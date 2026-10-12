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

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../core/errors/mcp_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../mcp/mcp_client.dart';
import '../mcp/sampling.dart';
import '../sandbox/conversation_store.dart';
import '../sandbox/memory_store.dart';
import 'components/call_card.dart';
import 'components/cross_source_consent_card.dart';
import 'components/dual_track_stream.dart';
import 'components/status_capsule.dart';
import 'tokens/console_tokens.dart';
import 'components/stuck_watcher.dart';
import 'gateway_loop_debug_page.dart';
import 'services_hall_page.dart';
import 'claim_loop_page.dart';

/// 连接配置持久化键（§4 过渡态：T5 服务大厅 Server 节点面板落地后迁移收编）。
const _kEndpointKey = 'chat.mcp.endpoint';
const _kApiKeyKey = 'chat.mcp.apiKey';

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

  // 连接配置（内存镜像；持久化见 [_loadConfig]）
  var _endpoint = '';
  var _apiKey = '';

  // 会话状态（页面 = 一个会话，§15）
  final List<CloudChatMessage> _history = [];
  SkillRegistry? _skills;
  DegradationController? _degradation;
  final SamplingQuota _samplingQuota = SamplingQuota(); // D3：重启清零

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
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _endpoint = sp.getString(_kEndpointKey) ?? '';
      _apiKey = sp.getString(_kApiKeyKey) ?? '';
    });
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

  Future<void> _saveConfig(String endpoint, String apiKey) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kEndpointKey, endpoint);
    await sp.setString(_kApiKeyKey, apiKey);
    if (!mounted) return;
    setState(() {
      _endpoint = endpoint;
      _apiKey = apiKey;
    });
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

  Future<void> _openSettings() async {
    final endpointCtrl = TextEditingController(text: _endpoint);
    final keyCtrl = TextEditingController(text: _apiKey);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('连接配置',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('服务端点与令牌暂存于此（T5 服务大厅收编）',
                style: TextStyle(
                    fontSize: 12, color: consoleTokens(ctx).terminalMuted)),
            const SizedBox(height: 12),
            TextField(
              controller: endpointCtrl,
              decoration: const InputDecoration(
                labelText: 'MCP Endpoint（须含 /mcp 路径）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: keyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'X-Api-Key（goodshare「MCP 服务」页可查，可留空）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 12),
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
    // 仅实际变更时通告（防「打开即存」噪音——关闭弹层也走保存路径）；
    // 旧值先取（_saveConfig 会刷新 state）。
    final oldEndpoint = _endpoint;
    final oldKey = _apiKey;
    await _saveConfig(endpointCtrl.text.trim(), keyCtrl.text.trim());
    final changed =
        endpointCtrl.text.trim() != oldEndpoint || keyCtrl.text.trim() != oldKey;
    endpointCtrl.dispose();
    keyCtrl.dispose();
    if (mounted && changed) {
      _add(TrackNote('✓ 连接配置已保存（${_endpoint.isEmpty ? '端点为空' : _endpoint}）',
          danger: false));
    }
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
    if (_endpoint.isEmpty) {
      _add(TrackNote('⚠ 尚未配置服务端点（右上角 ⚙ 设置）', danger: true));
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
      // —— 执行链装配（生产子集；与联调页同构，T5 统一装配线收编）——
      final client = McpClient(
        baseUrl: _endpoint,
        apiKey: _apiKey.isEmpty ? null : _apiKey,
      );
      final caps = await client.negotiate();
      _add(TrackNote(
          '✓ ${caps.serverName ?? '?'} v${caps.serverVersion ?? '?'} ｜ '
          '${caps.isTier1 ? 'Tier 1' : 'Tier 2（vanilla，Polyfill 接管）'}',
          danger: false));
      AgentLoop? loopBox;
      final memoryStore = MemoryStore.underSupportDir(
          (await getApplicationSupportDirectory()).path);
      final face = McpToolFace(
        client: client,
        opsLog: memoryStore, // N4 审计（remote 侧）
        onProgress: (tool, progress, total, message) {
          loopBox?.emitToolProgress(tool, progress, total, message);
          _setPill(
              total != null ? '$tool $progress/$total' : '$tool $progress',
              CapsuleTone.l1);
        },
      );
      final schemas = await face.listTools();
      // M4-T2 记忆工具面挂 Gateway 内侧：update_memory 先过 L2 裁决再执行。
      final memoryTool = MemoryToolExecutor(inner: face, store: memoryStore);
      final gateway = PermissionGateway(
        inner: memoryTool,
        delegate: _ChatGate(this),
        onNotice: (n) {
          _setPill(n.toolName, CapsuleTone.l1);
          unawaited(HapticFeedback.selectionClick());
        },
      );
      gateway.loadCatalog([...schemas, ...MemoryToolExecutor.toolSchemas()]);
      refStore = RefStore(
        cacheDir: await getTemporaryDirectory(),
        gcInterval: null, // 短会话，finally 即焚
      );
      final hydration = HydratingExecutor(
        inner: gateway,
        refStore: refStore,
        targetServerId: face.serverId,
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
      final sampling = samplingRequestHandler(
        engine: engine,
        quota: _samplingQuota,
        serverKey: face.serverId,
      );
      client.onServerRequest = (method, params) {
        _watcher?.samplingBegin();
        return sampling(method, params).whenComplete(() => _watcher?.samplingEnd());
      };
      // 会话粒度 SkillRegistry（§15）：激活集跨 Run 保留（同页多轮共享）。
      final skills = _skills ??= SkillRegistry()..registerAll(builtinSkills());
      if (caps.hasPrompts) {
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
          for (final i in await cow.sync(client, serverId: face.serverId)) {
            if (i.content == null) continue;
            final skill = CowSyncService.toSkill(i, face.serverId);
            // 注册表会话粒度（§15）——跨 Run 重同步幂等跳过；SkillRegistry 禁
            // 隐式覆盖（M2.5 口径），模板真更新走会话重启/覆写通道。
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
      final loop = AgentLoop(
        engine: engine,
        executor: skillExecutor,
        blockDelegate: _ChatBlock(this),
        refStore: refStore,
        refServerId: face.serverId,
      );
      loopBox = loop;
      _activeLoop = loop;
      _activeFace = face;
      // M4-T2 记忆注入（D8 三层作用域）+ 超限可观测。
      final memView = await memoryStore.memoryView(serverScopes: [face.serverId]);
      final memSection =
          await memoryPromptSection(memoryStore, serverScopes: [face.serverId]);
      _add(TrackNote(
          '记忆注入：${memView.entries.length} 条'
          '${memView.truncated ? '（预算外丢弃 ${memView.droppedCount} 条）' : ''}',
          danger: false));
      _setPill('thinking', CapsuleTone.l1);
      await for (final e in loop.run(
        systemPrompt: skills.composeSystemPrompt(
                _systemPrompt, connectedServerIds: [face.serverId]) +
            memSection,
        userPrompt: prompt,
        history: List.of(_history), // D11：上轮 transcript 续接
        tools: [
          ...schemas,
          skills.activationToolSchema(),
          ...MemoryToolExecutor.toolSchemas(),
        ],
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
            const ListTile(
              leading: Icon(Icons.inventory_2_outlined),
              title: Text('记忆看板'),
              enabled: false,
              subtitle: Text('M4-T5 落地'),
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
