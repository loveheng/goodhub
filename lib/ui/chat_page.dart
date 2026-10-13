/// 双轨消息流聊天主页（M4-T3）：AgentLoop 的正式产品宿主面。
/// 交互 SSOT = docs/product/chat-interaction.md；视觉 = ui-design.md（tokens
/// 唯一出处 goodhub-ui skill）。D9 拍板：本页为应用首页；D10：历史持久化拆
/// T3b（本页内存态，页面退出焚）；D11：同页多轮上下文共享（transcript 续接）。
///
/// 会话持有（§15）：AgentLoop 实例的引擎/执行链按 Run 重建（围栏映射会话 D2
/// 口径），SkillRegistry 激活集与降级判据记忆、对话历史随页面存续；RefStore
/// 会话粒度随 Run 焚（§9）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'trust_plugin_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../coordinator/agent_loop.dart';
import '../coordinator/cow_sync.dart';
import '../coordinator/degradation_controller.dart';
import '../coordinator/fenced_cloud_engine.dart';
import '../coordinator/hybrid_assembly.dart';
import '../coordinator/mcp_tool_face.dart';
import '../coordinator/memory_tool_executor.dart';
import '../coordinator/permission_gateway.dart';
import '../coordinator/ref_hydrator.dart';
import '../coordinator/ref_store.dart';
import '../coordinator/skill_activation_executor.dart';
import '../coordinator/skill_registry.dart';
import '../coordinator/tool_breaker.dart';
import '../coordinator/discovery_executor.dart';
import '../coordinator/tool_router.dart';
import '../core/errors/mcp_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../mcp/mcp_client.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/trusted_plugins.dart';
import '../mcp/sampling.dart';
import '../mcp/server_capabilities.dart';
import '../mcp/server_endpoints.dart';
import '../sandbox/conversation_store.dart';
import '../sandbox/memory_store.dart';
import '../gateway/gateway_controller.dart';
import 'components/call_card.dart';
import 'components/cross_source_consent_card.dart';
import 'components/dual_track_stream.dart';
import 'components/status_capsule.dart';
import 'tokens/console_tokens.dart';
import 'components/stuck_watcher.dart';
import 'gateway_loop_debug_page.dart';
import 'services_hall_page.dart';
import 'claim_loop_page.dart';
import 'memory_board_page.dart';

/// 连接配置持久化（T6-2）：改走 [ServerEndpointStore]（多端点 JSON + apiKey
/// 走安全存储）；旧单端点 SharedPreferences 由该 store 在首次 load 时迁移。

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _systemPrompt =
      '你是 GoodHub 宿主助手，调度已挂载服务与宿主能力完成用户任务。'
      '只读工具会静默执行，写操作需用户在确认卡批准；用户偏好可写入宿主记忆'
      '（只记稳定事实，禁记临时数据），回答使用中文。';

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _track = <TrackEntry>[];

  // 连接配置：多端点持久化走 [ServerEndpointStore]（无单值内存镜像）；
  // [_send] 每次 Run 启动从 store 全量加载，[_openSettings] 内联管理加/删/编辑。

  // 会话状态（页面 = 一个会话，§15）
  final List<CloudChatMessage> _history = [];
  SkillRegistry? _skills;
  DegradationController? _degradation;
  final SamplingQuota _samplingQuota = SamplingQuota(); // D3：重启清零

  // PC 远程网关（G1）：设置面板开关 + 配对 Token（SharedPreferences 持久化）。
  var _gatewayRunning = false;
  var _gatewayLanAddrs = const <String>[]; // G5：运行中展示 PC 可配 URL
  final _gatewayTokenCtrl = TextEditingController();

  // 会话持久化（M4-T3b，D10/D13）：当前会话 id + 标题 + 侧边栏列表
  ConversationStore? _convStore;
  String? _conversationId;
  var _conversationTitle = '';
  var _conversations = <ConversationMeta>[];

  // Run 期柄（Abort/卡状态机/卡死判定接线目标；finally 清）
  var _running = false;
  var _pillLabel = 'idle';
  var _pillTone = CapsuleTone.idle;
  AgentLoop? _activeLoop;
  McpToolFace? _activeFace;
  TrackCall? _activeCallEntry;
  StuckWatcher? _watcher;

  @override
  void initState() {
    super.initState();
    unawaited(_loadConfig());
    unawaited(_initConversations());
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _gatewayTokenCtrl.dispose();
    super.dispose();
  }

  /// T6：从 [ServerEndpointStore] 加载（首次 load 自动迁移旧 SharedPreferences
  /// 单端点配置）；多端点管理在 [_openSettings] 内联编辑，本页不持单值镜像。
  Future<void> _loadConfig() async {
    final support = await getApplicationSupportDirectory();
    await _epStore(support.path).load(); // 触发旧配置迁移
  }

  // ---------------------------------------------------------------------------
  // 会话持久化（M4-T3b）：侧边栏 + 恢复/切换/新建/删除
  // ---------------------------------------------------------------------------

  Future<void> _initConversations() async {
    final support = await getApplicationSupportDirectory();
    _convStore = ConversationStore.underSupportDir(support.path);
    await _refreshConversations();
  }

  Future<void> _refreshConversations() async {
    final store = _convStore;
    if (store == null) return;
    final list = await store.list();
    if (!mounted) return;
    setState(() => _conversations = list);
  }

  static String _titleFrom(String prompt) {
    final line = prompt.trim().split('\n').first;
    return line.length > 20 ? '${line.substring(0, 20)}…' : line;
  }

  /// Run 收尾快照（原子重写）；失败 DEGRADE 留痕不抛穿 finally。
  Future<void> _persistConversation() async {
    final cid = _conversationId;
    final store = _convStore;
    if (cid == null || store == null) return;
    try {
      await store.save(
        id: cid,
        title: _conversationTitle,
        track: TrackEntryCodec.encode(_track),
        messages: ConversationStore.encodeMessages(_history),
      );
      await _refreshConversations();
    } on Object catch (e) {
      debugPrint('[DEGRADE] chat: 会话快照保存失败 $cid: $e');
      _add(TrackNote('⚠ 会话快照保存失败（见日志）', danger: true));
    }
  }

  /// 切换/删除前的当前会话保底。
  Future<void> _persistIfAny() async {
    if (_conversationId != null) await _persistConversation();
  }

  /// 恢复/新建后重置会话态：激活集属会话（§15），跨会话必须重开。
  void _resetSessionState() {
    setState(() {
      _track.clear();
      _history.clear();
      _skills = null;
      _conversationId = null;
      _conversationTitle = '';
      _activeCallEntry = null;
      _pillLabel = 'idle';
      _pillTone = CapsuleTone.idle;
    });
  }

  Future<void> _newConversation() async {
    if (_running) return;
    await _persistIfAny();
    if (!mounted) return;
    Navigator.pop(context); // 关抽屉
    _resetSessionState();
  }

  Future<void> _loadConversation(ConversationMeta meta) async {
    if (_running) return;
    final snap = await _convStore?.load(meta.id);
    if (!mounted) return;
    if (snap == null) {
      _add(TrackNote('⚠ 会话文件损坏无法恢复：${meta.title}', danger: true));
      return;
    }
    await _persistIfAny(); // 保当前会话再切换
    if (!mounted) return;
    Navigator.pop(context);
    _resetSessionState();
    setState(() {
      _conversationId = snap.id;
      _conversationTitle = snap.title;
      _history.addAll(ConversationStore.decodeMessages(snap.messages));
      _track.addAll(TrackEntryCodec.decode(snap.track));
    });
    _pinToBottom();
  }

  Future<void> _deleteConversation(ConversationMeta meta) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('「${meta.title}」及其对话历史将被移除，不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _convStore?.delete(meta.id);
    if (_conversationId == meta.id) _resetSessionState();
    await _refreshConversations();
  }

  static String _fmtTime(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day
        ? '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'
        : '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }



  /// T6-2：生产装配入口——[ServerEndpointStore] 指向应用支持目录/mcp_servers.json，
  /// 旧单端点 SharedPreferences 经 [flutterPrefsLike] 注入迁移。
  ServerEndpointStore _epStore(String supportPath) => ServerEndpointStore(
        file: File('$supportPath/mcp_servers.json'),
        prefs: flutterPrefsLike((key) =>
            SharedPreferences.getInstance().then((sp) => sp.getString(key))),
      );

  /// T6：静态首级摘要「## 已挂载服务」（自动生成，标注工具名前缀格式）。
  static String _mountedServicesSection(
    ToolRouter router,
    Map<String, String> summaries,
  ) {
    final lines = [
      for (final id in router.serverIds)
        '- $id: ${summaries[id] ?? '(无摘要)'}'
        '${router.activatedServers.contains(id) ? '' : ' ［未激活，需 activate_server_tools］'}',
    ];
    final first = router.serverIds.isEmpty ? 'server_id' : router.serverIds.first;
    return '\n\n## 已挂载服务（自动生成）\n'
        '工具名带服务前缀，格式 `<server_id>__<tool>`，例如 `${first}__get_item`。\n'
        '服务列表：\n${lines.join('\n')}\n'
        '未激活服务用 get_connected_apps 查看、activate_server_tools 激活。';
  }

  void _add(TrackEntry entry) {
    if (!mounted) return;
    setState(() => _track.add(entry));
    _pinToBottom();
  }

  void _appendText(String delta) {
    if (!mounted) return;
    setState(() {
      final last = _track.isNotEmpty ? _track.last : null;
      if (last is TrackText) {
        last.text.write(delta);
      } else {
        _track.add(TrackText(delta));
      }
    });
    _pinToBottom();
  }

  void _pinToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _setPill(String label, CapsuleTone tone) {
    if (!mounted) return;
    setState(() {
      _pillLabel = label;
      _pillTone = tone;
    });
  }

  /// T6：通用多端点管理（规范驱动——任意满足接入规范的外界 MCP 服务均可添加，
  /// 手填 id/endpoint/token，如 shuguang）。支持内联编辑、删除、新增。
  Future<void> _openSettings() async {
    final support = await getApplicationSupportDirectory();
    final epStore = _epStore(support.path);
    final initial = await epStore.load();
    if (!mounted) return;
    final eps = List<ServerEndpoint>.from(initial);
    final keys = <String, String?>{};
    for (final e in eps) {
      keys[e.id] = await epStore.apiKey(e.id);
    }
    final prefs = await SharedPreferences.getInstance();
    // §1.2.6 信任管理：预扫本地插件 + 加载信任白名单（设置面板内联管理）。
    final localPlugins = await localPluginDiscovery.scan();
    final trusted = await TrustedPlugins.instance;
    _gatewayRunning = GatewayController.shared.running;
    _gatewayLanAddrs =
        _gatewayRunning ? await GatewayController.lanAddresses() : const [];
    if (!mounted) return;
    _gatewayTokenCtrl.text = prefs.getString('gateway.token') ?? '';
    var editingId = '';
    var adding = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final t = consoleTokens(ctx);
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // —— PC 远程网关（G1）：开关 + 配对 Token ——
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('PC 远程网关（:8766）'),
                    subtitle: Text(
                      _gatewayRunning
                          ? '运行中——PC 配置：'
                              '${_gatewayLanAddrs.isEmpty ? 'http://<手机IP>' : _gatewayLanAddrs.map((a) => 'http://$a').join(' 或 ')}'
                              ':8766/mcp（ADB 场景 127.0.0.1:8766）'
                          : '关闭——开启后 PC 经 Streamable HTTP 调用手机内全部服务',
                      style: const TextStyle(fontSize: 12),
                    ),
                    value: _gatewayRunning,
                    onChanged: (v) async {
                      final token = _gatewayTokenCtrl.text.trim();
                      if (v) {
                        await prefs.setString('gateway.token', token);
                        try {
                          await GatewayController.shared.start(
                              port: 8766, token: token);
                        } on Object catch (e) {
                          if (mounted) {
                            _add(TrackNote('⚠ 网关起服失败: $e', danger: true));
                          }
                        }
                        _gatewayLanAddrs =
                            await GatewayController.lanAddresses();
                      } else {
                        await GatewayController.shared.stop();
                      }
                      setSheet(() =>
                          _gatewayRunning = GatewayController.shared.running);
                    },
                  ),
                  TextField(
                    controller: _gatewayTokenCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '配对 Token（可空；留空 = 不鉴权，仅建议 ADB 调试）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('本地插件信任（零配置发现，§1.2.6）',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('同签名私有插件自动信任；第三方需手动信任（可在下方撤销）。',
                      style: TextStyle(fontSize: 12, color: t.terminalMuted)),
                  const SizedBox(height: 8),
                  for (final p in localPlugins)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${p.serverTitle}（${p.serverId}）'),
                      subtitle: Text(
                        '${p.packageName}${p.sameSignature ? ' · 同签名' : ' · 第三方'}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                      value: p.sameSignature ||
                          trusted.isTrusted(p.packageName),
                      onChanged: p.sameSignature
                          ? null
                          : (v) async {
                              if (v) {
                                await trusted.add(p.packageName,
                                    p.signatureSha256, p.serverTitle);
                              } else {
                                await trusted.remove(p.packageName);
                              }
                              setSheet(() {});
                            },
                    ),
                  if (localPlugins.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                          '未发现本地插件（安装声明 MCP_SERVER 的 App 后将出现）',
                          style: TextStyle(fontSize: 12, color: t.terminalMuted)),
                    ),
                  const Divider(),
                  const SizedBox(height: 16),
                  const Text('服务端点（多 MCP 接入）',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('连接任意满足接入规范的外界 MCP 服务（手填 endpoint + token）',
                      style: TextStyle(fontSize: 12, color: t.terminalMuted)),
                  const SizedBox(height: 12),
                  for (final ep in eps)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${ep.name}  (${ep.id})'),
                          subtitle: Text(
                              ep.endpoint.isEmpty
                                  ? '（未配置 endpoint）'
                                  : ep.endpoint,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(editingId == ep.id
                                    ? Icons.close
                                    : Icons.edit_outlined),
                                tooltip: editingId == ep.id ? '收起' : '编辑',
                                onPressed: () => setSheet(() =>
                                    editingId = editingId == ep.id ? '' : ep.id),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除',
                                onPressed: () async {
                                  eps.removeWhere((e) => e.id == ep.id);
                                  await epStore.save(eps);
                                  await epStore.setApiKey(ep.id, null);
                                  setSheet(() {});
                                  if (mounted) {
                                    _add(TrackNote('✓ 已删除服务 ${ep.name}',
                                        danger: false));
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                        if (editingId == ep.id)
                          _EditServiceForm(
                            ep: ep,
                            storedKey: keys[ep.id],
                            onSave: (updated, token) async {
                              final idx = eps.indexWhere((e) => e.id == ep.id);
                              if (idx >= 0) eps[idx] = updated;
                              await epStore.save(eps);
                              await epStore.setApiKey(
                                  ep.id, token.isEmpty ? null : token);
                              keys[ep.id] = token.isEmpty ? null : token;
                              setSheet(() => editingId = '');
                              if (mounted) {
                                _add(TrackNote('✓ 已更新服务 ${updated.name}',
                                    danger: false));
                              }
                            },
                            onCancel: () => setSheet(() => editingId = ''),
                          ),
                      ],
                    ),
                  if (eps.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                          '暂无服务，点下方「添加服务」接入（如 shuguang）',
                          style: TextStyle(fontSize: 12, color: t.terminalMuted)),
                    ),
                  const Divider(),
                  if (!adding)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setSheet(() => adding = true),
                        icon: const Icon(Icons.add),
                        label: const Text('添加服务'),
                      ),
                    )
                  else
                    _AddServiceForm(
                      onAdd: (id, name, endpoint, token) async {
                        final newEp = ServerEndpoint(
                          id: id,
                          name: name.isEmpty ? id : name,
                          endpoint: endpoint,
                          hasKey: token.isNotEmpty,
                        );
                        eps.add(newEp);
                        await epStore.save(eps);
                        if (token.isNotEmpty) {
                          await epStore.setApiKey(id, token);
                        }
                        keys[id] = token.isEmpty ? null : token;
                        setSheet(() {
                          adding = false;
                          editingId = id;
                        });
                        if (mounted) {
                          _add(TrackNote('✓ 已添加服务 $id', danger: false));
                        }
                      },
                      onCancel: () => setSheet(() => adding = false),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// D9：服务大厅/联调页/M1 任务循环入口收编（联调与任务循环仅 debug 构建）。
  void _openDebugMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const Text('服务大厅'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const ServicesHallPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('网关/熔断联调'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const GatewayLoopDebugPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.repeat_outlined),
              title: const Text('M1 任务循环（claim/apply）'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const ClaimLoopPage()));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// M4-T3 发送（D11 多轮）：上轮 transcript 作 history 续接；一次一个 Run。
  Future<void> _send() async {
    final prompt = _inputCtrl.text.trim();
    if (prompt.isEmpty || _running) return;
    // —— T6-2 多服务装配：ServerEndpointStore 读多端点（含旧 SharedPreferences
    // 迁移）→ 每端点一个 McpClient + McpToolFace → ToolRouter（实例随会话建）——
    final support = await getApplicationSupportDirectory();
    final epStore = _epStore(support.path);
    final allEndpoints = await epStore.load();
    // T5 节点卡挂载位（ui-design §3.3）：enabled=false 的卸载节点不进连接池
    // （配置与令牌保留，大厅节点卡可重开）。
    final endpoints = allEndpoints.where((e) => e.enabled).toList();
    final unmounted = allEndpoints.length - endpoints.length;
    if (unmounted > 0) {
      _add(TrackNote('⊘ 已卸载 $unmounted 项服务（服务大厅节点卡可重新挂载）',
          danger: false));
    }
    // T-trans-4：本地插件零配置发现（系统托管，不进手填配置）；与 HTTP 端点合并判定。
    final locals = <LocalPluginInfo>[];
    try {
      locals.addAll(await localPluginDiscovery.scan());
    } on Object {
      // 发现通道不可用（宿主未就绪）→ 视为无本地插件，不阻断 HTTP 端点装配。
    }
    if (endpoints.isEmpty && locals.isEmpty) {
      _add(TrackNote(
          '⚠ 尚未配置任何 MCP 服务（右上角 ⚙ 设置），且未发现本地插件',
          danger: true));
      unawaited(_openSettings());
      return;
    }
    _inputCtrl.clear();
    setState(() {
      _running = true;
      _pillLabel = 'connecting';
      _pillTone = CapsuleTone.l1;
    });
    _add(TrackUser(prompt));
    // T3b：会话懒建（首个任务起落盘；标题取首行截断）。
    _conversationId ??= await _convStore!.create(title: _titleFrom(prompt));
    _conversationTitle = _conversationTitle.isEmpty
        ? _titleFrom(prompt)
        : _conversationTitle;
    RefStore? refStore;
    try {
      final memoryStore = MemoryStore.underSupportDir(support.path);
      // T6-2 多连接池：每个端点一个 client + face（协商 + 能力目录）。
      final faces = <String, McpToolFace>{};
      final clients = <String, McpClient>{};
      final summaries = <String, String>{};
      final serverCaps = <String, ServerCapabilities>{};
      AgentLoop? loopBox;
      for (final ep in endpoints) {
        final key = await epStore.apiKey(ep.id);
        final client = McpClient.http(baseUrl: ep.endpoint, apiKey: key);
        final caps = await client.negotiate();
        serverCaps[ep.id] = caps;
        _add(TrackNote(
            '✓ ${ep.name} ${caps.serverName ?? '?'} v${caps.serverVersion ?? '?'} ｜ '
            '${caps.isTier1 ? 'Tier 1' : 'Tier 2（vanilla，Polyfill 接管）'}',
            danger: false));
        final face = McpToolFace(
          client: client,
          serverId: ep.id,
          opsLog: memoryStore, // N4 审计（remote 侧）
          onProgress: (tool, progress, total, message) {
            loopBox?.emitToolProgress(tool, progress, total, message);
            _setPill(
                total != null ? '$tool $progress/$total' : '$tool $progress',
                CapsuleTone.l1);
          },
        );
        await face.listTools();
        faces[ep.id] = face;
        clients[ep.id] = client;
        summaries[ep.id] =
            '${caps.serverName ?? ep.name} ${caps.isTier1 ? 'Tier 1' : 'Tier 2'}';
      }
      // T-trans-4：本地插件自动挂载（系统托管，零配置）。每个插件 = 一个 Binder 传输的
      // McpClient + McpToolFace，纳入同一 ToolRouter；onServerRequest(sampling) 由下方
      // 统一循环接管（反向请求 e2e 闭环，§1.2.2 / §5）。
      for (final info in locals) {
        if (info.serverId.isEmpty || faces.containsKey(info.serverId)) continue;
        // §1.2.6 信任闸门：同签名私有生态零弹窗自动信任；第三方首次需信任卡片确认，
        // 确认后持久化入白名单，后续会话自动信任。
        if (!info.sameSignature) {
          final trusted = await TrustedPlugins.instance;
          if (!trusted.isTrusted(info.packageName)) {
            if (!mounted) continue;
            final ok = await showTrustCard(context, info);
            if (!ok) {
              _add(TrackNote(
                  '⚠ 未信任本地插件 ${info.serverTitle}，已跳过挂载',
                  danger: true));
              continue;
            }
          }
        }
        try {
          final client = localPluginDiscovery.createClient(info);
          final caps = await client.negotiate();
          serverCaps[info.serverId] = caps;
          final face = McpToolFace(
            client: client,
            serverId: info.serverId,
            opsLog: memoryStore,
            onProgress: (tool, progress, total, message) {
              loopBox?.emitToolProgress(tool, progress, total, message);
              _setPill(
                  total != null ? '$tool $progress/$total' : '$tool $progress',
                  CapsuleTone.l1);
            },
          );
          await face.listTools();
          faces[info.serverId] = face;
          clients[info.serverId] = client;
          summaries[info.serverId] =
              '${caps.serverName ?? info.serverTitle} (本地) ${caps.isTier1 ? 'Tier 1' : 'Tier 2'}';
          _add(TrackNote(
              '✓ 本地插件 ${info.serverTitle} ${caps.serverName ?? '?'} ｜ 自动挂载',
              danger: false));
        } catch (e) {
          _add(TrackNote(
              '⚠ 本地插件 ${info.serverTitle} 挂载失败: $e', danger: true));
        }
      }
      // T6：路由注册表（实例随会话建）+ 默认激活全部已挂载（保单服务回归）。
      final router = ToolRouter(faces: faces);
      router.activatedServers.addAll(router.serverIds);
      // 链路序（T6 设计）：Loop → Discovery → SkillActivation → MemoryTool →
      // Hydration → Gateway → ToolRouter → faces。
      final memoryTool = MemoryToolExecutor(inner: router, store: memoryStore);
      final gateway = PermissionGateway(
        inner: memoryTool,
        delegate: _ChatGate(this),
        onNotice: (n) {
          _setPill(n.toolName, CapsuleTone.l1);
          unawaited(HapticFeedback.selectionClick());
        },
      );
      gateway.loadCatalog([
        ...router.activatedSchemas(),
        ...MemoryToolExecutor.toolSchemas(),
      ]);
      refStore = RefStore(
        cacheDir: await getTemporaryDirectory(),
        gcInterval: null, // 短会话，finally 即焚
      );
      final hydration = HydratingExecutor(
        inner: gateway,
        refStore: refStore,
        targetResolver: router.serverFor,
        crossSourceDelegate: (handle, from, to, preview) async {
          // D5：恒 L2 弹卡、无豁免勾选；禁盲签由卡内兜底。
          final r = await showDialog<bool>(
            context: context,
            builder: (dialogCtx) => AlertDialog(
              contentPadding: EdgeInsets.zero,
              content: CrossSourceConsentCard(
                handle: handle,
                fromServer: from,
                toServer: to,
                preview: preview,
                onDecision: (v) => Navigator.pop(dialogCtx, v),
              ),
            ),
          );
          return r == true;
        },
      );
      final engine = await assembleDefaultHybridEngine(
        controller: _degradation ??= DegradationController(),
        piiFenceDelegate: _ChatFence(this), // D4 有人值守拦截卡
      );
      _add(TrackNote('引擎: ${engine.name}', danger: false));
      _watcher = StuckWatcher(onStuck: _markActiveCallStuck);
      // T6：每个 client 接管自身采样反向请求（serverKey = serverId）。
      for (final entry in clients.entries) {
        final sampling = samplingRequestHandler(
          engine: engine,
          quota: _samplingQuota,
          serverKey: entry.key,
        );
        entry.value.onServerRequest = (method, params) {
          _watcher?.samplingBegin();
          return sampling(method, params)
              .whenComplete(() => _watcher?.samplingEnd());
        };
      }
      // 会话粒度 SkillRegistry（§15）：激活集跨 Run 保留（同页多轮共享）。
      final skills = _skills ??= SkillRegistry()..registerAll(builtinSkills());
      // T6：逐 server CoW 同步（有 prompts 能力者）；skill 名保持 cow/<promptName>
      // 撞名跳过（design 口径）。
      for (final entry in clients.entries) {
        final caps = serverCaps[entry.key]!;
        if (!caps.hasPrompts) continue;
        try {
          final cow = CowSyncService(
            store: CowOverridesStore(
                dir: await getApplicationDocumentsDirectory()),
            onMajorJump: (name, from, to) async {
              final r = await showDialog<bool>(
                context: context,
                builder: (dialogCtx) => AlertDialog(
                  title: Text('模板大版本更新：$name'),
                  content:
                      Text('服务端模板 $from → $to（大版本跃迁）。\n重置回服务端最新版，还是保留本地覆写？'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogCtx, false),
                        child: const Text('保留本地')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogCtx, true),
                        child: const Text('重置为服务端版')),
                  ],
                ),
              );
              return r == true;
            },
          );
          for (final i in await cow.sync(entry.value, serverId: entry.key)) {
            if (i.content == null) continue;
            final skill = CowSyncService.toSkill(i, entry.key);
            if (skills.byName(skill.name) != null) continue;
            try {
              skills.register(skill);
            } on ArgumentError catch (e) {
              _add(TrackNote('⚠ CoW Skill 注册跳过: ${i.promptName} — $e',
                  danger: true));
            }
          }
        } on McpException catch (e) {
          _add(TrackNote('CoW 同步失败（Polyfill 降级为无模板注入）：$e', danger: false));
        }
      }
      final skillExecutor = SkillActivationExecutor(
          inner: hydration, registry: skills, opsLog: memoryStore);
      // T6-3 JIT 两级发现：DiscoveryExecutor 挂最外层（SkillActivation 之前），
      // 拦截 get_connected_apps / activate_server_tools（L1 本地，不走确认卡）。
      final discovery = DiscoveryExecutor(
        router: router,
        inner: skillExecutor,
        serverSummaries: summaries,
        onActivation: (id) => _add(TrackNote(
            '✓ 已激活服务 $id（后续轮次其工具可用）',
            danger: false)),
      );
      final loop = AgentLoop(
        engine: engine,
        executor: discovery,
        blockDelegate: _ChatBlock(this),
        refStore: refStore,
        refServerId:
            router.serverIds.isNotEmpty ? router.serverIds.first : 'goodshare',
        serverResolver: router.serverFor,
        toolsProvider: () => [
          ...router.activatedSchemas(),
          ...DiscoveryExecutor.staticSchemas(),
          skills.activationToolSchema(),
          ...MemoryToolExecutor.toolSchemas(),
        ],
      );
      loopBox = loop;
      _activeLoop = loop;
      _activeFace = faces[router.serverIds.first]; // 主服务面（Abort 取消目标）
      // M4-T2 记忆注入（D8 三层作用域）+ 超限可观测：作用域 = 全部已连服务。
      final memView =
          await memoryStore.memoryView(serverScopes: router.serverIds);
      final memSection = await memoryPromptSection(
          memoryStore, serverScopes: router.serverIds);
      // T6：静态首级摘要「## 已挂载服务」（自动生成，标注工具名前缀格式）。
      final mountedSection = _mountedServicesSection(router, summaries);
      _add(TrackNote(
          '记忆注入：${memView.entries.length} 条'
          '${memView.truncated ? '（预算外丢弃 ${memView.droppedCount} 条）' : ''}',
          danger: false));
      _setPill('thinking', CapsuleTone.l1);
      await for (final e in loop.run(
        systemPrompt: skills.composeSystemPrompt(
                _systemPrompt, connectedServerIds: router.serverIds) +
            mountedSection +
            memSection,
        userPrompt: prompt,
        history: List.of(_history), // D11：上轮 transcript 续接
        tools: const [],
      )) {
        switch (e) {
          case LoopTextDelta(:final text):
            _appendText(text);
          case LoopToolCallStarted(:final call):
            _setPill(call.name, CapsuleTone.l1);
            final entry = TrackCall(tool: call.name);
            _activeCallEntry = entry;
            _add(entry);
            _watcher?.start();
          case LoopToolProgress(:final call, :final progress, :final total, :final message):
            final entry = _activeCallEntry;
            if (entry != null && entry.tool == call.name) {
              setState(() {
                final tail = message == null ? '' : ' · $message';
                entry.progressNote =
                    total != null ? '$progress/$total$tail' : '$progress$tail';
              });
            }
            _watcher?.onProgressFrame();
          case LoopToolCallFinished(:final call, :final result):
            final rejected = result.content.contains('"user_rejected"');
            final entry = _activeCallEntry;
            final phase =
                result.isError ? CallCardPhase.failed : CallCardPhase.success;
            if (entry != null && entry.tool == call.name) {
              // 真实结果优先于 Abort 的 cancelled 标记（在途调用完成后照常回填）
              setState(() {
                entry
                  ..phase = phase
                  ..preview = _preview(result.content)
                  ..progressNote = null;
              });
            } else {
              _add(TrackCall(tool: call.name)
                ..phase = phase
                ..preview = _preview(result.content));
            }
            _activeCallEntry = null;
            _watcher?.stop();
            _setPill(rejected ? 'rejected' : 'idle', CapsuleTone.l1);
          case LoopFinished(:final text, :final turns, :final transcript):
            _history
              ..clear()
              ..addAll(transcript); // D11：下轮续接（未配对尾巴已截断）
            _appendText(text.isEmpty ? '' : '\n');
            _add(TrackNote('✓ 收尾（$turns 轮）', danger: false));
            _setPill('done', CapsuleTone.idle);
        }
      }
    } on Object catch (e) {
      _add(TrackNote('✕ $e', danger: true));
      _setPill('failed', CapsuleTone.danger);
    } finally {
      _watcher?.stop();
      _watcher = null;
      _activeLoop = null;
      _activeFace = null;
      _activeCallEntry = null;
      await refStore?.expireAll(); // §9：Session 结束直清临时文件
      refStore?.dispose();
      await _persistConversation(); // T3b：Run 收尾快照（含 Cancelled 终态）
      if (mounted) setState(() => _running = false);
    }
  }

  /// D4 判定触发：在途卡转 stuck（Amber 提示），不自动中止（§10）。
  void _markActiveCallStuck() {
    final entry = _activeCallEntry;
    if (entry == null || entry.phase != CallCardPhase.running) return;
    if (mounted) setState(() => entry.phase = CallCardPhase.stuck);
  }

  /// §10 级联 UI 侧（M3-T2 语义复用）：③ cancelled 下发 → 环边界停下 →
  /// 在途卡 Cancelled 态（区别 Failed）。
  void _abort() {
    if (!_running) return;
    _watcher?.stop();
    _activeFace?.cancelActiveRequest(reason: 'user abort');
    _activeLoop?.abort();
    final entry = _activeCallEntry;
    if (entry != null && entry.phase == CallCardPhase.running) {
      setState(() {
        entry.phase = CallCardPhase.cancelled;
        entry.progressNote = '已中止（在途调用结果仍会回填）';
      });
    }
    _setPill('idle', CapsuleTone.idle);
  }

  /// D13 侧边栏（会话维度）：会话历史列表 + 服务大厅/记忆看板入口（服务区随 T6 预留）。
  Widget _buildDrawer() {
    final t = consoleTokens(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('会话',
                        style: TextStyle(
                            fontFamily: t.monoFamily,
                            fontSize: 13,
                            color: t.terminalMuted)),
                  ),
                  TextButton.icon(
                    onPressed: _running ? null : _newConversation,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新会话'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _conversations.isEmpty
                  ? Center(
                      child: Text('暂无历史会话\n（首次发送任务后自动保存）',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5, color: t.terminalMuted)))
                  : ListView.builder(
                      itemCount: _conversations.length,
                      itemBuilder: (context, i) {
                        final meta = _conversations[i];
                        return ListTile(
                          leading: Icon(Icons.chat_bubble_outline,
                              size: 18, color: t.terminalMuted),
                          title: Text(meta.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_fmtTime(meta.updatedAt),
                              style: const TextStyle(fontSize: 11)),
                          selected: meta.id == _conversationId,
                          onTap: _running ? null : () => _loadConversation(meta),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: '删除会话',
                            onPressed: _running
                                ? null
                                : () => unawaited(_deleteConversation(meta)),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const Text('服务大厅'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const ServicesHallPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('记忆看板'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const MemoryBoardPage()));
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _preview(String content) {
    final lines = content.trim().split('\n');
    final head = lines.take(2).join(' ⏎ ');
    return head.length > 120 ? '${head.substring(0, 120)}…' : head;
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        colorScheme: Theme.of(context).colorScheme,
        extensions: const [ConsoleTokens.fallback],
      ),
      child: Scaffold(
        drawer: _buildDrawer(),
        appBar: AppBar(
          title: const Text('GoodHub'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: '连接配置',
              onPressed: _running ? null : _openSettings,
            ),
            if (kDebugMode)
              IconButton(
                icon: const Icon(Icons.bug_report_outlined),
                tooltip: '调试入口',
                onPressed: _running ? null : _openDebugMenu,
              ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  const Spacer(),
                  StatusCapsule(label: _pillLabel, tone: _pillTone),
                ],
              ),
            ),
            Expanded(
              child: DualTrackStream(
                entries: _track,
                controller: _scrollCtrl,
                emptyHint: '下达自然语言任务，宿主调度已挂载服务完成\n（先在 ⚙ 配置服务端点）',
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputCtrl,
                        enabled: !_running,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: '描述任务…（如：把这篇笔记的行动项写进 todo）',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _running
                        ? FilledButton.tonal(
                            onPressed: _abort,
                            style: FilledButton.styleFrom(
                              foregroundColor: t.dangerDeep,
                            ),
                            child: const Text('[ABORT]'),
                          )
                        : FilledButton(
                            onPressed: _send,
                            child: const Text('发送'),
                          ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// L2 确认卡委托：轨道插待决卡并 await 用户操作（§10 结算流）。
class _ChatGate implements GateDelegate {
  _ChatGate(this._state);

  final _ChatPageState _state;

  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) {
    final entry = TrackConfirm(pending: pending);
    _state._add(entry);
    return entry.completer.future;
  }
}

/// 熔断/步数墙排查卡委托。
class _ChatBlock implements BlockDelegate {
  _ChatBlock(this._state);

  final _ChatPageState _state;

  @override
  Future<BreakerResolution> onBreakerTripped(BreakerReport report) {
    _state._setPill('breaker', CapsuleTone.danger);
    final entry = TrackBreaker.breaker(report);
    _state._add(entry);
    return entry.completer.future.then((value) => value as BreakerResolution);
  }

  @override
  Future<bool> onStepWallReached(StepWallReport report) {
    final entry = TrackBreaker.wall(report);
    _state._add(entry);
    return entry.completer.future.then((value) => value as bool);
  }
}

/// N7 围栏拦截确认委托（D4 有人值守面）。
class _ChatFence implements PiiFenceDelegate {
  _ChatFence(this._state);

  final _ChatPageState _state;

  @override
  Future<bool> onMaskBlocked(PiiMaskBlockInfo info) {
    _state._setPill('fence', CapsuleTone.danger);
    final entry = TrackFence(info);
    _state._add(entry);
    return entry.completer.future;
  }
}

/// T6：端点内联编辑表单（持有 controller，避免 StatefulBuilder 重建丢输入）。
class _EditServiceForm extends StatefulWidget {
  const _EditServiceForm({
    required this.ep,
    required this.storedKey,
    required this.onSave,
    required this.onCancel,
  });

  final ServerEndpoint ep;
  final String? storedKey;
  final void Function(ServerEndpoint updated, String token) onSave;
  final VoidCallback onCancel;

  @override
  State<_EditServiceForm> createState() => _EditServiceFormState();
}

class _EditServiceFormState extends State<_EditServiceForm> {
  late final _epCtrl = TextEditingController(text: widget.ep.endpoint);
  late final _keyCtrl = TextEditingController(text: widget.storedKey ?? '');

  @override
  void dispose() {
    _epCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _epCtrl,
            decoration: const InputDecoration(
              labelText: 'MCP Endpoint（须含 /mcp）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'X-Api-Key（可留空）',
              border: const OutlineInputBorder(),
              isDense: true,
              hintText: widget.storedKey?.isNotEmpty == true
                  ? '已存令牌（留空不改）'
                  : null,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => widget.onSave(
                  widget.ep.copyWith(endpoint: _epCtrl.text.trim()),
                  _keyCtrl.text.trim(),
                ),
                child: const Text('保存'),
              ),
            ],
          ),
          if (widget.storedKey?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  '该服务已存令牌（安全存储）。留空密钥框 = 不改；填新值 = 覆盖。',
                  style: TextStyle(fontSize: 11, color: t.terminalMuted)),
            ),
        ],
      ),
    );
  }
}

/// T6：新增端点表单（id/name/endpoint/token；id 校验不含 `__`）。
class _AddServiceForm extends StatefulWidget {
  const _AddServiceForm({
    required this.onAdd,
    required this.onCancel,
  });

  final void Function(String id, String name, String endpoint, String token)
      onAdd;
  final VoidCallback onCancel;

  @override
  State<_AddServiceForm> createState() => _AddServiceFormState();
}

class _AddServiceFormState extends State<_AddServiceForm> {
  final _idCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _epCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  var _err = '';

  @override
  void dispose() {
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _epCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final id = _idCtrl.text.trim();
    if (id.isEmpty) {
      setState(() => _err = '服务标识不能为空');
      return;
    }
    if (id.contains('__')) {
      setState(() => _err = '服务标识不能含 "__"（工具名前缀分隔符）');
      return;
    }
    widget.onAdd(
      id,
      _nameCtrl.text.trim(),
      _epCtrl.text.trim(),
      _keyCtrl.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _idCtrl,
            decoration: const InputDecoration(
              labelText: '服务标识（如 shuguang，不含 __）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '展示名（可空，默认同标识）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _epCtrl,
            decoration: const InputDecoration(
              labelText: 'MCP Endpoint（须含 /mcp）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'X-Api-Key（可留空）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          if (_err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child:
                  Text(_err, style: TextStyle(fontSize: 12, color: t.dangerDeep)),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _submit, child: const Text('添加')),
            ],
          ),
        ],
      ),
    );
  }
}
