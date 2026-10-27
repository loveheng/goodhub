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
import 'sections/resource_center_section.dart'
    show showResourcePickerSheet, undoResourceCollect;

import 'package:path_provider/path_provider.dart';

import '../app/service_directory.dart';
import '../app/task_consume_bootstrap.dart';
import '../coordinator/agent_loop.dart';
import '../coordinator/conversation_archive.dart';
import '../coordinator/chat_session_service.dart';
import '../coordinator/degradation_controller.dart';

import '../coordinator/chat_run_orchestrator.dart';
import '../coordinator/mcp_runtime.dart';
import '../coordinator/plan_proposal_tool.dart'
    show PlanProposalDecision;
import '../coordinator/task_plan.dart' show PlanAggregateRecord;
import '../llm/cloud/cloud_llm.dart';

import '../coordinator/user_prompt_store.dart';

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
import 'components/status_strip.dart';

import 'chat_status_controller.dart';
import 'tokens/console_tokens.dart';
import 'components/stuck_watcher.dart';
import 'resource_center_page.dart';
import 'settings_page.dart';

/// 连接配置持久化（T6-2）：改走 [ServerEndpointStore]（多端点 JSON + apiKey
/// 走安全存储）；旧单端点 SharedPreferences 由该 store 在首次 load 时迁移。

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, this.endpointStoreOverride, this.engineOverride});

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

class _ChatPageState extends State<ChatPage>
    with WidgetsBindingObserver
    implements ChatTrackSink {
  @override
  void addTrack(TrackEntry entry) => _add(entry);
  @override
  void setPill(String label, CapsuleTone tone) => _setPill(label, tone);

  /// 状态/副作用收敛件（window-slim P1-B/C/D）：pill/运行态/已耗时/轨道列表/
  /// 滚动锚定/键盘/会话切换生命周期全部收口此处；窗口只持配置缓存与编排句柄。
  /// 流式文本缓冲（stream-perf §3）亦归口其中——保序铁律：非文本条目入轨前
  /// 先刷空缓冲（防「✓ 任务完成」插到正文中间，2026-10-19 真机实证修复）。
  final ChatStatusController _status = ChatStatusController();

  static const _systemPrompt =
      '你是 GoodHub 宿主助手，调度已挂载服务与宿主能力完成用户任务。'
      '任务能直接回答的直接以自然语言回答，不强行调用工具；'
      '只读工具会静默执行，写操作需用户在确认卡批准；用户偏好可写入宿主记忆'
      '（只记稳定事实，禁记临时数据），回答使用中文。';

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

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
  // 编排 B1：会话级编排状态随编排件持有；聚合卡出口回调直插轨道
  // （onResume 闭包走续跑手势——Run 收口当刻的活会话才可续跑）。
  late final ChatRunOrchestrator _runOrchestrator =
      ChatRunOrchestrator(onPlanAggregate: _onPlanAggregate);

  // 会话持久化（archive-memory-claim 步 1）：落盘事实 owner = ConversationArchive
  // 内核（懒建/快照组装/恢复/删除门面），窗口只持侧边栏列表投影（已下沉
  // _sessionSvc.archive，见上方 getter）。
  // 端点缓存（供 composer menu 与默认回退使用；_send 内刷新）。
  List<ServerEndpoint> _endpoints = <ServerEndpoint>[];
  // 本地插件缓存（零配置自动发现；系统托管、始终挂载；供状态带/菜单展示）。
  List<LocalPluginInfo> _localPlugins = const <LocalPluginInfo>[];

  // 附件待发项（resource-center M1-T3）：composer 药丸展示；_send 装配期传
  // McpRuntime 落 run 级 $ref 池，发送起步即清（附件属单次发送；移除药丸仅
  // 注销本行，严禁触资源库删除——设计稿 §2 附件退回口径）。
  final List<({String id, String name})> _pendingResources = [];
  // 统一默认私有服务 id（设置页钉选，覆盖手动端点 + 本地插件）；null = 无默认。
  // 2026-10-18（二次修正，用户拍板）：新会话跟随钉选默认（无默认则公共起步）
  // ——「首个 private」遗留回退废除；钉选在弹层仍显只读快捷提示。
  String? _defaultPrivateId;

  /// 上一句发送的任务文本（ux-hardening P0-2：错误卡「重试」重跑语料）。
  String? _lastPrompt;

  McpAssembly? _activeAssembly; // Run 期句柄（Abort/finally 释放；步 1 内核化后窗口只持句柄）
  // F19（review-fix-2026-10）：装配期（连接中）点停止时句柄未就绪，无取消
  // 通道——置预中止标志，装配完成后立即对 assembly 补发 abort（否则 Run 挂着
  // 悬挂引擎空转，pill 已 idle 而 running 卡 true）。
  bool _pendingAbort = false;
  TrackCall? _activeCallEntry;

  /// 活动思考轨条目（2026-10-21 M1）：本轮当前思维流段——首 delta 建条目
  /// （默认收起），后续 delta 追加；工具卡/收尾断开（下一轮思维另起条目，
  /// 保多轮轨迹顺序）。展示 only，不参与持久化外的任何语义。
  TrackThinking? _activeThinkingEntry;
  StuckWatcher? _watcher;

  @override
  void initState() {
    super.initState();
    _status.attachScroll(_scrollCtrl);
    _scrollCtrl.addListener(_onUserScroll);
    WidgetsBinding.instance.addObserver(this);
    // 算力让路端口（契约 §3.12.2-2）：后台批处理遇前台对话进行中即暂缓。
    // 窗口层只注入运行态，装配与消费逻辑在 app 层装配件。
    taskConsumeBootstrap.isHostBusy = () => _status.running;
    unawaited(_loadConfig());
    unawaited(_initConversations());
    unawaited(_loadEndpoints());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    taskConsumeBootstrap.isHostBusy = null; // 解绑运行态端口（防悬空引用）
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _status.dispose(); // 含流控缓冲定时器取消（P0：widget 已销毁，残余无处可刷）
    super.dispose();
  }

  /// D：键盘遮挡收敛——键盘升降改 viewInsets 后，自动跟随时重新锚定底部，
  /// 避免输入条被软键盘顶起时流末尾看不见（无需整页 setState）。
  @override
  void didChangeMetrics() {
    _status.pinToBottom();
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
      _add(TrackNote('⚠ 用量配额记录损坏，已按全新额度计算（原文件已备份）', danger: true));
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
        _status.tracks.where((e) => e is! TrackGuide).toList(),
      ),
    );
    if (!ok) _add(TrackNote('⚠ 会话快照保存失败（见日志）', danger: true));
  }

  /// 切换/删除前的当前会话保底。
  Future<void> _persistIfAny() async {
    await _sessionSvc.persistIfAny(
      trackJson: TrackEntryCodec.encode(
        _status.tracks.where((e) => e is! TrackGuide).toList(),
      ),
    );
  }

  /// 恢复/新建后重置会话态：激活集属会话（§15），跨会话必须重开。
  /// 步 3-T4：五字段手工枚举消失——新会话 = 新 [ConversationSession] 实例
  /// （transcript/绑定/激活集/降级/事实库/配额随之全部归零，
  /// **切会话即重置配额** = 行为变更①，原为页面级「重启清零」）。
  void _resetSessionState() {
    _activeCallEntry = null;
    _activeThinkingEntry = null; // 思考轨句柄随会话切换断开
    // 记忆治理器随会话生灭（§6.2：传输态切会话即弃，重置周期锚点）——
    // governor 随编排件（window-slim P1-A），本页只触发重置。
    _runOrchestrator.memGovernor.reset();
    _status.resetForSession(); // 清轨道 + 复位状态带到 idle + 复位自动跟随
    // A06（review-fix-2026-10）：附件待发项属单次发送——跨会话残留会混入新
    // 会话的首轮发送（旧口径冲突）。
    _pendingResources.clear();
    _sessionSvc.resetSession(); // 内核态重置（会话实例 + 归档当前指针）
  }

  Future<void> _newConversation() async {
    if (!_guardRunning('新建会话')) return;
    await _persistIfAny();
    if (!mounted) return;
    Navigator.pop(context); // 关抽屉
    _resetSessionState();
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
    await _sessionSvc.adoptSnapshot(snap); // 内核态恢复（id/title/绑定/transcript）
    _status.addEntries(TrackEntryCodec.decode(snap.track)); // 轨道卡解码在 UI 层
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
    _status.addEntry(entry);
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

  /// 会话记忆汇总列表（BottomSheet）：轨道内全部 TrackMemoryCapsule 快照，
  /// 已撤销条目灰阶弱化（终态锁定语义，ui-design §3.2）。纯展示——落盘与
  /// 撤销仍由内联胶囊的 undo 通道负责，此处不做修改入口。
  void _showMemoryListSheet() {
    final t = consoleTokens(context);
    final capsules = _status.tracks.whereType<TrackMemoryCapsule>().toList(
      growable: false,
    );
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
                  '本轮记忆（${capsules.length}）',
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
                    // P2-11：常驻入口必须有「为什么这里是空的」的答案——否则点开
                    // 一个空面板等于把用户丢在真空里（禁静默禁用同源口径）。
                    '本会话暂无提取的记忆。模型从对话里认出稳定事实时会写入这里，'
                    '入轨的每条都可在流内逐条撤销。',
                    style: TextStyle(
                      fontSize: Fsz.note,
                      color: t.terminalMuted,
                    ),
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
                            c.undone
                                ? '${c.key}=${c.value}（已撤销）'
                                : '${c.key}=${c.value}',
                            style: TextStyle(
                              fontFamily: t.monoFamily,
                              fontSize: Fsz.note,
                              color: c.undone ? t.terminalMuted : null,
                              decoration: c.undone
                                  ? TextDecoration.lineThrough
                                  : null,
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
    // 异常路径由 _send 的 finally 强制 flush，尾帧不丢。缓冲与保序铁律
    // （非文本条目入轨前先刷盘）归口 ChatStatusController。
    _status.appendStreamText(delta);
  }

  /// 用户滚动监听：离开底部即暂停自动跟随（流式输出不劫持滚动），回到
  /// 底部恢复。逻辑收口 controller（D）。
  void _onUserScroll() {
    _status.onUserScroll();
  }

  /// 滚动锚定（D）：逻辑收口 controller；自动跟随时拽回底部。
  void _pinToBottom() {
    _status.pinToBottom();
  }

  /// 轻量反馈（SnackBar）：运行中共用守卫——给原因而非静默禁用。
  ///
  /// B5（page-beautify P3）：token 化 + 时长 2→4s——原默认 SnackBar
  /// （inverseSurface 深灰）与控制台风格不搭，且守卫话术是长句，2s 一闪
  /// 读不完；floating + codeBg 微深底贴卡片族，连续 toast 先清栈不叠加。
  void _toast(String msg) {
    if (!mounted) return;
    final t = consoleTokens(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: t.codeBg,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 运行中拦截的共用话术；返回 false = 调用方应中止动作。
  bool _guardRunning(String action) {
    if (_status.running) {
      _toast('任务运行中，$action 需等待当前任务结束');
      return false;
    }
    return true;
  }

  void _setPill(String label, CapsuleTone tone) {
    if (!mounted) return;
    _status.setPill(label, tone);
  }

  /// 端点缓存预热（供 composer menu 展示；首屏即可列服务）。
  /// 新会话绑定解析（2026-10-18 二次修正）：有钉选默认 → 绑定默认；无默认
  /// → 公共起步（''）；已显式绑定的会话（含历史恢复）沿用原值。
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
    // 新会话（未显式绑定）：有设置页钉选默认且仍存在 → 绑定默认；无默认 →
    // 公共起步（''）。历史恢复的显式绑定沿用原值。
    final bound = _session.activePrivateServerId ?? _defaultBinding(all);
    setState(() => _session.bindPrivateServer(bound));
    // MO6 阶段一：端点预热/默认锁定后 → 网关投影同步宿主当前激活私有域。
    syncGatewayActivePrivate(_session.activePrivateServerId);
    // 装配层合一（Contract 件）：预热共享能力源——启用端点逐个幂等确保挂载
    //（已挂载零成本），_send 装配时借用共享 face，消同源双实例双冷启动。
    for (final e in all.where((e) => e.enabled)) {
      unawaited(ensureEndpointMounted(e));
    }
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
    if (_status.tracks.any((e) => e is TrackGuide)) return;
    _add(
      TrackGuide(
        text:
            '尚未配置任何 MCP 服务，也未发现本地插件。'
            '先配置一个服务端点，才能下达任务。',
        actionLabel: '去配置',
        onAction: _openSettingsFromGuide,
      ),
    );
  }

  /// 配置就绪后摘除引导卡（用户从设置返回时重估）。
  void _removeGuide() {
    if (!mounted) return;
    _status.removeWhere((e) => e is TrackGuide);
  }

  /// 引导卡动作：进设置页；返回后重估配置——已配置摘卡，仍未配置保留可再入。
  Future<void> _openSettingsFromGuide() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
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

  /// 新会话绑定解析（2026-10-18 二次修正，用户拍板）：有设置页钉选默认
  /// 且当前仍存在（启用 private 端点或已发现本地插件）→ 绑定默认；否则
  /// 公共起步（''）。原回退链的「首个 private」遗留尾级废除——无默认即公共。
  String? _defaultBinding(List<ServerEndpoint> eps) {
    final def = _defaultPrivateId;
    if (def == null || def.isEmpty) return '';
    final exists =
        eps.any(
          (e) =>
              e.enabled && e.tier == ServerPrivacyTier.private && e.id == def,
        ) ||
        _localPlugins.any((lp) => lp.serverId == def);
    return exists ? def : '';
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
    // A5（page-beautify P3）：运行中菜单**可查看**（当前绑定/可用服务一览）
    // ——原一刀切 guard 把只读查看也弹「需等待」，零收益纯添堵；切换类
    // 动作（绑定/清空）才走 guard，与 sheet 内置灰双保险。
    // 开菜单前先重读端点目录：大厅新增/卸载服务后返回聊天页，initState 缓存可能
    // 已过时，直接重读保证菜单列出当前真实存在的私有服务。
    await _loadEndpoints();
    if (!mounted) return;
    final t = consoleTokens(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // 2026-10-19（用户拍板）：半屏起步、可上推全屏（0.5 ↔ 0.95 双档吸附）
      // ——空间诉求走弹层内扩容，不升正式页（使用面不升页判据）；snap 让
      // 半屏/全屏两档有明确停驻感，内容区拖拽经注入的 scrollController 联动。
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        snap: true,
        snapSizes: const [0.5],
        builder: (ctx, scrollCtrl) => StatefulBuilder(
          // live 快照每次 setSheet 重建重读；交互经回调回页面（步 4 Epic C 外提）
          builder: (ctx, setSheet) => SessionContextSheetBody(
            t: t,
            scrollController: scrollCtrl,
            bound: _session.activePrivateServerId,
            privEndpoints: _endpoints
                .where((e) => e.enabled && e.tier == ServerPrivacyTier.private)
                .toList(),
            localPlugins: _localPlugins,
            defaultId: _defaultPrivateId,
            endpointName: _endpointName,
            bindLocked: _status.running,
            onBind: (id) {
              if (!_guardRunning('切换会话绑定')) return;
              _bindSessionServer(id);
              setSheet(() {});
            },
            onClear: () {
              if (!_guardRunning('切换会话绑定')) return;
              _bindSessionServer('');
              setSheet(() {});
            },
            // 资源挂载 = 本次会话挂载物的一类，与「服务绑定」同挂「+」下：
            // 空态无独立附件行，靠本菜单发现（消「功能堆砌」的物理痕迹）。
            onPickResource: _pickResource,
            onManageResources: _openResourceCenter,
            planArmed: _runOrchestrator.planState.armed,
            onTogglePlanArmed: () =>
                _togglePlanArmed(refreshSheet: () => setSheet(() {})),
          ),
        ),
      ),
    );
  }

  /// 附件入口（M1-T3，RC6）：资源选择 sheet → 加入待发项。选择 sheet 落在
  /// resource_center_section（ui→resources 白名单内文件），本页零 resources 域
  /// import——只持 record 数据。
  Future<void> _pickResource() async {
    // P1-8（2026-10-22）：取消此处的运行守卫——挂载资源是「预备下一次发送」的
    // 视图态动作（`_pendingResources` 只影响下一次 _send，本次 Run 早已在装配
    // 期取过快照），不扰动在途 Run 的领域态；且菜单里「附加资源」已不再随绑定一起
    // 置灰，两者口径必须一致（此前菜单可点却被守卫拦，等于说谎）。
    final picked = await showResourcePickerSheet(context);
    if (picked == null || !mounted) return;
    if (_pendingResources.any((r) => r.id == picked.id)) return; // 幂等。
    setState(() => _pendingResources.add((id: picked.id, name: picked.name)));
    // 选择即收集：新入库条目明示 + 提供撤销；命中同内容复用只给选用回执
    // （撤销 = 删本次收集，复选既有条目不属收集，不给撤销）。
    if (picked.collected) {
      _flashCollected(picked.id, picked.name);
    } else {
      _toast('✓ 已选用资源：《${picked.name}》');
    }
  }

  /// 资源中心管理页（composer「+」菜单直达；与抽屉入口同一页面）——导入/
  /// 改名/删除/外部打开属高频动作，不该藏在二级配置页。
  Future<void> _openResourceCenter() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ResourceCenterPage()));
  }

  /// 收集明示 + 撤销通道——复用记忆胶囊「已记录 · 撤销」的既有交互语法
  /// （page-beautify B2 先例），不新造反馈模式。
  void _flashCollected(String id, String name) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已收入资源中心：$name'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              setState(() => _pendingResources.removeWhere((r) => r.id == id));
              unawaited(undoResourceCollect(id));
            },
          ),
        ),
      );
  }

  /// M4-T3 发送（D11 多轮）：上轮 transcript 作 history 续接；一次一个 Run。
  /// [promptOverride] = 错误卡「重试」入口重跑上一句（ux-hardening P0-2）：
  /// 不重复插用户轮卡、不清输入框（用户可能正在预输入下一轮）。
  /// F6（review-fix-2026-10）：发送闩——判 running 与 beginRun 之间有两个
  /// await（support 目录/端点加载），窗口内 running 仍 false，双击发送 =
  /// 两个并发 Run（双 TrackUser + transcript 竞写）。闩住重入；Run 收尾
  /// （finally）释放，与 running 守卫等宽覆盖。
  bool _sending = false;

  Future<void> _send([String? promptOverride, bool asSystemEvent = false]) async {
    if (_sending) return;
    final isRetry = promptOverride != null;
    final prompt = (promptOverride ?? _inputCtrl.text).trim();
    if (prompt.isEmpty || _status.running) return;
    _sending = true;
    try {
      await _sendGuarded(prompt, isRetry: isRetry, asSystemEvent: asSystemEvent);
    } finally {
      _sending = false;
    }
  }

  Future<void> _sendGuarded(
    String prompt, {
    required bool isRetry,
    bool asSystemEvent = false,
  }) async {
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
    // P0-3 降噪（2026-10-22）：卸载提示属**配置态通告**——每轮重插会在多轮会话里
    // 逐行堆积。同一会话同一计数只告一次；用户回设置页改动导致计数变化则再告
    // （键随计数变，见 ChatStatusController.claimSessionNotice）。
    if (unmounted > 0 &&
        _status.claimSessionNotice('unmounted-services:$unmounted')) {
      _add(TrackNote('⊘ 有 $unmounted 个服务已卸载，未参与本次任务（设置页可重新挂载）', danger: false));
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
    // 切片 B：运行态收口到 controller——beginRun 一次性落 running/connecting/
    // 自动跟随/已耗时起点，合并为单次状态通知（替代原 4 行整页 setState）。
    _status.beginRun(startedAt: DateTime.now());
    _activeThinkingEntry = null; // 思考轨按 Run 生灭（多轮内按工具卡分段）
    if (!isRetry) {
      // 编排 B1：续跑合成消息渲染为灰阶系统事件行（非普通用户气泡）。
      asSystemEvent ? _add(TrackNote(prompt, danger: false)) : _add(TrackUser(prompt));
    }
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
      void onCapsule(
        String key,
        String value,
        String action,
        String scope,
        void Function() undo,
      ) {
        // A4（page-beautify P3）：首颗记忆胶囊入轨前插一条事前说明——模型
        // 「何时会记/记了什么/去哪管」须可解释，而非静默出现（幂等：本会话
        // 只插一次；恢复会话经 note 序列化还原、不再触发本回调）。
        if (!_status.tracks.any(
          (e) => e is TrackNote && e.text == kMemoryFirstNotice,
        )) {
          _add(const TrackNote(kMemoryFirstNotice, danger: false));
        }
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
          _add(TrackNote('⚠ 记忆写入失败（$scope 域 $key），本条事实未保存', danger: true));
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
          if (!trusted.isTrusted(
            info.packageName,
            signatureSha256: info.signatureSha256, // F13：挂载期复核签名指纹
          )) {
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
      // prompt-mgmt §3.3：user 全局 prompt 随基础注册表落盘装载——注册闸
      // （300 Token/重名）fail-fast 跳过项可见通告，不阻断装配。
      final existingSkills = _session.skills;
      final BaseSkillRegistry baseSkills = existingSkills != null
          ? BaseSkillRegistry(registry: existingSkills, skipped: const [])
          : await buildBaseSkillRegistry(
              dirResolver: () async => await getApplicationDocumentsDirectory(),
            );
      for (final skip in baseSkills.skipped) {
        // P0-3 降噪（同上）：注册跳过项迟早仍在（文件没修就在），每轮重插 = 每行
        // 必出的重复危险通告，反而稀释真正的错误。同会话同条目只告一次。
        if (_status.claimSessionNotice('skill-skip:$skip')) {
          _add(TrackNote('⚠ 全局 Prompt 注册跳过: $skip', danger: true));
        }
      }
      _session.bindSkills(baseSkills.registry);
      _session.bindDegradation(_session.degradation ?? DegradationController());
      // A2（page-beautify）：工具名人话化映射（前缀名 → 服务端 description
      // 全文）——onProgress/onNotice 等委托先于 assembly 建成，故此处持可变
      // 映射由委托闭包捕获，装配完成后（下方 router 就绪即 run 起步前）填充。
      final toolDescriptions = <String, String>{};
      final attachmentsSnapshot = List.of(_pendingResources);
      assembly = await const McpRuntime().assemble(
        engine: widget.engineOverride,
        resourceAttachments: attachmentsSnapshot,
        // 装配层合一（Contract 件）：共享能力源 face 表——已由网关挂载的服务
        // 借用复用（跳过新建/协商/连接），未挂载的走旧自建路径兜底。
        sharedFaces: sharedFaces,
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
                content: Text('服务端模板 $from → $to（大版本跃迁）。\n重置回服务端最新版，还是保留本地覆写？'),
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
          elicitationDelegate: ChatElicitationDelegate(this),
          planDelegate: ChatPlanDelegate(this), // 编排 B1：计划确认卡
          onNote: (message, {danger = false}) =>
              _add(TrackNote(message, danger: danger)),
          onProgress: (tool, progress, total, message) {
            // A2：进度胶囊同步人话动作标签（原名归 CallCard 遥测轨）。
            final action = StatusStrip.toolAction(tool, toolDescriptions);
            _setPill(
              total != null ? '$action $progress/$total' : '$action $progress',
              CapsuleTone.l1,
            );
          },
          onNotice: (n) {
            _setPill(
              StatusStrip.toolAction(n.toolName, toolDescriptions),
              CapsuleTone.l1,
            );
            unawaited(HapticFeedback.selectionClick());
          },
          connectionReport: (report) {
            if (!mounted) return;
            switch (report.kind) {
              case ConnectionReportKind.disconnect:
                _add(
                  TrackNote(
                    '⚠ 连接中断，在途 ${report.inFlightCancelled} 个请求已取消，不重放',
                    danger: true,
                  ),
                );
              case ConnectionReportKind.backlog:
                _add(
                  TrackNote(
                    '⚠ 连接中断，积压 ${report.droppedCount} 个请求已丢弃，不重放',
                    danger: true,
                  ),
                );
              case ConnectionReportKind.resourceUpdated:
                _add(
                  TrackNote(
                    '${McpConnection.resourceStaleMessage}（${report.uri}）',
                    danger: false,
                  ),
                );
            }
          },
        ),
        quota: _session.samplingQuota,
        // 编排 B1：会话级编排状态（围栏/台账/配额跨续跑；close 即 Run 收口）。
        planState: _runOrchestrator.planState,
        onSamplingBegin: () => _watcher?.samplingBegin(),
        onSamplingEnd: () => _watcher?.samplingEnd(),
      );
      _activeAssembly = assembly;
      // F19：装配期间用户已点停止 → 对刚就绪的 assembly 补发 abort（预中止：
      // loop 首个 _aborted 检查即 LoopFinished 收尾，Run 立即结束而非空转）。
      if (_pendingAbort) assembly.abort(reason: 'user abort (connecting phase)');
      final router = assembly.router;
      // A2：填充人话化映射——faces 的 cachedSchemas 已缓存，一次性 O(工具数)；
      // 值 = 服务端 description 全文（CallCard 收起首子句/可展开全文）。
      for (final id in router.serverIds) {
        for (final s in router.schemasFor(id)) {
          toolDescriptions[s.name] = s.description;
        }
      }
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
      // 断连降级通告（prompt-mgmt §8.2.1）：激活私有服务掉线，本 Run 已收敛
      // 降级纯公共模式——可见通告，禁幽灵上下文静默。
      if (plan.slotNotice != null) {
        _add(TrackNote(plan.slotNotice!, danger: true));
      }
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
          // P1-7：记忆不再在此重列——给直达 AppBar「本轮记忆」的入口
          // （同一份内容只留一处可管理位）。
          onViewMemories: _showMemoryListSheet,
        ),
      );
      _setPill('thinking', CapsuleTone.l1);
      // 附件属单次发送（M1-T3）：装配已消费快照，起步即清药丸。
      if (_pendingResources.isNotEmpty && mounted) {
        setState(_pendingResources.clear);
      }
      await for (final e in assembly.loop.run(
        systemPrompt: plan.systemPrompt, // 静态前缀（P1-3b 断点 A，编排件组装）
        systemTail: plan.memSection,
        // 记忆增量区沉底（context-stepped-pruning §6.5）：周期内提取的变更
        // 只追加在稳定前缀之后、本轮提问之前，不推移快照+窗口原文。
        contextFooter: plan.contextFooter,
        // 资源附件 footer（M1-T3）拼在用户文本之前（模型先见附件再见图）。
        userPrompt: (assembly.resourceContextFooter ?? '') + prompt,
        history: List.of(_session.transcript), // D11：上轮 transcript 续接
        workspaceFilter: plan.workspaceFilter, // P2-6：In-band 分流+胶囊
        maskTool: plan.maskTool, // P3-2：让位私有域发送边界脱敏
        tools: const [],
      )) {
        switch (e) {
          case LoopThinkingDelta(:final text):
            // 思考轨（2026-10-21 M1，默认收起）：首 delta 经 _add 建条目
            // （保序铁律：先刷文本缓冲），后续追加。PII 边界：思考流与正文
            // 同域（宿主本机视图——不进 transcript/工具结果，无跨端暴露面），
            // 出站遮蔽与占位符还原由 FencedCloudEngine 统一覆盖，本层不重复遮。
            final activeThinking = _activeThinkingEntry;
            if (activeThinking != null) {
              activeThinking.append(text);
            } else {
              final entry = TrackThinking(text);
              _activeThinkingEntry = entry;
              _add(entry);
            }
          case LoopTextDelta(:final text):
            _appendText(text);
          case LoopToolCallStarted(:final call):
            // A2：状态带人话相位「执行中 · 动作」；原名 + 描述全文归 CallCard
            // （头部等宽遥测轨 + 灰阶人话行，可展开全文）。
            _setPill(
              '执行中 · ${StatusStrip.toolAction(call.name, toolDescriptions)}',
              CapsuleTone.l1,
            );
            final entry = TrackCall(tool: call.name)
            ..description = toolDescriptions[call.name];
            _activeCallEntry = entry;
            // 思考轨分段断开：工具卡之后的下一轮思维另起条目（保轨迹顺序，
            // 不把新思维追加到工具卡之前的旧条目里）。
            _activeThinkingEntry = null;
            // 工具卡插入打断文本流：先刷盘残余保序（尾帧不被卡甩后），后续
            // 文本另起条目。
            _status.breakTextStream();
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
              // 切片 C：工具卡相位自管，进度更新仅本卡局部重绘（无整页 setState）。
              final tail = message == null ? '' : ' · $message';
              entry.patch(
                progressNote: total != null
                    ? '$progress/$total$tail'
                    : '$progress$tail',
              );
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
              // 切片 C：工具卡相位自管，patch 仅本卡局部重绘（无整页 setState）。
              entry.patch(
                phase: phase,
                preview: _preview(result.content),
                resultText: result.content,
                progressNote: null,
              );
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
            // C6：完成通告走常量（dual_track_stream 据此把它从 Run 概要
            // 折叠中摘出、单独 Emerald 成行——重要反馈不被遥测通告稀释）。
            // P0-3 降噪（2026-10-22）：本轮已产出可见正文时，**答案本身即完成
            // 信号**（流式停止 + pill 转「已完成」），不再另起一行「✓ 任务完成」
            // ——多轮会话里每轮必出即为纯占位。仅当本轮**零正文**（纯工具调用/
            // 纯思考）才补这一行，避免「任务结束了吗」的悬空感。
            if (text.trim().isEmpty) {
              _add(const TrackNote(kTaskDoneNote, danger: false));
            }
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
      _activeThinkingEntry = null; // Run 收尾：思考轨句柄断开（条目已入轨）
      // §6.4 TTL 机会主义压实的判定起点：本 Run 结束时刻（governor 持有，
      // 随编排件——window-slim P1-A）。
      _runOrchestrator.markRunEnded();
      // P0 尾帧铁律（stream-perf §3）：快照与终态渲染前强制清空流控缓冲——
      // 覆盖正常收尾 / Abort / 异常三条路径，缓冲期内到达的尾帧不得丢失。
      _status.breakTextStream();
      // 资源释放内核化（谁持资源谁释放）：connections stop + client.close +
      // refStore 焚，全部在内核 close() 内（幂等；失败 DEGRADE 不抛穿 finally）。
      await assembly?.close();
      _activeAssembly = null;
      assembly = null;
      _pendingAbort = false; // F19：Run 收尾清预中止标志（下 Run 干净起步）
      await _persistCurrent(); // T3b：Run 收尾快照（含 Cancelled 终态）
      if (mounted) _status.endRun();
    }
  }

  /// D4 判定触发：在途卡转 stuck（Amber 提示），不自动中止（§10）。
  void _markActiveCallStuck() {
    final entry = _activeCallEntry;
    if (entry == null || entry.phase != CallCardPhase.running) return;
    // 切片 C：工具卡相位自管，patch 仅本卡局部重绘（无整页 setState）。
    entry.patch(phase: CallCardPhase.stuck);
  }

  /// §10 级联 UI 侧（M3-T2 语义复用）：③ cancelled 下发 → 环边界停下 →
  /// 在途卡 Cancelled 态（区别 Failed）。
  void _abort() {
    if (!_status.running) return;
    // §4.1：Abort → 重度确认震动
    unawaited(HapticFeedback.heavyImpact());
    _watcher?.stop();
    if (_activeAssembly == null) {
      // F19：Run 仍在装配期（negotiate/加载未完）——置预中止标志，赋值点补发。
      _pendingAbort = true;
    }
    _activeAssembly?.abort(
      reason: 'user abort',
    ); // 内核遍历全部 face 取消在途 + loop.abort
    // T4 Abort 兜底（编排 B1）：未决计划卡以取消完成——completer 无超时路径，
    // 漏兜底即永挂（propose execute 不返回，Run 无法收口）。
    for (final e in _status.tracks) {
      if (e is TrackPlanConfirm && !e.completer.isCompleted) {
        e.decision = const PlanProposalDecision(approved: false);
        e.decidedAt = DateTime.now();
        e.lockedSummary = '✕ 已取消（计划与同批并入的写作废）';
        e.completer.complete(e.decision!);
      }
    }
    final entry = _activeCallEntry;
    if (entry != null && entry.phase == CallCardPhase.running) {
      // 切片 C：工具卡相位自管，patch 仅本卡局部重绘（无整页 setState）。
      entry.patch(
        phase: CallCardPhase.cancelled,
        progressNote: '已中止（在途调用结果仍会回填）',
      );
    }
    _setPill('idle', CapsuleTone.idle);
  }

  /// 编排 B1：Run 收口聚合卡出口（McpAssembly.close → PlanRunState.endRun
  /// 广播回调）。续跑按钮仅在收口当刻的活会话有效（历史恢复态锁定回看）。
  void _onPlanAggregate(PlanAggregateRecord record) {
    if (!mounted) return;
    _add(TrackPlanResult(
      record: record,
      onResume: _resumePlan,
    ));
  }

  /// 聚合卡续跑手势（防重写三件套）：台账快照合成续跑消息 → 系统事件行 +
  /// 常规发送（冻结集重激活不重弹卡、配额跨续跑累计、模型仅补剩余）。
  void _resumePlan() {
    if (_status.running) return;
    final snapshot = _runOrchestrator.planState.resume();
    if (snapshot == null) return;
    unawaited(_send(snapshot, true));
  }

  /// 总管模式开关（上下文菜单入口；开启即状态带琥珀提示）。
  void _togglePlanArmed({required void Function() refreshSheet}) {
    final state = _runOrchestrator.planState;
    state.armed = !state.armed;
    setState(() {});
    refreshSheet();
    if (state.armed) {
      _add(const TrackNote('总管模式已开启：跨插件写操作将先出计划再一次确认', danger: false));
    }
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
      // prompt-mgmt §3.3：记忆看板「提示词」Tab 展示 SkillRegistry 的
      // appScoped 注入面（官方预置 + CoW 同步）；其 globals()/appScoped()
      // 反映当前已连接服务与静态预置，与具体会话内容无关（看板先于连接
      // 打开时回落离线基线）。
      skillsProvider: () => _session.skills,
    );
  }

  /// 重命名会话（ux-hardening P1-5）：内核透传（当前会话同名时内核同步
  /// _currentTitle，防下次 saveCurrent 覆盖回旧标题）+ 列表刷新。元数据
  /// 操作不动 transcript，运行中亦可（无会话态扰动，故不走运行守卫）。
  Future<void> _renameConversation(
    ConversationMeta meta,
    String rawTitle,
  ) async {
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
  /// 触发即停(abort 在途任务)+ 会话快照落盘(保存部分进度,可稍后从会话恢复),
  /// 否则留在页内。非运行态不拦截(零摩擦)。
  Future<bool> _confirmLeaveWhileRunning() async {
    if (!_status.running) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('任务运行中'),
        content: const Text(
          '离开将中止当前任务并保存当前进度快照（可从会话恢复），'
          '在途调用已发出的结果仍会回填。确定离开？',
        ),
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
    // D 外溢拦截:触发即停(中止在途任务,避免任务在后台泄漏运行)+ 会话快照落盘
    // (显式落盘当前部分进度,趁仍 mounted 保证写入;随后 PopScope 弹栈,循环
    // finally 的 _persistCurrent 再补一次幂等写入)。
    _abort();
    await _persistCurrent();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    // F1（review-fix-2026-10）：PopScope 的 canPop 必须随运行态即时翻转——
    // 原写法只在页面级 build 求值一次，而运行态变更只通知 body 内的
    // ListenableBuilder，首 Run 期间 canPop 恒 true，返回手势直接弹栈（运行中
    // 离开确认拦截实际失灵）。现仅 PopScope 一层随 statusListenable 重建；
    // Scaffold 经 child 参数缓存原实例，状态带/输入集群的局部重建切分不变。
    return ListenableBuilder(
      listenable: _status.statusListenable,
      child: Scaffold(
        // P1：弹键盘时收起主区，避免遮挡表单（默认 true，此处显式锁定）。
        resizeToAvoidBottomInset: true,
        drawer: _buildDrawer(),
        appBar: AppBar(
          // 会话标题进 AppBar（D13 多会话：切会话后知道自己所在会话）。
          title: Text(
            _archive?.currentTitle.isEmpty ?? true
                ? 'GoodHub'
                : _archive!.currentTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // B2（page-beautify）：会话记忆入口上收 AppBar——原右下悬浮 ≡ FAB
          // 与「回到最新」同尺寸垂直堆叠、主次不分，且 reorder 图标表意弱
          // （排序/菜单心智，且与归因条「≡」前缀撞车，A3 同源半题）。改 Bolt
          // 图标（与流内「⚡ 已记录」胶囊同符号）；点击弹 BottomSheet 汇总列表
          // （_showMemoryListSheet，纯展示不变）。
          actions: [
            // A7（page-beautify P3）：命名与抽屉「记忆库」（全局）区分——
            // 原「会话记忆」vs「记忆看板」两套「记忆」用户必混。
            // P2-11（2026-10-22）：由「有胶囊才出现」改**常驻且恒可点**——
            // ① 消灭首颗胶囊入轨时 AppBar 的布局跳变；② 常驻但不给动作 = 死
            // 控件（违反 SSOT §1「禁止静默禁用」），故无记忆时点开仍是同一个
            // 汇总列表的空态说明，而不是置灰。有/无记忆以图标色分档（§6 双
            // 通道：颜色 + tooltip 文本）。
            _MemoryEntryButton(hasMemory: _status.hasMemoryCapsules, onPressed: _showMemoryListSheet),
            // A6（page-beautify P3）已撤销（2026-10-17 用户拍板）：⚙ 设置直达
            // 从对话页 AppBar 摘除，设置入口回归抽屉底部。
          ],
        ),
        // 切片 B/D：状态带与轨道列表经 controller 双 Listenable 切分——status 变更
        // 仅重建状态带+输入集群，tracks 变更仅重建双轨流，互不打扰；二者合并为本
        // 件的重建触发源。40ms 文本流（C）走 TrackText 自管，不触发本 ListenableBuilder。
        body: ListenableBuilder(
          listenable: Listenable.merge([
            _status.statusListenable,
            _status.tracksListenable,
          ]),
          builder: (context, _) => Column(
            children: [
              Expanded(
                // 上翻看历史时不劫持滚动；离底时给「回到最新」浮钮。B2 后
                // 全页唯一悬浮钮（记忆入口已上收 AppBar），主操作不再与
                // 次级入口竞争右下角。
                child: Stack(
                  children: [
                    DualTrackStream(
                      entries: _status.tracks,
                      listenable: _status.tracksListenable,
                      controller: _scrollCtrl,
                      // 未配置时的可操作引导在轨道内引导卡（ux-hardening P0-1，
                      // _ensureGuide），空态提示只承担已配置用户的首次指引。
                      emptyHint: '下达自然语言任务，宿主调度已挂载服务完成',
                    ),
                    // B2：唯一悬浮钮出场/退场包 AnimatedSwitcher（180ms 淡入，
                    // ui-design §4.2 紧凑减速；替代原瞬时出现——离底事件应有
                    // 可感知的出现过程而非「闪出一钮」）。注意 Positioned 必须
                    // 是 Stack 直接子级（隔 RenderObjectWidget 时 parent data
                    // 不被应用，定位失效），故动效包在 Positioned 内层包按钮本体。
                    if (!_status.autoFollow && _status.tracks.isNotEmpty)
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: AnimatedSwitcher(
                          duration: t.fastDuration,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(opacity: animation, child: child),
                          // P1-10（2026-10-22）：离底期间下方新增内容带计数徽标
                          // ——同一个箭头曾同时表达「只是翻上去了」和「下面有 N
                          // 条没看」，用户无法判断该不该点。计数 > 0 才标强调色。
                          child: _ScrollToBottomFab(
                            key: const ValueKey('chat-scroll-bottom'),
                            missed: _status.missedSinceDetach,
                            onPressed: () {
                              _scrollCtrl
                                  .animateTo(
                                    _scrollCtrl.position.maxScrollExtent,
                                    duration: t.fastDuration,
                                    curve: Curves.easeOut,
                                  )
                                  .then((_) {
                                    if (mounted) {
                                      _status.setAutoFollow(true);
                                    }
                                  });
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 底部控制集群：限宽/SafeArea/留白**一律由 ChatComposer 自持**
              // （任何复用面都该拿到同一套布局）。页面侧只传数据与回调——曾在
              // 此重复套一层 SafeArea+Center+ConstrainedBox+Padding，导致输入区
              // 比 ui-design §5 窄 24dp、底部多垫 16dp（2026-10-22 P0-1：布局
              // owner 单一化，删外层重复包装）。
              ChatComposer(
                inputCtrl: _inputCtrl,
                running: _status.running,
                hasContext: _hasContext,
                contextId: _session.activePrivateServerId,
                endpointName: _endpointName,
                hasEndpoints: _endpoints.isNotEmpty,
                localPluginCount: _localPlugins.length,
                pillTone: _status.pillTone,
                pillLabel: _status.pillLabel,
                runStartedAt: _status.runStartedAt,
                onOpenMenu: _openComposerMenu,
                // 资源附件（M1-T3）：药丸展示 + 选择/移除回调；数据
                // 流出，零依赖本页私有态（composer 头部口径）。
                pendingResources: List.unmodifiable(_pendingResources),
                onPickResource: _pickResource,
                onRemoveResource: (id) => setState(
                  () => _pendingResources.removeWhere((r) => r.id == id),
                ),
                // 回车与发送钮统一走本分支（composer 不判 emptiness）：
                // running 时按钮已变中止键，此处拦下并给 SnackBar；空输入同样
                // 给一次性反馈（P1-9——桌面端 Enter 曾静默无反应，等同死控件）。
                onSend: () {
                  if (!_guardRunning('发送')) return;
                  if (_inputCtrl.text.trim().isEmpty) {
                    _toast('先说点什么再发送');
                    return;
                  }
                  _send();
                },
                onAbort: _abort,
              ),
            ],
          ),
        ),
      ),
      builder: (context, child) => PopScope(
        canPop: !_status.running,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final leave = await _confirmLeaveWhileRunning();
          if (!leave) return;
          if (!mounted) return;
          Navigator.of(this.context).pop();
        },
        child: child!,
      ),
    );
  }
}

/// AppBar「本轮记忆」入口（B2 定位 + P2-11 常驻化）。
///
/// 常驻 + 恒可点：无记忆时点开汇总列表的空态说明（解释「什么时候这里会有
/// 东西」），而不是置灰——置灰即死控件，违反 SSOT §1「禁止静默禁用」。
/// 有/无记忆两档以图标色区分（§6 双通道：颜色 + tooltip 文本）。
class _MemoryEntryButton extends StatelessWidget {
  const _MemoryEntryButton({
    required this.hasMemory,
    required this.onPressed,
  });

  final bool hasMemory;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return IconButton(
      tooltip: hasMemory ? '本轮记忆' : '本轮记忆（暂无，点击查看说明）',
      onPressed: onPressed,
      icon: Icon(
        Icons.bolt,
        color: hasMemory ? t.l1Ok : t.terminalMuted,
      ),
    );
  }
}

/// 「回到最新」悬浮钮（chat-interaction §3：消息流唯一悬浮钮）。
///
/// P1-10（2026-10-22）：两层含义此前共用同一个向下箭头——「只是翻上去了」与
/// 「下面还有 N 条没看」，用户无法判断该不该点。现按 `missed` 分档：有新内容
/// 挂计数徽标 + 数据指针强调色（§1）+ tooltip 明说条数；纯离底态保持低调。
/// 双通道（§6）：徽标数字 + tooltip 文本，不单靠颜色。
/// heroTag 保留原值（与既有 Hero 动画/测试键位一致）。
class _ScrollToBottomFab extends StatelessWidget {
  const _ScrollToBottomFab({
    super.key,
    required this.missed,
    required this.onPressed,
  });

  /// 离底期间新增且未看的条目数（0 = 只是翻上去了，无新内容）。
  final int missed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final hasNew = missed > 0;
    final icon = const Icon(Icons.arrow_downward);
    return FloatingActionButton.small(
      heroTag: 'chat-scroll-bottom',
      tooltip: hasNew ? '下方有 $missed 条新内容' : '回到最新',
      onPressed: onPressed,
      child: hasNew
          ? Badge.count(
              count: missed,
              backgroundColor: t.l1Info,
              child: icon,
            )
          : icon,
    );
  }
}
