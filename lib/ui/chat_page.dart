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
import 'components/chat_composer.dart';
import 'components/chat_gate_delegates.dart';

import 'package:path_provider/path_provider.dart';

import '../app/service_directory.dart';
import '../coordinator/agent_loop.dart';
import '../coordinator/conversation_archive.dart';
import '../coordinator/chat_session_service.dart';
import '../coordinator/degradation_controller.dart';

import '../coordinator/chat_run_orchestrator.dart';
import '../coordinator/mcp_runtime.dart';
import '../llm/cloud/cloud_llm.dart';

import '../coordinator/skill_registry.dart';

import '../mcp/connection_manager.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/trusted_plugins.dart';
import '../mcp/server_endpoints.dart';
import '../mcp/default_private_server.dart';
import '../gateway_api/gateway_control.dart';
import '../sandbox/conversation_store.dart';
import '../sandbox/memory_store.dart';
import '../sandbox/workspace_state_store.dart';
import 'components/call_card.dart';
import 'components/cross_source_consent_card.dart';
import 'components/conversation_drawer.dart';
import 'components/dual_track_stream.dart';
import 'components/session_context_sheet.dart';
import 'error_copy.dart';
import 'components/status_capsule.dart';

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

class _ChatPageState extends State<ChatPage> implements ChatTrackSink {
  @override
  void addTrack(TrackEntry entry) => _add(entry);
  @override
  void setPill(String label, CapsuleTone tone) => _setPill(label, tone);
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

  /// 会话服务（断点③ step1：会话内核状态下沉 coordinator/chat_session_service，
  /// 窗口只持句柄 + UI 态；轨道卡编解码在边界完成——见 service 文件头注释）。
  final ChatSessionService _sessionSvc = ChatSessionService();

  /// 活态会话（getter 委托到服务，读取引用零改写；赋值走服务方法）。
  ConversationSession get _session => _sessionSvc.session;
  /// 落盘内核（getter 委托；读取引用零改写）。
  ConversationArchive? get _archive => _sessionSvc.archive;
  /// 侧边栏列表投影（getter 委托）。
  List<ConversationMeta> get _conversations => _sessionSvc.conversations;

  /// 记忆治理器（context-stepped-pruning §6，内核层）：journal/TTL/Tick 判定
  /// 全在 MemoryGovernor（window-kernel-split 落点纪律）；窗口只测量 transcript
  /// （轮数/体量）并投影 systemTail + contextFooter。切会话即重置。
  // Run 编排下沉件（window-slim P1-A）：记忆内核接线/冷热分层/系统前缀/slot
  // 写回/governor 生命周期收口 coordinator——本页只持展示态与 UI 端口实现。
  final ChatRunOrchestrator _runOrchestrator = ChatRunOrchestrator();

  // 会话持久化（archive-memory-claim 步 1）：落盘事实 owner = ConversationArchive
  // 内核（懒建/快照组装/恢复/删除门面），窗口只持侧边栏列表投影（已下沉
  // _sessionSvc.archive，见上方 getter）。
  // 端点缓存（供 composer menu 与默认回退使用；_send 内刷新）。
  List<ServerEndpoint> _endpoints = <ServerEndpoint>[];
  // 本地插件缓存（零配置自动发现；系统托管、始终挂载；供状态带/菜单展示）。
  List<LocalPluginInfo> _localPlugins = const <LocalPluginInfo>[];
  // 统一默认私有服务 id（设置页钉选，覆盖手动端点 + 本地插件）；null = 无默认。
  // 开会话回退链以本键为准（见 _resolveBinding）。
  String? _defaultPrivateId;

  // Run 期柄（Abort/卡状态机/卡死判定接线目标；finally 清）
  var _running = false;

  /// 运行起始时刻（状态带计时显示用；running=false 时清空）。
  DateTime? _runStartedAt;

  /// 上一句发送的任务文本（ux-hardening P0-2：错误卡「重试」重跑语料）。
  String? _lastPrompt;

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
    await _sessionSvc.init();
    // P2-1：配额损坏/签名不符不再静默清零——原文件已备份，用户可见提示
    // （旧行为：用户对额度重置毫无知觉）。
    if (_sessionSvc.archive?.lastQuotaError != null) {
      _add(TrackNote('⚠ 用量配额记录损坏，已按全新额度计算（原文件已备份）',
          danger: true));
    }
    if (mounted) setState(() {}); // 配额/会话已从服务恢复
  }

  Future<void> _refreshConversations() async {
    await _sessionSvc.refresh();
    if (!mounted) return;
    setState(() {});
  }

  /// Run 收尾/绑定即存快照：save 组装与落盘在 Archive 内核；失败 DEGRADE
  /// 留痕返 false，窗口出轨道提示（视图态可观测）。轨道卡编码在边界完成
  /// （TrackEntryCodec 属 ui 层，service 不依赖 ui 类型）。
  Future<void> _persistCurrent() async {
    final ok = await _sessionSvc.persistCurrent(
      // ux-hardening P0-1：引导卡瞬态（动作回调不可序列化）——持久化前
      // 过滤，恢复会话不出现；未配置状态由 _loadEndpoints 重插。
      trackJson: TrackEntryCodec.encode(
        _track.where((e) => e is! TrackGuide).toList(),
      ),
    );
    if (!ok) _add(TrackNote('⚠ 会话快照保存失败（见日志）', danger: true));
  }

  /// 切换/删除前的当前会话保底。
  Future<void> _persistIfAny() async {
    await _sessionSvc.persistIfAny(
      trackJson: TrackEntryCodec.encode(
        _track.where((e) => e is! TrackGuide).toList(),
      ),
    );
  }

  /// 恢复/新建后重置会话态：激活集属会话（§15），跨会话必须重开。
  /// 步 3-T4：五字段手工枚举消失——新会话 = 新 [ConversationSession] 实例
  /// （transcript/绑定/激活集/降级/事实库/配额随之全部归零，
  /// **切会话即重置配额** = 行为变更①，原为页面级「重启清零」）。
  void _resetSessionState() {
    setState(() {
      _track.clear();
      _activeCallEntry = null;
      _pillLabel = 'idle';
      // 记忆治理器随会话生灭（§6.2：传输态切会话即弃，重置周期锚点）——
      // governor 随编排件（window-slim P1-A），本页只触发重置。
      _runOrchestrator.memGovernor.reset();
      _pillTone = CapsuleTone.idle;
    });
    _sessionSvc.resetSession(); // 内核态重置（会话实例 + 归档当前指针）
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
    final snap = await _sessionSvc.loadSnapshot(meta.id);
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
    await _sessionSvc.adoptSnapshot(snap); // 内核态恢复（id/title/绑定/transcript）
    setState(() {
      _track.addAll(TrackEntryCodec.decode(snap.track)); // 轨道卡解码在 UI 层
    });
    // MO6 阶段一：切换会话 → 网关投影同步宿主当前激活私有域（PC 只读镜像）。
    syncGatewayActivePrivate(_session.activePrivateServerId);
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
    await _sessionSvc.delete(meta.id);
    if (_sessionSvc.archive?.currentId == meta.id) _resetSessionState();
    if (mounted) setState(() {}); // 侧边栏列表随服务刷新
  }

  void _add(TrackEntry entry) {
    if (!mounted) return;
    setState(() => _track.add(entry));
    _pinToBottom();
  }

  /// 错误行动卡（ux-hardening P0-2）：异常白话翻译 + 原始异常留痕 + 重试
  /// 入口。重试 = 以 [_lastPrompt] 重跑（[_send] override 路径）；重试后
  /// 卡片锁定为灰阶「已重试」（终态锁定，ui-design §3.2）。
  void _addErrorCard(Object error) {
    final copy = humanizeError(error);
    final card = TrackError(
      title: copy.title,
      advice: copy.advice,
      detail: '$error',
    );
    card.onAction = () {
      final p = _lastPrompt;
      if (p == null || p.isEmpty) return;
      if (!_guardRunning('重试')) return;
      setState(() => card.retried = true);
      unawaited(_send(p));
    };
    _add(card);
  }

  /// 本会话轨道是否存在记忆胶囊（悬浮 ≡ 按钮的显隐依据）。
  bool get _hasMemoryCapsules => _track.any((e) => e is TrackMemoryCapsule);

  /// 会话记忆汇总列表（BottomSheet）：轨道内全部 TrackMemoryCapsule 快照，
  /// 已撤销条目灰阶弱化（终态锁定语义，ui-design §3.2）。纯展示——落盘与
  /// 撤销仍由内联胶囊的 undo 通道负责，此处不做修改入口。
  void _showMemoryListSheet() {
    final t = consoleTokens(context);
    final capsules =
        _track.whereType<TrackMemoryCapsule>().toList(growable: false);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetCtx) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本会话记忆（${capsules.length}）',
                  style: TextStyle(
                    fontSize: Fsz.telemetry,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '模型从对话中提取落库的事实要点（session/user/srv 域）',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
                ),
                const Divider(height: 16),
                if (capsules.isEmpty)
                  Text(
                    '本会话暂无提取的记忆',
                    style:
                        TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
                  ),
                for (final c in capsules)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(top: 6),
                          decoration: BoxDecoration(
                            color: c.undone ? t.terminalMuted : t.l1Ok,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            c.undone ? '${c.key}=${c.value}（已撤销）' : '${c.key}=${c.value}',
                            style: TextStyle(
                              fontFamily: t.monoFamily,
                              fontSize: Fsz.note,
                              color: c.undone ? t.terminalMuted : null,
                              decoration:
                                  c.undone ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
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
    final def = await readDefaultPrivateServerId();
    if (!mounted) return;
    setState(() {
      _endpoints = all;
      _localPlugins = locals;
      _defaultPrivateId = def;
    });
    // 先刷新端点/插件缓存，再按统一默认回退解析本会话绑定。
    final bound = _session.activePrivateServerId ?? _resolveBinding(all);
    setState(() => _session.bindPrivateServer(bound));
    // MO6 阶段一：端点预热/默认锁定后 → 网关投影同步宿主当前激活私有域。
    syncGatewayActivePrivate(_session.activePrivateServerId);
    // ux-hardening P0-1：未配置（无启用端点且无本地插件）→ 轨道内引导卡
    // 替代历史上的整页跳转；幂等入轨，瞬态不持久化。
    _ensureGuide();
  }

  /// 未配置判定（ux-hardening P0-1）：与 [_send] 装配口径一致——无启用端点
  /// 且无本地插件（全部卸载等同未配置）。
  bool get _unconfigured =>
      _endpoints.where((e) => e.enabled).isEmpty && _localPlugins.isEmpty;

  /// 冷启动引导卡（chat-interaction.md §1）：幂等——已在轨不重复插。
  void _ensureGuide() {
    if (!_unconfigured) return;
    if (_track.any((e) => e is TrackGuide)) return;
    _add(
      TrackGuide(
        text: '尚未配置任何 MCP 服务，也未发现本地插件。'
            '先配置一个服务端点，才能下达任务。',
        actionLabel: '去配置',
        onAction: _openSettingsFromGuide,
      ),
    );
  }

  /// 配置就绪后摘除引导卡（用户从设置返回时重估）。
  void _removeGuide() {
    if (!mounted) return;
    setState(() => _track.removeWhere((e) => e is TrackGuide));
  }

  /// 引导卡动作：进设置页；返回后重估配置——已配置摘卡，仍未配置保留可再入。
  Future<void> _openSettingsFromGuide() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
    if (!mounted) return;
    await _loadEndpoints();
    if (!mounted) return;
    if (_unconfigured) {
      _ensureGuide();
    } else {
      _removeGuide();
    }
  }

  /// 是否处于"已绑定某私有服务"的弱感知态（用于状态带胶囊）。
  bool get _hasContext =>
      _session.activePrivateServerId != null &&
      _session.activePrivateServerId!.isNotEmpty;

  /// 会话绑定默认回退：已显式绑定直接用（'' → null = 显式公共）→ 统一默认
  /// 私有服务（设置页钉选，覆盖手动端点 + 本地插件，须当前仍存在）→ 首个手动
  /// private 端点（遗留回退）→ null（纯公共）。
  String? _resolveBinding(List<ServerEndpoint> eps) {
    final bound = _session.activePrivateServerId;
    if (bound != null) return bound.isEmpty ? null : bound;
    final def = _defaultPrivateId;
    if (def != null && def.isNotEmpty) {
      final exists = eps.any((e) =>
              e.enabled &&
              e.tier == ServerPrivacyTier.private &&
              e.id == def) ||
          _localPlugins.any((lp) => lp.serverId == def);
      if (exists) return def;
    }
    String? firstPrivate;
    for (final e in eps) {
      if (e.tier != ServerPrivacyTier.private) continue;
      firstPrivate ??= e.id;
    }
    return firstPrivate;
  }

  /// 即时绑定（composer menu 调用）：写会话态（三态写回契约）+ 落会话元数据。
  void _bindSessionServer(String? serverId) {
    setState(() => _session.bindPrivateServer(serverId));
    // MO6 阶段一：菜单即时绑定/清空 → 网关投影同步宿主当前激活私有域。
    syncGatewayActivePrivate(_session.activePrivateServerId);
    unawaited(_persistCurrent());
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

  /// Composer Menu（药丸内左侧「+」→ 底部弹层）：本会话绑定哪个私有服务。
  /// 持久默认（设置页钉选）不在此处改——此处只做本次会话即时切换/覆盖。
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
          defaultId: _defaultPrivateId,
          endpointName: _endpointName,
          onBind: (id) {
            _bindSessionServer(id);
            setSheet(() {});
          },
          onClear: () {
            _bindSessionServer('');
            setSheet(() {});
          },
          onDone: () => Navigator.pop(ctx),
        ),
      ),
    );
  }


  /// M4-T3 发送（D11 多轮）：上轮 transcript 作 history 续接；一次一个 Run。
  /// [promptOverride] = 错误卡「重试」入口重跑上一句（ux-hardening P0-2）：
  /// 不重复插用户轮卡、不清输入框（用户可能正在预输入下一轮）。
  Future<void> _send([String? promptOverride]) async {
    final isRetry = promptOverride != null;
    final prompt = (promptOverride ?? _inputCtrl.text).trim();
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
      // ux-hardening P0-1：轨道内引导卡替代整页跳转设置页——输入内容保留
      // （下方 clear() 在本 return 前不执行），用户经卡上「去配置」自选进入；
      // 从设置返回后按配置状态摘卡/保留（chat-interaction.md §1）。
      _endpoints = allEndpoints;
      _localPlugins = locals;
      _ensureGuide();
      return;
    }
    // P0-2：错误卡「重试」的语料（未配置路径不设——重试无意义，走引导卡）。
    _lastPrompt = prompt;
    if (!isRetry) _inputCtrl.clear();
    setState(() {
      _running = true;
      _pillLabel = 'connecting';
      _pillTone = CapsuleTone.l1;
      _autoFollow = true; // 新任务：回到底部并恢复自动跟随
    });
    // P1-4：运行计时接通——_runStartedAt/_elapsedTimer 此前定义后从未赋值
    // （死代码），状态带 runStartedAt 分支永不亮；秒级 tick 刷已耗时。
    _runStartedAt = DateTime.now();
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    if (!isRetry) _add(TrackUser(prompt));
    // T3b：会话懒建（首个任务起落盘；标题截取策略在 Archive 内核）。
    await _archive!.ensureCurrent(prompt: prompt);
    // P2-6（§3.6/G3）：会话级事实库懒建——In-band 捎带 session 域落点。
    _session.bindWsStates(WorkspaceStateStore.underSupportDir(support.path));
    final convId = _archive!.currentId!;
    McpAssembly? assembly; // Run 级句柄：finally 统一释放（内核持资源谁释放）
    try {
      final memoryStore = MemoryStore.underSupportDir(support.path);
      // 记忆内核接线收口编排件（window-slim P1-A）；窗口只留胶囊 UI
      // （TrackMemoryCapsule 渲染与撤销挂载）与写失败可见轨道（P1-C）。
      void onCapsule(String key, String value, String action, String scope,
          void Function() undo) {
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
      }

      void onWriteFailure(String key, String scope) {
        if (!mounted) return;
        setState(() {
          _add(TrackNote('⚠ 记忆写入失败（$scope 域 $key），本条事实未保存',
              danger: true));
        });
      }
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
          gateDelegate: ChatGateDelegate(this),
          fenceDelegate: ChatFenceDelegate(this), // D4 有人值守拦截卡
          blockDelegate: ChatBlockDelegate(this),
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
      // Run 编排核下沉（window-slim P1-A）：workspaceFilter/记忆冷热分层/
      // 系统前缀/归因数据/maskTool 由编排件组装，窗口只映射到轨道。
      final plan = await _runOrchestrator.plan(
        assembly: assembly,
        memoryStore: memoryStore,
        wsStates: _session.wsStates,
        conversationId: convId,
        transcript: _session.transcript,
        skills: _session.skills!,
        baseSystemPrompt: _systemPrompt,
        onCapsule: onCapsule,
        onWriteFailure: onWriteFailure,
      );
      // 上下文归因（展示 only）：本轮注入的记忆/服务快照挂轨道，点开 BottomSheet
      // 查详情。「本轮排除」为预留钩子——当前不接线（onItemExclude=null）。
      _add(
        TrackContextAttribution(
          memories: [
            for (final e in plan.memoryEntries)
              ContextAttributionItem(source: e.scope, text: e.content),
          ],
          services: [
            for (final id in router.serverIds)
              ContextAttributionItem(
                source: id,
                text: assembly.serverSummaries[id] ?? '(无摘要)',
              ),
          ],
          droppedCount: plan.droppedCount,
        ),
      );
      _setPill('thinking', CapsuleTone.l1);
      await for (final e in assembly.loop.run(
        systemPrompt: plan.systemPrompt, // 静态前缀（P1-3b 断点 A，编排件组装）
        systemTail: plan.memSection,
        // 记忆增量区沉底（context-stepped-pruning §6.5）：周期内提取的变更
        // 只追加在稳定前缀之后、本轮提问之前，不推移快照+窗口原文。
        contextFooter: plan.contextFooter,
        userPrompt: prompt,
        history: List.of(_session.transcript), // D11：上轮 transcript 续接
        workspaceFilter: plan.workspaceFilter, // P2-6：In-band 分流+胶囊
        maskTool: plan.maskTool, // P3-2：让位私有域发送边界脱敏
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
            // P1-4：工具结束 ≠ Run 结束——回「思考中」（环回到模型推理），
            // 杜绝旧行为置 idle 让用户误判任务已完成。
            _setPill(rejected ? 'rejected' : 'thinking', CapsuleTone.l1);
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
      // 会话绑定捕获（window-slim P1-A：三态写回契约收口编排件）——模型可能
      // 在本轮经 use_server/activate 改写私有槽位，收尾前落会话元数据。
      _runOrchestrator.writebackSlot(router: router, session: _session);
    } on Object catch (e) {
      // ux-hardening P0-2：白话错误卡（标题/建议/可复制原始异常）+ 重试入口，
      // 替代原始异常栈直怼轨道。
      _addErrorCard(e);
      _setPill('failed', CapsuleTone.danger);
    } finally {
      _watcher?.stop();
      _watcher = null;
      _activeCallEntry = null;
      // §6.4 TTL 机会主义压实的判定起点：本 Run 结束时刻（governor 持有，
      // 随编排件——window-slim P1-A）。
      _runOrchestrator.markRunEnded();
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
      onRename: (meta, title) => unawaited(_renameConversation(meta, title)),
    );
  }

  /// 重命名会话（ux-hardening P1-5）：内核透传（当前会话同名时内核同步
  /// _currentTitle，防下次 saveCurrent 覆盖回旧标题）+ 列表刷新。元数据
  /// 操作不动 transcript，运行中亦可（无会话态扰动，故不走运行守卫）。
  Future<void> _renameConversation(
      ConversationMeta meta, String rawTitle) async {
    final title = rawTitle.trim();
    if (title.isEmpty) return;
    final ok = await _archive?.rename(meta.id, title) ?? false;
    if (!mounted) return;
    if (!ok) {
      _toast('⚠ 重命名失败（会话文件可能已损坏）');
      return;
    }
    await _refreshConversations();
    _toast('✓ 已重命名为「$title」');
  }

  static String _preview(String content) {
    final lines = content.trim().split('\n');
    final head = lines.take(2).join(' · ');
    return head.length > 120 ? '${head.substring(0, 120)}…' : head;
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
                    // 未配置时的可操作引导在轨道内引导卡（ux-hardening P0-1，
                    // _ensureGuide），空态提示只承担已配置用户的首次指引。
                    emptyHint: '下达自然语言任务，宿主调度已挂载服务完成',
                  ),
                  if (!_autoFollow && _track.isNotEmpty)
                    Positioned(
                      right: 16,
                      bottom: _hasMemoryCapsules ? 72 : 8,
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
                  // 悬浮记忆入口（≡）：与「回到最新」同款 FAB——本会话轨道
                  // 存在记忆胶囊时显示，点击弹 BottomSheet 汇总列表。
                  if (_hasMemoryCapsules)
                    Positioned(
                      right: 16,
                      bottom: 8,
                      child: FloatingActionButton.small(
                        heroTag: 'chat-memory-list',
                        tooltip: '会话记忆',
                        onPressed: _showMemoryListSheet,
                        child: const Icon(Icons.reorder),
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
                    // 底部控制集群已抽 lib/ui/components/chat_composer.dart
                    // （断点③ step2：传数据 + 回调，零依赖本页私有态）。
                    child: ChatComposer(
                      inputCtrl: _inputCtrl,
                      running: _running,
                      hasContext: _hasContext,
                      contextId: _session.activePrivateServerId,
                      endpointName: _endpointName,
                      hasEndpoints: _endpoints.isNotEmpty,
                      localPluginCount: _localPlugins.length,
                      pillTone: _pillTone,
                      pillLabel: _pillLabel,
                      runStartedAt: _runStartedAt,
                      onOpenMenu: _openComposerMenu,
                      // 回车与发送钮统一走 guard（非 running 时 guard 通过→等价原
                      // 按钮直发；running 时按钮已变中止键，此处拦下并给 SnackBar）。
                      onSend: () {
                        if (!_guardRunning('发送')) return;
                        _send();
                      },
                      onAbort: _abort,
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


