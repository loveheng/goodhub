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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'trust_plugin_dialog.dart';

import 'package:path_provider/path_provider.dart';

import '../app/service_directory.dart';
import '../coordinator/agent_loop.dart';
import '../coordinator/conversation_archive.dart';
import '../coordinator/degradation_controller.dart';
import '../coordinator/fenced_cloud_engine.dart';
import '../coordinator/mcp_runtime.dart';
import '../llm/cloud/cloud_llm.dart';
import '../coordinator/memory_kernel.dart';
import '../coordinator/permission_gateway.dart';
import '../coordinator/workspace_stream_filter.dart';
import '../coordinator/skill_registry.dart';
import '../coordinator/tool_breaker.dart';
import '../coordinator/tool_router.dart';
import '../mcp/connection_manager.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/trusted_plugins.dart';
import '../mcp/server_endpoints.dart';
import '../gateway/gateway_controller.dart';
import '../sandbox/conversation_store.dart';
import '../sandbox/memory_store.dart';
import '../sandbox/workspace_state_store.dart';
import 'components/call_card.dart';
import 'components/cross_source_consent_card.dart';
import 'components/conversation_drawer.dart';
import 'components/dual_track_stream.dart';
import 'components/session_context_sheet.dart';
import 'components/status_capsule.dart';
import 'components/status_strip.dart';
import 'components/stream_text_buffer.dart';
import 'tokens/console_tokens.dart';
import 'components/stuck_watcher.dart';
import 'settings_page.dart';

/// 连接配置持久化（T6-2）：改走 [ServerEndpointStore]（多端点 JSON + apiKey
/// 走安全存储）；旧单端点 SharedPreferences 由该 store 在首次 load 时迁移。

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    this.endpointStoreOverride,
    this.engineOverride,
  });

  /// 测试注入位（window-kernel-split 移交 misc#17）：null = 生产路径
  /// （应用支持目录/mcp_servers.json，与设置页 ⚙ 设置同一文件）；测试传假
  /// store 免去文件系统依赖，修 chat_page_smoke_test 可测性债。
  final ServerEndpointStore? endpointStoreOverride;

  /// 测试注入位：null = 生产路径（[McpRuntime.assemble] 默认混合引擎
  /// [assembleDefaultHybridEngine]）；测试传假引擎覆盖发送链路。
  final CloudLlmEngine? engineOverride;

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

  // 端点 store 注入位（misc#17）：测试传 [endpointStoreOverride] 免去文件系统
  // 依赖；生产路径经 [serverEndpointStore] 工厂（单一入口，见
  // lib/app/service_directory.dart）。缓存到 [_epStore] 保证单一实例。
  ServerEndpointStore? _epStore;
  Future<ServerEndpointStore> _resolveEpStore() async =>
      _epStore ??= widget.endpointStoreOverride ?? await serverEndpointStore();

  // 会话状态（页面 = 一个会话，§15）：活态收编进 ConversationSession
  // （window-kernel-split 步 3-T4——transcript/绑定写回走其契约方法，
  // 配额/激活集/降级判据/事实库随会话实例生灭，切会话即重置）。
  ConversationSession _session = ConversationSession();

  // 会话持久化（archive-memory-claim 步 1）：落盘事实 owner = ConversationArchive
  // 内核（懒建/快照组装/恢复/删除门面），窗口只持侧边栏列表投影。
  ConversationArchive? _archive;

  var _conversations = <ConversationMeta>[];
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
  McpAssembly? _activeAssembly; // Run 期句柄（Abort/finally 释放；步 1 内核化后窗口只持句柄）
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
    await (await _resolveEpStore()).load(); // 触发旧配置迁移
  }

  // ---------------------------------------------------------------------------
  // 会话持久化（M4-T3b）：侧边栏 + 恢复/切换/新建/删除
  // ---------------------------------------------------------------------------

  Future<void> _initConversations() async {
    final support = await getApplicationSupportDirectory();
    _archive = ConversationArchive.underSupportDir(support.path);
    // SamplingQuota 恢复（杀进程重启不清零；切会话仍重置=行为变更①）。
    final quota = await _archive!.loadQuota();
    if (quota != null && mounted) {
      setState(() => _session = ConversationSession(samplingQuota: quota));
    }
    await _refreshConversations();
  }

  Future<void> _refreshConversations() async {
    final archive = _archive;
    if (archive == null) return;
    final list = await archive.list();
    if (!mounted) return;
    setState(() => _conversations = list);
  }

  /// Run 收尾/绑定即存快照：save 组装与落盘在 Archive 内核；失败 DEGRADE
  /// 留痕返 false，窗口出轨道提示（视图态可观测）。
  Future<void> _persistCurrent() async {
    final archive = _archive;
    if (archive == null || !archive.hasCurrent) return;
    final ok = await archive.saveCurrent(
      trackJson: TrackEntryCodec.encode(_track),
      session: _session,
    );
    if (!ok) _add(TrackNote('⚠ 会话快照保存失败（见日志）', danger: true));
    // 配额落盘（AM1）：随 Run 收尾一并持久化，防杀进程刷新额度。
    await archive.saveQuota(_session.samplingQuota);
    await _refreshConversations();
  }

  /// 切换/删除前的当前会话保底。
  Future<void> _persistIfAny() async {
    if (_archive?.hasCurrent ?? false) await _persistCurrent();
  }

  /// 恢复/新建后重置会话态：激活集属会话（§15），跨会话必须重开。
  /// 步 3-T4：五字段手工枚举消失——新会话 = 新 [ConversationSession] 实例
  /// （transcript/绑定/激活集/降级/事实库/配额随之全部归零，
  /// **切会话即重置配额** = 行为变更①，原为页面级「重启清零」）。
  void _resetSessionState() {
    setState(() {
      _track.clear();
      _session = ConversationSession();
      _archive?.resetCurrent();
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
    final snap = await _archive?.load(meta.id);
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
      _archive?.adoptSnapshot(snap); // 当前 id/title 归 Archive 内核
      _session.bindPrivateServer(snap.activePrivateServerId);
      _session.replaceTranscript(
          ConversationStore.decodeMessages(snap.messages)); // 全量替换
      _track.addAll(TrackEntryCodec.decode(snap.track));
    });
    // MO6 阶段一：切换会话 → 网关投影同步宿主当前激活私有域（PC 只读镜像）。
    GatewayController.shared.syncActivePrivate(_session.activePrivateServerId);
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
    await _archive?.delete(meta.id);
    if (_archive?.currentId == meta.id) _resetSessionState();
    await _refreshConversations();
  }

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
    final all = await (await _resolveEpStore()).load();
    // 本地插件零配置自动发现（系统托管、始终挂载；与 _send 装配同口径）。
    // 通道不可用（宿主未就绪）按空目录，不阻断 HTTP 端点装配。
    final locals = <LocalPluginInfo>[];
    try {
      locals.addAll(await localPluginDiscovery.scan());
    } on Object {
      // 发现通道不可用：视为无本地插件。
    }
    if (!mounted) return;
    final bound = _session.activePrivateServerId ?? _resolveBinding(all);
    setState(() {
      _endpoints = all;
      _localPlugins = locals;
      _session.bindPrivateServer(bound);
    });
    // MO6 阶段一：端点预热/默认锁定后 → 网关投影同步宿主当前激活私有域。
    GatewayController.shared.syncActivePrivate(_session.activePrivateServerId);
  }

  /// 是否处于"已绑定某私有服务"的弱感知态（用于状态带胶囊）。
  bool get _hasContext =>
      _session.activePrivateServerId != null &&
      _session.activePrivateServerId!.isNotEmpty;

  /// 会话绑定默认回退：未显式绑定时 → 全局钉选 isDefault → 首个启用的 private
  /// → null（纯公共）。已显式绑定（含 '' 显式公共）则直接用。
  String? _resolveBinding(List<ServerEndpoint> eps) {
    final bound = _session.activePrivateServerId;
    if (bound != null) return bound.isEmpty ? null : bound;
    String? firstPrivate;
    for (final e in eps) {
      if (e.tier != ServerPrivacyTier.private) continue;
      if (e.isDefault) return e.id; // 全局钉选优先
      firstPrivate ??= e.id;
    }
    return firstPrivate;
  }

  /// 即时绑定（composer menu 调用）：写会话态（三态写回契约）+ 落会话元数据。
  void _bindSessionServer(String? serverId) {
    setState(() => _session.bindPrivateServer(serverId));
    // MO6 阶段一：菜单即时绑定/清空 → 网关投影同步宿主当前激活私有域。
    GatewayController.shared.syncActivePrivate(_session.activePrivateServerId);
    unawaited(_persistCurrent());
  }

  /// 全局默认钉选写回（单选）：更新 mcp_servers.json 并刷新缓存。
  Future<void> _setGlobalDefault(String serverId, bool on) async {
    final epStore = await _resolveEpStore();
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
    for (final lp in _localPlugins) {
      if (lp.serverId == id) {
        return lp.serverTitle.isNotEmpty ? lp.serverTitle : lp.serverId;
      }
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
        // live 快照每次 setSheet 重建重读；交互经回调回页面（步 4 Epic C 外提）
        builder: (ctx, setSheet) => SessionContextSheetBody(
          t: t,
          bound: _session.activePrivateServerId,
          privEndpoints: _endpoints
              .where((e) => e.enabled && e.tier == ServerPrivacyTier.private)
              .toList(),
          localPlugins: _localPlugins,
          defaultId: _defaultId(),
          endpointName: _endpointName,
          onBind: (id) {
            _bindSessionServer(id);
            setSheet(() {});
          },
          onClear: () {
            _bindSessionServer('');
            setSheet(() {});
          },
          onSetDefault: (v) async {
            await _setGlobalDefault(_session.activePrivateServerId!, v);
            setSheet(() {});
          },
          onDone: () => Navigator.pop(ctx),
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
    // （support 目录另供 WorkspaceStateStore / MemoryStore 落点。）
    final support = await getApplicationSupportDirectory();
    final epStore = await _resolveEpStore();
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
      // 未配置任何服务：直接进设置页（2026-10-16：设置页入口收敛到侧边栏，
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
    // T3b：会话懒建（首个任务起落盘；标题截取策略在 Archive 内核）。
    await _archive!.ensureCurrent(prompt: prompt);
    // P2-6（§3.6/G3）：会话级事实库懒建——In-band 捎带 session 域落点。
    _session.bindWsStates(WorkspaceStateStore.underSupportDir(support.path));
    final convId = _archive!.currentId!;
    McpAssembly? assembly; // Run 级句柄：finally 统一释放（内核持资源谁释放）
    try {
      final memoryStore = MemoryStore.underSupportDir(support.path);
      // 步 2（archive-memory-claim）：In-band 提取面认领进 Memory 内核——
      // session 域落 workspace_states（所有权仍在 Session，按调用传入），
      // user/srv 域走 MemoryStore keyed 映射（G1）；UI 胶囊经 onCapsule 回传
      // 窗口（渲染与撤销挂载留窗口，undo 已含落盘回滚）。
      final workspaceFilter = MemoryKernel(memoryStore).buildFilter(
        wsStates: _session.wsStates,
        conversationId: convId,
        onCapsule: (key, value, undo) {
          final capsule = TrackMemoryCapsule(key: key, value: value);
          capsule.onUndo = () {
            undo(); // 落盘回滚（内核侧闭包）
            if (!mounted) return;
            setState(() {
              capsule
                ..undone = true
                ..onUndo = null;
            });
          };
          _add(capsule);
        },
      );
      // 步 1（window-kernel-split）：装配段迁入 McpRuntime（内核）；本页收集
      // 会话快照 + 实现端口。本地插件信任闸门是 UI（信任卡片）——窗口先裁再传，
      // 内核只挂载（§7.1：不为此造第 10 个端口）。
      final mountedLocals = <LocalPluginInfo>[];
      for (final info in locals) {
        if (info.serverId.isEmpty) continue;
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
        mountedLocals.add(info);
      }
      _watcher = StuckWatcher(onStuck: _markActiveCallStuck);
      // 步 3-T4：激活集/降级判据懒建收编进 session（新会话 = 新实例 = 重开）。
      _session.bindSkills(
          _session.skills ?? (SkillRegistry()..registerAll(builtinSkills())));
      _session.bindDegradation(
          _session.degradation ?? DegradationController());
      assembly = await const McpRuntime().assemble(
        engine: widget.engineOverride,
        context: SessionContext(
          activePrivateServerId: _session.activePrivateServerId,
          conversationId: convId,
          degradation: _session.degradation,
          transcript: _session.transcript,
          wsStates: _session.wsStates,
        ),
        endpoints: endpoints,
        locals: mountedLocals,
        apiKeyReader: epStore.apiKey,
        memoryStore: memoryStore,
        skills: _session.skills!,
        delegates: RuntimeDelegates(
          gateDelegate: _ChatGate(this),
          fenceDelegate: _ChatFence(this), // D4 有人值守拦截卡
          blockDelegate: _ChatBlock(this),
          consentDelegate: (handle, from, to, preview) async {
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
          majorJumpDelegate: (name, from, to) async {
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
          onNote: (message, {danger = false}) =>
              _add(TrackNote(message, danger: danger)),
          onProgress: (tool, progress, total, message) {
            _setPill(
              total != null ? '$tool $progress/$total' : '$tool $progress',
              CapsuleTone.l1,
            );
          },
          onNotice: (n) {
            _setPill(n.toolName, CapsuleTone.l1);
            unawaited(HapticFeedback.selectionClick());
          },
          connectionReport: (report) {
            if (!mounted) return;
            switch (report.kind) {
              case ConnectionReportKind.disconnect:
                _add(TrackNote(
                  '⚠ 连接中断，在途 ${report.inFlightCancelled} 个请求已取消，不重放',
                  danger: true,
                ));
              case ConnectionReportKind.backlog:
                _add(TrackNote(
                  '⚠ 连接中断，积压 ${report.droppedCount} 个请求已丢弃，不重放',
                  danger: true,
                ));
              case ConnectionReportKind.resourceUpdated:
                _add(TrackNote(
                  '${McpConnection.resourceStaleMessage}（${report.uri}）',
                  danger: false,
                ));
            }
          },
        ),
        quota: _session.samplingQuota,
        onSamplingBegin: () => _watcher?.samplingBegin(),
        onSamplingEnd: () => _watcher?.samplingEnd(),
      );
      _activeAssembly = assembly;
      final router = assembly.router;
      // M4-T2 记忆注入（D8 三层作用域）+ 超限可观测：作用域 = 全部已连服务。
      final memView = await memoryStore.memoryView(
        serverScopes: router.serverIds,
      );
      final memSection = await memoryPromptSection(
        memoryStore,
        serverScopes: router.serverIds,
      );
      // T6：静态首级摘要「## 已挂载服务」（自动生成，标注工具名前缀格式）。
      final mountedSection = _mountedServicesSection(router, assembly.serverSummaries);
      _add(
        TrackNote(
          '✓ 已载入宿主记忆 ${memView.entries.length} 条'
          '${memView.truncated ? '（超预算丢弃 ${memView.droppedCount} 条）' : ''}',
          danger: false,
        ),
      );
      _setPill('thinking', CapsuleTone.l1);
      await for (final e in assembly.loop.run(
        // P1-3b（§8.1 断点 A）：静态角色+skills+mountedSection 为静态前缀
        // （挂 ephemeral 断点），记忆区走 systemTail 置尾——记忆增长不顶掉
        // 静态前缀缓存边界。P2-4（§3.2）：workspace_update 提取指令为固定
        // 静态区追加（含「tool-call 轮严禁输出」铁律）。
        systemPrompt: _session.skills!.composeSystemPrompt(
          _systemPrompt,
          connectedServerIds: router.serverIds,
        ) +
            mountedSection +
            WorkspaceStreamFilter.promptInstructions,
        systemTail: memSection,
        userPrompt: prompt,
        history: List.of(_session.transcript), // D11：上轮 transcript 续接
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
            // 步 3 写回契约（§8.1-1）：全量替换（非 append）——D11 下轮续接
            //（未配对尾巴已截断），同会话多轮后条数不翻倍 = 行为变更③。
            _session.replaceTranscript(transcript);
            _appendText(text.isEmpty ? '' : '\n');
            _add(TrackNote('✓ 任务完成', danger: false));
            _setPill('done', CapsuleTone.idle);
            // §4.1：L1 药丸完成 → 极轻微 tick
            unawaited(HapticFeedback.selectionClick());
        }
      }
      // 会话绑定捕获：模型可能在本轮经 use_server/activate 改写私有槽位，
      // 收尾前经三态写回契约落到会话元数据（免每轮重选）。
      final slot = router.activePrivateServerId;
      if (slot != null) {
        _session.bindPrivateServer(slot);
      } else if ((_session.activePrivateServerId ?? '').isNotEmpty) {
        _session.unbindToPublic(); // 曾绑定 → 本轮 use_server('all') 清空 = 显式公共
      }
    } on Object catch (e) {
      _add(TrackNote('✕ 任务中断：$e', danger: true));
      _setPill('failed', CapsuleTone.danger);
    } finally {
      _watcher?.stop();
      _watcher = null;
      _activeCallEntry = null;
      // P0 尾帧铁律（stream-perf §3）：快照与终态渲染前强制清空流控缓冲——
      // 覆盖正常收尾 / Abort / 异常三条路径，缓冲期内到达的尾帧不得丢失。
      _streamBuf.flush();
      // 资源释放内核化（谁持资源谁释放）：connections stop + client.close +
      // refStore 焚，全部在内核 close() 内（幂等；失败 DEGRADE 不抛穿 finally）。
      await assembly?.close();
      _activeAssembly = null;
      assembly = null;
      await _persistCurrent(); // T3b：Run 收尾快照（含 Cancelled 终态）
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
      _runStartedAt = null;
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
    // §4.1：Abort → 重度确认震动
    unawaited(HapticFeedback.heavyImpact());
    _watcher?.stop();
    _activeAssembly?.abort(reason: 'user abort'); // 内核遍历全部 face 取消在途 + loop.abort
    final entry = _activeCallEntry;
    if (entry != null && entry.phase == CallCardPhase.running) {
      setState(() {
        entry.phase = CallCardPhase.cancelled;
        entry.progressNote = '已中止（在途调用结果仍会回填）';
      });
    }
    _setPill('idle', CapsuleTone.idle);
  }

  /// D13 侧边栏（会话维度）：布局体外提 ConversationDrawer（步 4 Epic C），
  /// 运行守卫/删除确认/导航编排留窗口。
  Widget _buildDrawer() {
    return ConversationDrawer(
      conversations: _conversations,
      currentId: _archive?.currentId,
      onNew: () {
        if (!_guardRunning('新建会话')) return;
        _newConversation();
      },
      onLoad: _loadConversation,
      onDelete: (meta) => unawaited(_deleteConversation(meta)),
    );
  }

  static String _preview(String content) {
    final lines = content.trim().split('\n');
    final head = lines.take(2).join(' · ');
    return head.length > 120 ? '${head.substring(0, 120)}…' : head;
  }

  /// 输入条内嵌状态带：布局体外提 StatusStrip（步 4 Epic C），胶囊可点开菜单。
  Widget _statusStrip(ConsoleTokens t) {
    return StatusStrip(
      t: t,
      pillTone: _pillTone,
      pillLabel: _pillLabel,
      running: _running,
      runStartedAt: _runStartedAt,
      contextId: _session.activePrivateServerId,
      localPluginCount: _localPlugins.length,
      hasEndpoints: _endpoints.isNotEmpty,
      endpointName: _endpointName,
      onOpenMenu: _openComposerMenu,
    );
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
            _archive?.currentTitle.isEmpty ?? true ? 'GoodHub' : _archive!.currentTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
                        '（首次使用请先在侧边栏 → 设置页里配置服务端点）',
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
