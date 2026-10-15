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
import '../coordinator/workspace_stream_filter.dart';
import '../coordinator/skill_activation_executor.dart';
import '../coordinator/skill_registry.dart';
import '../coordinator/tool_breaker.dart';
import '../coordinator/discovery_executor.dart';
import '../coordinator/tool_router.dart';
import '../mcp/connection_manager.dart';
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
import '../sandbox/workspace_state_store.dart';
import 'components/call_card.dart';
import 'components/cross_source_consent_card.dart';
import 'components/dual_track_stream.dart';
import 'components/status_capsule.dart';
import 'components/stream_text_buffer.dart';
import 'tokens/console_tokens.dart';
import 'components/stuck_watcher.dart';
import 'gateway_loop_debug_page.dart';
import 'settings_page.dart';
import 'claim_loop_page.dart';
import 'update_page.dart';
import 'memory_board_page.dart';

/// 连接配置持久化（T6-2）：改走 [ServerEndpointStore]（多端点 JSON + apiKey
/// 走安全存储）；旧单端点 SharedPreferences 由该 store 在首次 load 时迁移。

/// T4-5 收官：工具执行按 server 路由到对应 [McpConnection.guardExecute]（离线
/// 窗口内整体丢弃、不重放）；无 server 前缀的工具（JIT 元工具/本地工具）透传。
class _GuardedExecutor implements ToolExecutor {
  _GuardedExecutor(this.connections, this.router, this.inner);

  final Map<String, McpConnection> connections;
  final ToolRouter router;
  final ToolExecutor inner;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) {
    final sid = router.serverFor(call.name);
    final conn = sid != null ? connections[sid] : null;
    if (conn != null) return conn.guardExecute(() => inner.execute(call));
    return inner.execute(call);
  }
}

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
  // [_send] 每次 Run 启动从 store 全量加载；增删改与探活/挂载全归设置页
  // （2026-10-16 合并：聊天页不再持有任何非会话 UI）。

  // 会话状态（页面 = 一个会话，§15）
  final List<CloudChatMessage> _history = [];
  SkillRegistry? _skills;
  DegradationController? _degradation;
  final SamplingQuota _samplingQuota = SamplingQuota(); // D3：重启清零

  // 会话持久化（M4-T3b，D10/D13）：当前会话 id + 标题 + 侧边栏列表
  ConversationStore? _convStore;
  String? _conversationId;

  /// P2-6（G3）：会话级事实库懒建（首个任务轮起与 ConversationStore 同期装配）。
  WorkspaceStateStore? _wsStates;
  var _conversationTitle = '';
  var _conversations = <ConversationMeta>[];
  // 会话级 MCP 绑定（v1）：null=未设定（按默认回退）/ ''=显式纯公共 / 否则 serverId。
  String? _activePrivateServerId;
  // 端点缓存（供 composer menu 与默认回退使用；_send 内刷新）。
  List<ServerEndpoint> _endpoints = <ServerEndpoint>[];
  // 本地插件缓存（零配置自动发现；系统托管、始终挂载；供状态带/菜单展示）。
  List<LocalPluginInfo> _localPlugins = const <LocalPluginInfo>[];

  // Run 期柄（Abort/卡状态机/卡死判定接线目标；finally 清）
  var _running = false;

  /// 运行起始时刻（状态带计时显示用；running=false 时清空）。
  DateTime? _runStartedAt;

  /// 状态带秒级计时刷新定时器（running 期间每秒 setState 刷新已耗时）。
  Timer? _elapsedTimer;
  var _pillLabel = 'idle';
  var _pillTone = CapsuleTone.idle;

  /// 流式自动跟随（P2）：用户上翻看历史时暂停「拽回底部」，回到底部恢复。
  var _autoFollow = true;
  AgentLoop? _activeLoop;
  McpToolFace? _activeFace;
  TrackCall? _activeCallEntry;
  StuckWatcher? _watcher;

  // P0 流控层（stream-perf §3）：阅读轨文本 delta 缓冲池（40ms 节拍批量刷盘）。
  final _streamBuf = StreamTextBuffer();

  @override
  void initState() {
    super.initState();
    _streamBuf.onFlush = _onStreamFlush;
    _scrollCtrl.addListener(_onUserScroll);
    unawaited(_loadConfig());
    unawaited(_initConversations());
    unawaited(_loadEndpoints());
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _streamBuf.dispose(); // P0：取消节拍定时器（widget 已销毁，残余无处可刷）
    super.dispose();
  }

  /// T6：从 [ServerEndpointStore] 加载（首次 load 自动迁移旧 SharedPreferences
  /// 单端点配置）；多端点管理在设置页（[SettingsPage]）编辑，本页不持单值镜像。
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
        activePrivateServerId: _activePrivateServerId,
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
    if (!_guardRunning('新建会话')) return;
    await _persistIfAny();
    if (!mounted) return;
    Navigator.pop(context); // 关抽屉
    _resetSessionState();
    _autoFollow = true;
  }

  Future<void> _loadConversation(ConversationMeta meta) async {
    if (!_guardRunning('切换会话')) return;
    final snap = await _convStore?.load(meta.id);
    if (!mounted) return;
    if (snap == null) {
      // 损坏会话不进任何轨道（避免串台写进当前会话快照），SnackBar 明示。
      _toast('⚠ 会话「${meta.title}」文件损坏，无法恢复');
      return;
    }
    await _persistIfAny(); // 保当前会话再切换
    if (!mounted) return;
    Navigator.pop(context);
    _resetSessionState();
    _autoFollow = true;
    setState(() {
      _conversationId = snap.id;
      _conversationTitle = snap.title;
      _activePrivateServerId = snap.activePrivateServerId;
      _history.addAll(ConversationStore.decodeMessages(snap.messages));
      _track.addAll(TrackEntryCodec.decode(snap.track));
    });
    _pinToBottom();
  }

  Future<void> _deleteConversation(ConversationMeta meta) async {
    if (!_guardRunning('删除会话')) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('「${meta.title}」及其对话历史将被移除，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: consoleTokens(dialogCtx).danger,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除'),
          ),
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
    prefs: flutterPrefsLike(
      (key) => SharedPreferences.getInstance().then((sp) => sp.getString(key)),
    ),
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
    final first = router.serverIds.isEmpty
        ? 'server_id'
        : router.serverIds.first;
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
    // P0 流控层（stream-perf §3）：delta 入池，40ms 节拍批量刷盘；流结束/中止/
    // 异常路径由 _send 的 finally 强制 flush，尾帧不丢。
    _streamBuf.add(delta);
  }

  /// 流控刷盘回调：与 _appendText 同一节拍落地 setState + _pinToBottom。
  void _onStreamFlush(String text) {
    if (!mounted) return;
    setState(() {
      final last = _track.isNotEmpty ? _track.last : null;
      if (last is TrackText) {
        last.text.write(text);
      } else {
        _track.add(TrackText(text));
      }
    });
    _pinToBottom();
  }

  /// 用户滚动监听：离开底部即暂停自动跟随（流式输出不劫持滚动），回到
  /// 底部恢复。程序性 jumpTo 恒落底部，不会误触该标志。
  void _onUserScroll() {
    if (!_scrollCtrl.hasClients) return;
    final atBottom =
        _scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 24;
    if (atBottom != _autoFollow && mounted) {
      setState(() => _autoFollow = atBottom);
    }
  }

  void _pinToBottom() {
    if (!_autoFollow) return; // 用户上翻看历史中：不拽回
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  /// 轻量反馈（SnackBar）：运行中共用守卫——给原因而非静默禁用。
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 运行中拦截的共用话术；返回 false = 调用方应中止动作。
  bool _guardRunning(String action) {
    if (_running) {
      _toast('任务运行中，$action需等待当前任务结束');
      return false;
    }
    return true;
  }

  void _setPill(String label, CapsuleTone tone) {
    if (!mounted) return;
    setState(() {
      _pillLabel = label;
      _pillTone = tone;
    });
  }

  /// 端点缓存预热（供 composer menu / 默认回退；首屏即可列服务）。
  /// 同时完成「新会话默认锁定」（①）：未显式绑定时按默认回退锁定首个启用的
  /// private（已显式绑定/纯公共 '' 则沿用），确保状态带与菜单开屏即正确。
  Future<void> _loadEndpoints() async {
    final support = await getApplicationSupportDirectory();
    final all = await _epStore(support.path).load();
    // 本地插件零配置自动发现（系统托管、始终挂载；与 _send 装配同口径）。
    // 通道不可用（宿主未就绪）按空目录，不阻断 HTTP 端点装配。
    final locals = <LocalPluginInfo>[];
    try {
      locals.addAll(await localPluginDiscovery.scan());
    } on Object {
      // 发现通道不可用：视为无本地插件。
    }
    if (!mounted) return;
    final bound = _activePrivateServerId ?? _resolveBinding(all);
    setState(() {
      _endpoints = all;
      _localPlugins = locals;
      _activePrivateServerId = bound;
    });
  }

  /// 是否处于"已绑定某私有服务"的弱感知态（用于状态带胶囊）。
  bool get _hasContext =>
      _activePrivateServerId != null && _activePrivateServerId!.isNotEmpty;

  /// 会话绑定默认回退：未显式绑定时 → 全局钉选 isDefault → 首个启用的 private
  /// → null（纯公共）。已显式绑定（含 '' 显式公共）则直接用。
  String? _resolveBinding(List<ServerEndpoint> eps) {
    final bound = _activePrivateServerId;
    if (bound != null) return bound.isEmpty ? null : bound;
    String? firstPrivate;
    for (final e in eps) {
      if (e.tier != ServerPrivacyTier.private) continue;
      if (e.isDefault) return e.id; // 全局钉选优先
      firstPrivate ??= e.id;
    }
    return firstPrivate;
  }

  /// 即时绑定（composer menu 调用）：写页面态 + 落会话元数据（对话未建则安全早退）。
  void _bindSessionServer(String? serverId) {
    setState(() => _activePrivateServerId = serverId);
    unawaited(_persistConversation());
  }

  /// 全局默认钉选写回（单选）：更新 mcp_servers.json 并刷新缓存。
  Future<void> _setGlobalDefault(String serverId, bool on) async {
    final support = await getApplicationSupportDirectory();
    final epStore = _epStore(support.path);
    final all = await epStore.load();
    var changed = false;
    final updated = <ServerEndpoint>[];
    for (final e in all) {
      final want = on && e.id == serverId;
      if (e.isDefault != want) {
        updated.add(e.copyWith(isDefault: want));
        changed = true;
      } else {
        updated.add(e);
      }
    }
    if (!changed) return;
    await epStore.save(updated);
    if (mounted) setState(() => _endpoints = updated);
  }

  String _endpointName(String id) {
    for (final e in _endpoints) {
      if (e.id == id) return e.name;
    }
    return id;
  }

  String? _defaultId() {
    for (final e in _endpoints) {
      if (e.isDefault) return e.id;
    }
    return null;
  }

  /// Composer Menu（药丸内左侧「+」→ 底部弹层）：本会话绑定哪个私有服务 +
  /// 全局默认钉选。数据驱动列表，未来附件/模型切换等仅追加项。
  Future<void> _openComposerMenu() async {
    if (!_guardRunning('打开上下文菜单')) return;
    // 开菜单前先重读端点目录：大厅新增/卸载服务后返回聊天页，initState 缓存可能
    // 已过时，直接重读保证菜单列出当前真实存在的私有服务。
    await _loadEndpoints();
    if (!mounted) return;
    final t = consoleTokens(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final bound = _activePrivateServerId;
          final priv = _endpoints
              .where((e) => e.enabled && e.tier == ServerPrivacyTier.private)
              .toList();
          final defaultId = _defaultId();
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
                  Text('本次会话上下文',
                      style: TextStyle(
                          fontSize: Fsz.telemetry, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    bound != null && bound.isNotEmpty
                        ? '已锁定：${_endpointName(bound)}（$bound）'
                        : (_localPlugins.isNotEmpty
                            ? '本地插件自动挂载（${_localPlugins.length}）· 未锁定手动私有服务'
                            : '纯公共模式（无私有域）'),
                    style: TextStyle(
                        fontSize: Fsz.note, color: t.terminalMuted),
                  ),
                  const Divider(height: 16),
                  if (priv.isEmpty && _localPlugins.isEmpty)
                    Text('无可用私有服务（私有端点请在 ⚙ 设置页添加）',
                        style: TextStyle(
                            fontSize: Fsz.note, color: t.terminalMuted)),
                  for (final e in priv)
                    ListTile(
                      leading: const Icon(Icons.lock_outline),
                      title: Text(e.name),
                      subtitle: Text(e.id),
                      trailing: (bound != null && bound == e.id)
                          ? const Icon(Icons.check, size: 18)
                          : null,
                      onTap: () {
                        _bindSessionServer(e.id);
                        setSheet(() {});
                      },
                    ),
                  if (_localPlugins.isNotEmpty) ...[
                    const Divider(height: 16),
                    Text('本地私有插件（自动挂载 · 零配置）',
                        style: TextStyle(
                            fontSize: Fsz.telemetry,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('私有 · 系统托管，始终参与本次任务，无需绑定选择',
                        style: TextStyle(
                            fontSize: Fsz.note, color: t.terminalMuted)),
                    for (final lp in _localPlugins)
                      ListTile(
                        leading: const Icon(Icons.lock_outline),
                        title: Text(
                            lp.serverTitle.isEmpty ? lp.serverId : lp.serverTitle),
                        subtitle: Text(lp.packageName),
                        trailing: Text('私有 · 始终挂载',
                            style: TextStyle(
                                fontSize: Fsz.note, color: t.l1Info)),
                      ),
                  ],
                  if (bound != null && bound.isNotEmpty) ...[
                    SwitchListTile(
                      title: const Text('设为全局默认'),
                      subtitle: const Text('新会话默认锁定此服务'),
                      value: defaultId == bound,
                      onChanged: (v) async {
                        await _setGlobalDefault(bound, v);
                        setSheet(() {});
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.public),
                      title: const Text('清空（纯公共）'),
                      onTap: () {
                        _bindSessionServer('');
                        setSheet(() {});
                      },
                    ),
                  ],
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

  /// D9：联调页/M1 任务循环入口收编（联调与任务循环仅 debug 构建，
  /// kDebugMode 门禁；检查更新为正式功能全构建保留）。
  /// 注：设置页入口已于 2026-10-16 收敛到 AppBar ⚙ 与侧边栏，本菜单不再重复。
  void _openDebugMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kDebugMode)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: const Text('网关/熔断联调'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const GatewayLoopDebugPage(),
                    ),
                  );
                },
              ),
            if (kDebugMode)
              ListTile(
                leading: const Icon(Icons.repeat_outlined),
                title: const Text('M1 任务循环（claim/apply）'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ClaimLoopPage(),
                    ),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('检查更新'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const UpdatePage(),
                  ),
                );
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
    _endpoints = allEndpoints;
    final unmounted = allEndpoints.length - endpoints.length;
    if (unmounted > 0) {
      _add(TrackNote('⊘ 有 $unmounted 项服务已卸载，未参与本次任务（设置页可重新挂载）', danger: false));
    }
    // T-trans-4：本地插件零配置发现（系统托管，不进手填配置）；与 HTTP 端点合并判定。
    final locals = <LocalPluginInfo>[];
    try {
      locals.addAll(await localPluginDiscovery.scan());
    } on Object {
      // 发现通道不可用（宿主未就绪）→ 视为无本地插件，不阻断 HTTP 端点装配。
    }
    if (endpoints.isEmpty && locals.isEmpty) {
      _add(TrackNote('⚠ 尚未配置任何 MCP 服务，且未发现本地插件', danger: true));
      // 未配置任何服务：直接进设置页（2026-10-16：⚙ 弹层已合并进设置页，
      // 此处同步改为整页 push；输入内容不丢，返回即可继续）。
      if (!mounted) return;
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
        ),
      );
      return;
    }
    _inputCtrl.clear();
    setState(() {
      _running = true;
      _pillLabel = 'connecting';
      _pillTone = CapsuleTone.l1;
      _autoFollow = true; // 新任务：回到底部并恢复自动跟随
    });
    _add(TrackUser(prompt));
    // T3b：会话懒建（首个任务起落盘；标题取首行截断）。
    _conversationId ??= await _convStore!.create(title: _titleFrom(prompt));
    _conversationTitle = _conversationTitle.isEmpty
        ? _titleFrom(prompt)
        : _conversationTitle;
    // P2-6（§3.6/G3）：会话级事实库懒建——In-band 捎带 session 域落点。
    final wsStates =
        _wsStates ??= WorkspaceStateStore.underSupportDir(support.path);
    final convId = _conversationId!;
    RefStore? refStore;
    final connections = <String, McpConnection>{}; // T4-5 收官：每 server 一条韧性连接（函数作用域，finally 可见）
    try {
      final memoryStore = MemoryStore.underSupportDir(support.path);
      // P2-6/P2-1b：In-band 提取分流——session 域落 workspace_states，
      // user/srv 域走 MemoryStore keyed 映射（G1）；胶囊撤销 = 对应 remove。
      final workspaceFilter = WorkspaceStreamFilter(
        onExtracted: (facts) {
          for (final f in facts) {
            final scope = f.normalizedScope;
            if (scope == null) continue; // 幻觉 scope 丢弃（G4）
            if (scope == 'session') {
              if (f.action == 'remove') {
                unawaited(wsStates.remove(convId, f.key));
              } else {
                unawaited(wsStates.upsert(convId, f.key, f.value));
              }
            } else {
              // P2-1b（G1）：user/srv 域走 MemoryStore keyed 映射——同 key
              // 覆盖不追加；remove 幂等。
              if (f.action == 'remove') {
                unawaited(memoryStore.removeFacts(f.key, scope: scope));
              } else {
                unawaited(memoryStore.upsertFacts(f.key, f.value, scope: scope));
              }
            }
            final capsule = TrackMemoryCapsule(key: f.key, value: f.value);
            capsule.onUndo = () {
              if (scope == 'session') {
                unawaited(wsStates.remove(convId, f.key));
              } else {
                unawaited(memoryStore.removeFacts(f.key, scope: scope));
              }
              if (!mounted) return;
              setState(() {
                capsule
                  ..undone = true
                  ..onUndo = null;
              });
            };
            _add(capsule);
          }
        },
      );
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
        _add(
          TrackNote(
            '✓ 已连接 ${ep.name}'
            '${caps.serverVersion != null ? ' v${caps.serverVersion}' : ''}',
            danger: false,
          ),
        );
        final face = McpToolFace(
          client: client,
          serverId: ep.id,
          opsLog: memoryStore, // N4 审计（remote 侧）
          onProgress: (tool, progress, total, message) {
            loopBox?.emitToolProgress(tool, progress, total, message);
            _setPill(
              total != null ? '$tool $progress/$total' : '$tool $progress',
              CapsuleTone.l1,
            );
          },
        );
        await face.listTools();
        faces[ep.id] = face;
        clients[ep.id] = client;
        connections[ep.id] = _startConnection(ep.id, client, face);
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
              _add(
                TrackNote('⚠ 未信任本地插件 ${info.serverTitle}，已跳过挂载', danger: true),
              );
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
                CapsuleTone.l1,
              );
            },
          );
          await face.listTools();
          faces[info.serverId] = face;
          clients[info.serverId] = client;
          connections[info.serverId] = _startConnection(info.serverId, client, face);
          summaries[info.serverId] =
              '${caps.serverName ?? info.serverTitle} (本地) ${caps.isTier1 ? 'Tier 1' : 'Tier 2'}';
          _add(
            TrackNote(
              '✓ 本地插件 ${info.serverTitle} ${caps.serverName ?? '?'} ｜ 自动挂载',
              danger: false,
            ),
          );
        } catch (e) {
          _add(TrackNote('⚠ 本地插件 ${info.serverTitle} 挂载失败: $e', danger: true));
        }
      }
      // T6：路由注册表（实例随会话建）+ 默认激活全部已挂载（保单服务回归）。
      // P1-4（§1.6）：tier 注入——private 端点进单一私有槽位模型，本地插件
      // 系统托管 = public 常驻（缺省公共）。
      final router = ToolRouter(
        faces: faces,
        privateServerIds: {
          for (final ep in endpoints)
            if (ep.tier == ServerPrivacyTier.private) ep.id,
        },
      );
      router.activatedServers.addAll(
        router.serverIds.where((id) => !router.privateServerIds.contains(id)),
      );
      // 会话绑定（v1）：本会话锁定的私有服务——未显式绑定则按默认回退
      // （全局钉选 isDefault → 首个启用的 private → null）。每轮重建 router
      // 时从此恢复，确保跨轮稳固锁定、免每轮重选。
      router.activePrivateServerId = _resolveBinding(endpoints);
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
        ...router.focusedSchemas(),
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
          // D5：恒 L2 弹卡、无豁免勾选；禁盲签由卡内兜底。点外部不关 =
          // 显式裁决（误触外部不等于默拒）。
          final r = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
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
      _add(TrackNote('✓ 引擎就绪：${engine.name}', danger: false));
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
          return sampling(
            method,
            params,
          ).whenComplete(() => _watcher?.samplingEnd());
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
              dir: await getApplicationDocumentsDirectory(),
            ),
            onMajorJump: (name, from, to) async {
              final r = await showDialog<bool>(
                context: context,
                builder: (dialogCtx) => AlertDialog(
                  title: Text('模板大版本更新：$name'),
                  content: Text(
                    '服务端模板 $from → $to（大版本跃迁）。\n重置回服务端最新版，还是保留本地覆写？',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx, false),
                      child: const Text('保留本地'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogCtx, true),
                      child: const Text('重置为服务端版'),
                    ),
                  ],
                ),
              );
              return r == true;
            },
          );
          for (final i in await cow.sync(entry.value, serverId: entry.key)) {
            if (i.content == null) continue;
            final skill = CowSyncService.toSkill(i, entry.key);
            final existing = skills.byName(skill.name);
            if (existing != null) {
              // 撞名（cow/<promptName> 全局唯一）：先到先得，跳过后者并通告用户
              // （design「撞名跳过 + 通告」——原为静默 continue，缺用户面通告）。
              _add(
                TrackNote(
                  '⚠ CoW 模板「${i.promptName}」重名：已采用 '
                  '${existing.serverId ?? '内置'} 版本，跳过 ${entry.key} 的同名模板',
                  danger: false,
                ),
              );
              continue;
            }
            try {
              skills.register(skill);
            } on ArgumentError catch (e) {
              _add(
                TrackNote(
                  '⚠ CoW Skill 注册跳过: ${i.promptName} — $e',
                  danger: true,
                ),
              );
            }
          }
        } on McpException catch (e) {
          _add(TrackNote('CoW 同步失败（Polyfill 降级为无模板注入）：$e', danger: false));
        }
      }
      final skillExecutor = SkillActivationExecutor(
        inner: hydration,
        registry: skills,
        opsLog: memoryStore,
      );
      // T6-3 JIT 两级发现：DiscoveryExecutor 挂最外层（SkillActivation 之前），
      // 拦截 get_connected_apps / activate_server_tools（L1 本地，不走确认卡）。
      final discovery = DiscoveryExecutor(
        router: router,
        inner: skillExecutor,
        serverSummaries: summaries,
        onActivation: (id) =>
            _add(TrackNote('✓ 已激活 $id 的工具', danger: false)),
      );
      // T4-5 收官：执行链经 _GuardedExecutor 路由——server 工具调用先过对应
      // McpConnection.guardExecute（离线窗口整体丢弃、不重放），JIT/本地工具透传。
      final guarded = _GuardedExecutor(connections, router, discovery);
      final loop = AgentLoop(
        engine: engine,
        executor: guarded,
        blockDelegate: _ChatBlock(this),
        refStore: refStore,
        refServerId: router.serverIds.isNotEmpty
            ? router.serverIds.first
            : 'goodshare',
        serverResolver: router.serverFor,
        toolsProvider: () => [
          ...router.focusedSchemas(),
          ...DiscoveryExecutor.staticSchemas(),
          skills.activationToolSchema(),
          ...MemoryToolExecutor.toolSchemas(),
        ],
      );
      loopBox = loop;
      _activeLoop = loop;
      _activeFace = faces[router.serverIds.first]; // 主服务面（Abort 取消目标）
      // M4-T2 记忆注入（D8 三层作用域）+ 超限可观测：作用域 = 全部已连服务。
      final memView = await memoryStore.memoryView(
        serverScopes: router.serverIds,
      );
      final memSection = await memoryPromptSection(
        memoryStore,
        serverScopes: router.serverIds,
      );
      // T6：静态首级摘要「## 已挂载服务」（自动生成，标注工具名前缀格式）。
      final mountedSection = _mountedServicesSection(router, summaries);
      _add(
        TrackNote(
          '✓ 已载入宿主记忆 ${memView.entries.length} 条'
          '${memView.truncated ? '（超预算丢弃 ${memView.droppedCount} 条）' : ''}',
          danger: false,
        ),
      );
      _setPill('thinking', CapsuleTone.l1);
      await for (final e in loop.run(
        // P1-3b（§8.1 断点 A）：静态角色+skills+mountedSection 为静态前缀
        // （挂 ephemeral 断点），记忆区走 systemTail 置尾——记忆增长不顶掉
        // 静态前缀缓存边界。P2-4（§3.2）：workspace_update 提取指令为固定
        // 静态区追加（含「tool-call 轮严禁输出」铁律）。
        systemPrompt: skills.composeSystemPrompt(
          _systemPrompt,
          connectedServerIds: router.serverIds,
        ) +
            mountedSection +
            WorkspaceStreamFilter.promptInstructions,
        systemTail: memSection,
        userPrompt: prompt,
        history: List.of(_history), // D11：上轮 transcript 续接
        workspaceFilter: workspaceFilter, // P2-6：In-band 分流+胶囊
        // P3-2（D-H/§9.1）：已让位私有域的历史调用发送边界合成桩脱敏。
        maskTool: (name) {
          final sid = router.serverFor(name);
          return sid != null &&
              router.privateServerIds.contains(sid) &&
              router.activePrivateServerId != sid;
        },
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
          case LoopToolProgress(
            :final call,
            :final progress,
            :final total,
            :final message,
          ):
            final entry = _activeCallEntry;
            if (entry != null && entry.tool == call.name) {
              setState(() {
                final tail = message == null ? '' : ' · $message';
                entry.progressNote = total != null
                    ? '$progress/$total$tail'
                    : '$progress$tail';
              });
            }
            _watcher?.onProgressFrame();
          case LoopToolCallFinished(:final call, :final result):
            final rejected = result.content.contains('"user_rejected"');
            final entry = _activeCallEntry;
            final phase = result.isError
                ? CallCardPhase.failed
                : CallCardPhase.success;
            if (entry != null && entry.tool == call.name) {
              // 真实结果优先于 Abort 的 cancelled 标记（在途调用完成后照常回填）
              setState(() {
                entry
                  ..phase = phase
                  ..preview = _preview(result.content)
                  ..resultText = result.content
                  ..progressNote = null;
              });
            } else {
              _add(
                TrackCall(tool: call.name)
                  ..phase = phase
                  ..preview = _preview(result.content)
                  ..resultText = result.content,
              );
            }
            _activeCallEntry = null;
            _watcher?.stop();
            _setPill(rejected ? 'rejected' : 'idle', CapsuleTone.l1);
          case LoopFinished(:final text, :final transcript):
            _history
              ..clear()
              ..addAll(transcript); // D11：下轮续接（未配对尾巴已截断）
            _appendText(text.isEmpty ? '' : '\n');
            _add(TrackNote('✓ 任务完成', danger: false));
            _setPill('done', CapsuleTone.idle);
            // §4.1：L1 药丸完成 → 极轻微 tick
            unawaited(HapticFeedback.selectionClick());
        }
      }
      // 会话绑定捕获：模型可能在本轮经 use_server/activate 改写私有槽位，
      // 收尾前落到会话元数据，使该会话后续轮次稳固锁定（免每轮重选）。
      final slot = router.activePrivateServerId;
      if (slot != null) {
        _activePrivateServerId = slot;
      } else if (_activePrivateServerId != null &&
          _activePrivateServerId!.isNotEmpty) {
        _activePrivateServerId = ''; // 曾绑定 → 本轮 use_server('all') 清空 = 显式公共
      }
    } on Object catch (e) {
      _add(TrackNote('✕ 任务中断：$e', danger: true));
      _setPill('failed', CapsuleTone.danger);
    } finally {
      _watcher?.stop();
      _watcher = null;
      _activeLoop = null;
      _activeFace = null;
      _activeCallEntry = null;
      // P0 尾帧铁律（stream-perf §3）：快照与终态渲染前强制清空流控缓冲——
      // 覆盖正常收尾 / Abort / 异常三条路径，缓冲期内到达的尾帧不得丢失。
      _streamBuf.flush();
      for (final c in connections.values) {
        c.stop(); // T4-5 收官：停心跳/监听，无泄漏
      }
      await refStore?.expireAll(); // §9：Session 结束直清临时文件
      refStore?.dispose();
      await _persistConversation(); // T3b：Run 收尾快照（含 Cancelled 终态）
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
      _runStartedAt = null;
      if (mounted) setState(() => _running = false);
    }
  }

  /// T4-5 收官：为某 server 建韧性连接并接线断连/积压/资源变更三类回调 → 操作轨
  /// TrackNote；心跳/重连由 [McpConnection.start] 接管。返回已 start 的连接。
  McpConnection _startConnection(String serverId, McpClient client, McpToolFace face) {
    final conn = McpConnection(client: client, face: face, serverId: serverId)
      ..onDisconnectReport = (r) {
        if (!mounted) return;
        _add(TrackNote(
          '⚠ 连接中断，在途 ${r.inFlightCancelled} 个请求已取消，不重放',
          danger: true,
        ));
      }
      ..onBacklogReport = (r) {
        if (!mounted) return;
        _add(TrackNote(
          '⚠ 连接中断，积压 ${r.droppedCount} 个请求已丢弃，不重放',
          danger: true,
        ));
      }
      ..onResourceUpdated = (uri) {
        if (!mounted) return;
        _add(TrackNote(
          '${McpConnection.resourceStaleMessage}（$uri）',
          danger: false,
        ));
      };
    conn.start();
    return conn;
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
    // §4.1：Abort → 重度确认震动
    unawaited(HapticFeedback.heavyImpact());
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

  /// D13 侧边栏（会话维度）：会话历史列表 + 设置/记忆看板入口（服务区随 T6 预留）。
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
                    child: Text(
                      '会话',
                      style: TextStyle(
                        fontFamily: t.monoFamily,
                        fontSize: Fsz.body,
                        color: t.terminalMuted,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      if (!_guardRunning('新建会话')) return;
                      _newConversation();
                    },
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
                      child: Text(
                        '暂无历史会话\n（首次发送任务后自动保存）',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: Fsz.note,
                          color: t.terminalMuted,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _conversations.length,
                      itemBuilder: (context, i) {
                        final meta = _conversations[i];
                        return ListTile(
                          leading: Icon(
                            Icons.chat_bubble_outline,
                            size: 18,
                            color: t.terminalMuted,
                          ),
                          title: Text(
                            meta.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _fmtTime(meta.updatedAt),
                            style: const TextStyle(fontSize: Fsz.micro),
                          ),
                          selected: meta.id == _conversationId,
                          onTap: () => _loadConversation(meta),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: '删除会话',
                            onPressed: () => unawaited(_deleteConversation(meta)),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsPage(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('记忆看板'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MemoryBoardPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _preview(String content) {
    final lines = content.trim().split('\n');
    final head = lines.take(2).join(' · ');
    return head.length > 120 ? '${head.substring(0, 120)}…' : head;
  }

  /// 胶囊标签人话化：内部英文相位 → 用户可读中文；工具名等宽原名保持透传。
  static String _pillText(String label) => switch (label) {
    'idle' => '空闲',
    'connecting' => '连接中',
    'thinking' => '思考中',
    'done' => '已完成',
    'failed' => '失败',
    'rejected' => '已拒绝',
    'breaker' => '熔断排查',
    'fence' => '围栏拦截',
    _ => label,
  };

  /// 输入条内嵌状态带（§3.1：状态做在输入框本身上沿，不挤占文本区）。
  /// idle 由调用处将高度收 0（AnimatedContainer 平滑），运行态展开为极简状态带：
  /// 1px hairline 分隔 + 呼吸点 + 等宽相位；文本输入区始终全宽（D+B 改造）。
  /// 已绑定私有服务时，状态带常驻显示上下文胶囊（药丸内弱感知）；
  /// 公共态（有可绑定端点）显示「公共」胶囊。**胶囊可点 → 打开会话上下文菜单**，
  /// 因此即便输入中「+」隐藏，也能随时切换绑定（解决输入一半想切服务的痛点）。
  Widget _statusStrip(ConsoleTokens t) {
    final color = switch (_pillTone) {
      CapsuleTone.idle => t.terminalMuted,
      CapsuleTone.l1 => t.l1Info,
      CapsuleTone.l2 => t.l2Warn,
      CapsuleTone.danger => t.danger,
    };
    final ctxId = _activePrivateServerId;
    final hasCtx = ctxId != null && ctxId.isNotEmpty;
    final hasLocal = _localPlugins.isNotEmpty;
    // 绑定私有端点 / 本地插件 均按「私有」呈现（锁形 + l1 色），不视作公有；
    // 三者任一即显示上下文胶囊（均可点开菜单）。
    final isPrivate = hasCtx || hasLocal;
    final showChip = isPrivate || _endpoints.isNotEmpty;
    Widget? chip;
    if (showChip) {
      final chipColor = isPrivate ? t.l1Info : t.terminalMuted;
      final chipIcon = isPrivate ? Icons.lock_outline : Icons.public;
      final chipText = hasCtx
          ? _endpointName(ctxId)
          : (hasLocal ? '本地×${_localPlugins.length}' : '公共');
      chip = GestureDetector(
        onTap: _openComposerMenu,
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: chipColor.withValues(alpha: 0.16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                chipIcon,
                size: 11,
                color: chipColor,
              ),
              const SizedBox(width: 4),
              Text(
                chipText,
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.micro,
                  color: chipColor,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.hairline, width: 1)),
      ),
      child: Row(
        children: [
          ? chip,
          // §4.2 紧凑动效：状态点颜色随相位过渡（150~200ms，禁 Spring）。
          AnimatedContainer(
            width: 7,
            height: 7,
            duration: t.fastDuration,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _pillText(_pillLabel),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.micro,
                color: color,
              ),
            ),
          ),
          if (_running && _runStartedAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                _fmtElapsed(_runStartedAt!),
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.micro,
                  color: color,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 状态带已耗时格式化（mm:ss），自 [_runStartedAt] 起算，供运行态计时显示。
  static String _fmtElapsed(DateTime start) {
    final s = DateTime.now().difference(start).inSeconds;
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  /// Run 进行中离开拦截(破坏性防护 P0):系统返回/手势先弹确认——确认则
  /// abort 后退出,否则留在页内。非运行态不拦截(零摩擦)。
  Future<bool> _confirmLeaveWhileRunning() async {
    if (!_running) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('任务运行中'),
        content: const Text('离开将中止当前任务,在途调用已发出的结果仍会回填。确定离开?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('留下'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('中止并离开'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    _abort();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmLeaveWhileRunning();
        if (!leave) return;
        if (!mounted) return;
        Navigator.of(this.context).pop();
      },
      child: Scaffold(
        drawer: _buildDrawer(),
        appBar: AppBar(
          // 会话标题进 AppBar（D13 多会话：切会话后知道自己所在会话）。
          title: Text(
            _conversationTitle.isEmpty ? 'GoodHub' : _conversationTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: '设置',
              onPressed: () {
                if (!_guardRunning('打开设置')) return;
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsPage(),
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: Icon(kDebugMode ? Icons.bug_report_outlined : Icons.system_update_alt),
              tooltip: kDebugMode ? '调试入口' : '检查更新',
              onPressed: () {
                if (!_guardRunning('打开菜单')) return;
                _openDebugMenu();
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              // 上翻看历史时不劫持滚动；离底时给「回到最新」浮钮。
              child: Stack(
                children: [
                  DualTrackStream(
                    entries: _track,
                    controller: _scrollCtrl,
                    emptyHint: '下达自然语言任务，宿主调度已挂载服务完成\n'
                        '（首次使用请先在 ⚙ 设置页里配置服务端点）',
                  ),
                  if (!_autoFollow && _track.isNotEmpty)
                    Positioned(
                      right: 16,
                      bottom: 8,
                      child: FloatingActionButton.small(
                        heroTag: 'chat-scroll-bottom',
                        tooltip: '回到最新',
                        onPressed: () {
                          _scrollCtrl
                              .animateTo(
                                _scrollCtrl.position.maxScrollExtent,
                                duration: t.fastDuration,
                                curve: Curves.easeOut,
                              )
                              .then((_) {
                                if (mounted) setState(() => _autoFollow = true);
                              });
                        },
                        child: const Icon(Icons.arrow_downward),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Center(
                // 桌面宽屏下输入区居中限宽，避免全宽拉伸
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                    // 底部控制集群：药丸输入条（状态带 + 相位 + 输入 + 主操作钮）；
                    // 运行态发送钮形变复用为「中止」键（§3.1：单一主操作槽切换
                    // 发送↔中止，避免右侧另起红键挤占输入区，省一条常驻空行）。
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: t.hairline),
                              color: Theme.of(context).cardColor,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // §3.1 状态做在输入框本身上沿（框内顶部状态带），idle
                                // 高度收 0，运行态平滑展开；文本输入区始终全宽（D+B 改造）。
                                AnimatedContainer(
                                  duration: t.fastDuration,
                                  curve: Curves.easeOut,
                                  height: (_running || _hasContext || _endpoints.isNotEmpty)
                                      ? 30
                                      : 0,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: const BoxDecoration(
                                    borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(24),
                                    ),
                                  ),
                                  child: _statusStrip(t),
                                ),
                                Row(
                                  children: [
                                      IconButton(
                                        icon: const Icon(Icons.add),
                                        tooltip: '会话上下文（绑定 MCP 服务）',
                                        onPressed: _openComposerMenu,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                            minWidth: 36, minHeight: 36),
                                      ),
                                    Expanded(
                                      child: TextField(
                                        controller: _inputCtrl,
                                        // 运行中保持可预输入（发送由按钮/_guard 挡 running）。
                                        minLines: 1,
                                        maxLines: 4,
                                        textInputAction: TextInputAction.send,
                                        decoration: InputDecoration(
                                          hintText: _running
                                              ? '生成中…可先预输入下一轮'
                                              : '描述任务…（Enter 发送；如：列出今天的待办）',
                                          border: InputBorder.none,
                                          contentPadding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                                        ),
                                        onSubmitted: (_) {
                                          // 生成中静默拦截：发送钮已形变为「中止」，键盘回车
                                          // 不再弹 Toast 打扰（行业惯例：停止为即时动作）。
                                          if (_running) return;
                                          _send();
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    // §3.1 复用发送钮：运行态形变为主操作「中止」键，
                                    // 单一槽位内切换 发送↔中止，避免右侧另起红键挤占输入区。
                                    IconButton.filledTonal(
                                      style: IconButton.styleFrom(
                                        minimumSize: const Size(36, 36),
                                        padding: EdgeInsets.zero,
                                        foregroundColor:
                                            _running ? t.dangerDeep : null,
                                      ),
                                      onPressed: _running ? _abort : _send,
                                      tooltip: _running ? '中止' : '发送',
                                      icon: Icon(
                                        _running
                                            ? Icons.stop
                                            : Icons.arrow_upward,
                                        size: 20,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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
