/// TaskPlan 计划模型 + 元工具入参校验（多插件任务编排 B1）。
///
/// 规格 SSOT：`docs/design/task-orchestration.md`。本文件是**纯模型层**：
/// 计划提议解析、可见面校验（校验层拒绝 / 单服务降级 / 预检置灰三分）、
/// 冻结步骤、步骤台账（[PlanLedger]）、每对调用配额（[PlanQuota]）、
/// step-id Schema 注入/剥离、会话级编排状态（[PlanRunState]）。
/// 执行链装饰器与元工具执行器分见 `plan_guard.dart` / `plan_proposal_tool.dart`。
///
/// **生命周期层级**（coding-standards §8.4 ①）：[PlanRunState] = 会话级
/// （台账与配额跨续跑累计，比照 `SamplingQuota` 独立实例入参不进快照）；
/// planGrant 授权本体 = Run 级（绑定确认手势所在 Run，收口即销毁）；
/// 其余类型无状态。
library;

import 'dart:convert';

import '../llm/cloud/cloud_llm.dart';
import 'permission_gateway.dart' show PlanGrantSource;
import 'tool_router.dart' show parsePrefixedToolName;

/// step-id 经 Schema 声明的可选属性名（四轮拍板：Strict Tool Use 模型不生成
/// Schema 外字段，须在 Schema 内声明；PlanGuard 无条件剥离后下路由）。
const String kPlanStepIdKey = '_plan_step_id';

/// 写步骤上限（计划粒度 = 意图级；超过引导拆分多计划）。
const int kMaxPlanWriteSteps = 8;

/// 每对 (server, tool) 调用软配额初值（Q1 拍板：12 统一起步，TO-B2 真机回归）。
const int kPlanPairQuotaDefault = 12;

// ---------------------------------------------------------------------------
// 提议解析（元工具入参形状）
// ---------------------------------------------------------------------------

/// 计划提议的单步骤（意图级：目标服务 + 工具名 + 一句话意图，不带参数）。
class PlanProposalStep {
  const PlanProposalStep({
    required this.id,
    required this.server,
    required this.tool,
    required this.intent,
  });

  final String id;
  final String server;
  final String tool;
  final String intent;
}

/// `propose_task_plan` 入参整体（goal + steps）。畸形入参解析返 null——
/// 调用方回 isError 引导（校验层拒绝、不弹卡）。
class PlanProposal {
  const PlanProposal({required this.goal, required this.steps});

  final String goal;
  final List<PlanProposalStep> steps;

  /// 严格解析：任一步骤缺字段/类型不符即整体畸形返 null（禁 dynamic 渗漏）。
  static PlanProposal? fromArgumentsJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final goal = decoded['goal'];
    if (goal is! String || goal.trim().isEmpty) return null;
    final rawSteps = decoded['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) return null;
    final steps = <PlanProposalStep>[];
    for (final raw in rawSteps) {
      if (raw is! Map) return null;
      final id = raw['id'];
      final server = raw['server'];
      final tool = raw['tool'];
      final intent = raw['intent'];
      if (id is! String ||
          id.isEmpty ||
          server is! String ||
          server.isEmpty ||
          tool is! String ||
          tool.isEmpty ||
          intent is! String ||
          intent.isEmpty) {
        return null;
      }
      steps.add(PlanProposalStep(
        id: id,
        server: server,
        tool: tool,
        intent: intent,
      ));
    }
    return PlanProposal(goal: goal.trim(), steps: List.unmodifiable(steps));
  }
}

// ---------------------------------------------------------------------------
// 可见面与校验（校验层：拒绝即 ToolResult 引导、不弹卡）
// ---------------------------------------------------------------------------

/// 计划提议时刻的可见面上下文（装配层组：全部 public + 至多一个已激活
/// private，SSOT §结论「计划面 = 当前可见面」）。
class PlanFaceContext {
  PlanFaceContext({
    required Set<String> mountedServerIds,
    required Set<String> privateServerIds,
    required String? activePrivateSlotId,
    required this.toolOf,
    this.availabilityIssue,
  })  : _mounted = Set.of(mountedServerIds),
        _private = Set.of(privateServerIds),
        _slot = activePrivateSlotId;

  final Set<String> _mounted;
  final Set<String> _private;
  final String? _slot;

  /// 裸工具名 → schema（存在性 + annotations 识别源；未知工具返回 null）。
  final CloudToolSchema? Function(String serverId, String toolName) toolOf;

  /// 服务就绪预检（R6 起草期）：非 null = 置灰原因（离线/未信任等）。
  final String? Function(String serverId)? availabilityIssue;

  /// server 是否在当前可见面（全部 public + ≤1 已激活 private）。
  bool isVisibleServer(String serverId) =>
      _mounted.contains(serverId) &&
      (!_private.contains(serverId) || _slot == serverId);

  /// 可见面违规原因（null = 合规）。私有非槽位统一引单槽纪律话术。
  String? visibleFaceIssue(String serverId) {
    if (!_mounted.contains(serverId)) {
      return '服务 $serverId 未挂载';
    }
    if (_private.contains(serverId) && _slot != serverId) {
      return '私有服务单一槽位（计划面 = 全部公共 + 至多一个已激活私有），'
          '当前私有槽位${_slot == null ? '为空' : '由 $_slot 占用'}，'
          '不可跨私有服务编排——先 use_server 锁定目标服务再提议';
    }
    return null;
  }
}

/// 校验后的单步骤行（写步骤 / 读信息行；blockedReason 非空 = 预检置灰）。
class PlanStepRow {
  const PlanStepRow({
    required this.step,
    required this.isWrite,
    this.destructive = false,
    this.blockedReason,
  });

  final PlanProposalStep step;
  final bool isWrite;

  /// destructiveHint 显式 true（D1：毁坏性不可批量授权，卡面徽标 + 逐条 L2）。
  final bool destructive;

  /// 起草期预检（未挂载/未信任/离线）：非 null = 卡面置灰 + 原因。
  final String? blockedReason;
}

/// 校验三分结果（sealed：调用方穷尽匹配）。
sealed class PlanCheckResult {
  const PlanCheckResult();
}

/// 校验层拒绝（不弹卡，isError 引导模型自纠）。
class PlanCheckRejected extends PlanCheckResult {
  const PlanCheckRejected(this.reason);

  final String reason;
}

/// 自动降级「无需计划」（单服务写集 / 无写步骤）：零 UI，模型按既有轻确认走。
class PlanCheckUnnecessary extends PlanCheckResult {
  const PlanCheckUnnecessary(this.reason);

  final String reason;
}

/// 通过：可进批量确认卡。
class PlanCheckOk extends PlanCheckResult {
  const PlanCheckOk({required this.writeSteps, required this.readRows});

  final List<PlanStepRow> writeSteps;
  final List<PlanStepRow> readRows;
}

/// 校验 SSOT（验收口径：可见面/跨双 private 拒绝/单服务降级/畸形/超限/未知
/// 服务工具/预检置灰）。写步骤分类与 PermissionGateway.classify 同口径
/// （经 [isWriteTool] 注入——gatewat tearoff，禁第二判定源）。
PlanCheckResult validatePlanProposal({
  required PlanProposal proposal,
  required PlanFaceContext face,
  required bool Function(String toolName, Map<String, Object?>? annotations)
      isWriteTool,
}) {
  if (proposal.goal.isEmpty) {
    return const PlanCheckRejected('goal 不能为空');
  }
  if (proposal.steps.isEmpty) {
    return const PlanCheckRejected('steps 不能为空');
  }
  final ids = <String>{};
  for (final s in proposal.steps) {
    if (!ids.add(s.id)) {
      return PlanCheckRejected('步骤 id 重复: ${s.id}');
    }
  }
  final rows = <PlanStepRow>[];
  for (final s in proposal.steps) {
    final faceIssue = face.visibleFaceIssue(s.server);
    if (faceIssue != null) {
      return PlanCheckRejected('步骤 ${s.id}: $faceIssue');
    }
    final schema = face.toolOf(s.server, s.tool);
    if (schema == null) {
      return PlanCheckRejected('步骤 ${s.id}: 服务 ${s.server} '
          '无工具 ${s.tool}（裸名，先经只读工具确认目标服务真实工具名）');
    }
    final blocked = face.availabilityIssue?.call(s.server);
    final destructiveHint = schema.annotations?['destructiveHint'];
    rows.add(PlanStepRow(
      step: s,
      isWrite: isWriteTool(s.tool, schema.annotations),
      destructive: destructiveHint is bool && destructiveHint,
      blockedReason: blocked,
    ));
  }
  final writes = rows.where((r) => r.isWrite).toList();
  if (writes.length > kMaxPlanWriteSteps) {
    return PlanCheckRejected(
        '写步骤 ${writes.length} 个超上限 $kMaxPlanWriteSteps——'
        '预期大量调用（逐日建条）请拆分多个计划分批提议');
  }
  if (writes.isEmpty) {
    return const PlanCheckUnnecessary('计划无写步骤（全部为只读探测），无需计划');
  }
  final writeServers = writes.map((r) => r.step.server).toSet();
  if (writeServers.length == 1) {
    return PlanCheckUnnecessary(
        '写集仅涉单服务 ${writes.first.step.server}，按常规单步确认执行即可');
  }
  return PlanCheckOk(
    writeSteps: List.unmodifiable(writes),
    readRows: List.unmodifiable(rows.where((r) => !r.isWrite)),
  );
}

// ---------------------------------------------------------------------------
// 冻结步骤与台账（PlanLedger）
// ---------------------------------------------------------------------------

/// 用户确认后的冻结写步骤（剔除步不入此列；note = 单步叮嘱 user_note）。
class FrozenPlanStep {
  const FrozenPlanStep({
    required this.id,
    required this.server,
    required this.tool,
    required this.intent,
    this.note,
  });

  final String id;
  final String server;
  final String tool;
  final String intent;

  /// 单步叮嘱（确认卡输入，执行期随首笔回显给模型；可空）。
  final String? note;
}

/// 台账步骤视图（不可变投影，卡面 / 快照 / 归档共用）。
class PlanLedgerStepView {
  const PlanLedgerStepView({
    required this.step,
    required this.calls,
    required this.ok,
    required this.failed,
    required this.skippedByUser,
    this.closedPending = false,
  });

  final FrozenPlanStep step;
  final int calls;
  final int ok;
  final int failed;

  /// 用户在计划卡剔除（终态；续跑不重激活，改动须新卡）。
  final bool skippedByUser;

  /// Run 收口未执行（聚合卡显示 skipped；续跑快照归「待继续」——毒丸 E）。
  final bool closedPending;

  /// 展示口径的 skipped（用户剔除 或 收口未执行）。
  bool get skipped => skippedByUser || closedPending;

  /// 状态文案：有成功 ok×k / 全失败 failed / 无调用 pending / 剔除 skipped。
  String get statusText => skipped
      ? 'skipped'
      : ok > 0
          ? 'ok×$ok'
          : calls > 0
              ? 'failed'
              : 'pending';
}

/// 聚合状态（只由写步骤判定）。
enum PlanAggregateStatus { completed, partial, failed }

/// 编排任务的步骤执行账本（术语 PlanLedger，防撞 goodshare task_ledger_page）。
/// 归属协议：step-id 有效且与 (server, tool) 对匹配 → 按 id；缺失/无效 →
/// 「同对最早未终态步骤」启发式（inferred 标记）；同对全部剔除后再调用 =
/// 计划外补调。
class PlanLedger {
  PlanLedger({required List<FrozenPlanStep> steps}) {
    for (final s in steps) {
      _states.add(_State(s));
    }
  }

  final List<_State> _states = [];
  final Map<String, int> _outOfBand = {};

  /// 归属调用到步骤；null = 计划外补调（同对无未剔除步骤）。
  ({FrozenPlanStep step, bool inferred})? attribute({
    required String serverId,
    required String toolName,
    String? stepId,
  }) {
    if (stepId != null && stepId.isNotEmpty) {
      for (final s in _states) {
        if (s.step.id == stepId) {
          if (s.step.server == serverId &&
              s.step.tool == toolName &&
              !s.skipped) {
            return (step: s.step, inferred: false);
          }
          break; // id 存在但对不匹配 / 已剔除 → 启发式兜底
        }
      }
    }
    for (final s in _states) {
      if (s.step.server == serverId &&
          s.step.tool == toolName &&
          !s.skipped) {
        return (step: s.step, inferred: true);
      }
    }
    return null;
  }

  /// 派发即计数（成败均计——[recordResult] 另记成败分布）。
  void recordDispatch(FrozenPlanStep step) {
    final s = _stateOf(step);
    if (s == null) return;
    s._calls++;
  }

  void recordResult(FrozenPlanStep step, {required bool isError}) {
    final s = _stateOf(step);
    if (s == null) return;
    isError ? s._failed++ : s._ok++;
  }

  void markSkipped(String stepId) {
    for (final s in _states) {
      if (s.step.id == stepId) s._skipped = true;
    }
  }

  /// Run 收口：剩余 pending（无调用且未剔除）记收口未执行——聚合卡显示
  /// skipped；续跑快照仍归「待继续」（毒丸 E：不重写已完成条目、待继续清单
  /// 不丢）。与用户剔除（[markSkipped]）严格分立。
  void markPendingSkipped() {
    for (final s in _states) {
      if (!s._skipped && s._calls == 0) s._closedPending = true;
    }
  }

  void recordOutOfBand(String serverId, String toolName) =>
      _outOfBand['$serverId|$toolName'] =
          (_outOfBand['$serverId|$toolName'] ?? 0) + 1;

  int outOfBandCount(String serverId, String toolName) =>
      _outOfBand['$serverId|$toolName'] ?? 0;

  Map<String, int> get outOfBandAll => Map.unmodifiable(_outOfBand);

  List<PlanLedgerStepView> view() => [
        for (final s in _states) s.view(),
      ];

  /// 聚合状态（只由写步骤判定；frozen 全为写步骤）：全部有成功 = 完成 /
  /// 部分有成功 = 部分完成 / 全无成功 = 失败。
  PlanAggregateStatus aggregateStatus() {
    final okAny = _states.any((s) => s._ok > 0);
    final allOk = _states.every((s) => s._ok > 0);
    if (allOk) return PlanAggregateStatus.completed;
    return okAny ? PlanAggregateStatus.partial : PlanAggregateStatus.failed;
  }

  /// 续跑台账快照文本（防重写三件套①）：已完成步带「已写部分勿重复」。
  String snapshotText(String goal) {
    final done = <String>[];
    final todo = <String>[];
    for (final s in _states) {
      if (s._skipped && s._calls == 0) {
        done.add('${s.step.id} skipped（已剔除勿重做）');
      } else if (s._ok > 0) {
        done.add('${s.step.id} ok×${s._ok}（已写部分勿重复）');
        if (s._failed > 0) done.last += ' failed×${s._failed}';
      } else if (s._calls > 0) {
        done.add('${s.step.id} failed×${s._calls}（此前失败，视情补做）');
      } else if (s._closedPending) {
        todo.add(s.step.id);
      } else {
        todo.add(s.step.id);
      }
    }
    final buffer = StringBuffer('[计划台账快照] 目标：$goal\n');
    buffer.writeAll([for (final d in done) '- $d\n']);
    buffer.write(todo.isEmpty
        ? '- 全部步骤已有产出，仅收尾汇报'
        : '- 待继续：${todo.join('、')}（仅补剩余，勿重写已完成条目）');
    return buffer.toString();
  }

  _State? _stateOf(FrozenPlanStep step) {
    for (final s in _states) {
      if (identical(s.step, step) || s.step.id == step.id) return s;
    }
    return null;
  }
}

class _State {
  _State(this.step);

  final FrozenPlanStep step;
  int _calls = 0;
  int _ok = 0;
  int _failed = 0;
  bool _skipped = false;
  bool _closedPending = false;

  bool get skipped => _skipped;

  PlanLedgerStepView view() => PlanLedgerStepView(
        step: step,
        calls: _calls,
        ok: _ok,
        failed: _failed,
        skippedByUser: _skipped,
        closedPending: _closedPending,
      );
}

// ---------------------------------------------------------------------------
// 每对调用配额（防写放大；软上限不熔断）
// ---------------------------------------------------------------------------

/// 冻结集内每 (server, tool) 对总调用软配额：派发即计数、成败均计、
/// **跨续跑累计**（实例住 [PlanRunState]，随会话级状态存活）。超限不熔断，
/// 由 PlanGuard 引导收尾（见 plan_guard.dart）。
class PlanQuota {
  PlanQuota({this.pairLimit = kPlanPairQuotaDefault});

  final int pairLimit;
  final Map<String, int> _counts = {};

  static String keyOf(String serverId, String toolName) =>
      '$serverId|$toolName';

  /// 派发即计数（成败均计）；返回累计值。
  int register(String serverId, String toolName) {
    final key = keyOf(serverId, toolName);
    return _counts[key] = (_counts[key] ?? 0) + 1;
  }

  int countOf(String serverId, String toolName) =>
      _counts[keyOf(serverId, toolName)] ?? 0;

  bool isOverLimit(int count) => count > pairLimit;
}

// ---------------------------------------------------------------------------
// step-id Schema 注入 / 剥离
// ---------------------------------------------------------------------------

/// 冻结集激活期对冻结集写工具注入可选属性 `_plan_step_id`（每轮经既有
/// toolsProvider 重取——propose 回填后的首轮即生效、Run 收口自然消失）。
/// 非编排会话与冻结集外的工具 Schema 恒干净（四轮收口：禁全天候静态注入）。
List<CloudToolSchema> injectPlanStepIdSchema(
  List<CloudToolSchema> schemas, {
  required bool Function(String serverId, String toolName) inFrozenSet,
}) {
  return [
    for (final s in schemas) _maybeInjectStepId(s, inFrozenSet),
  ];
}

CloudToolSchema _maybeInjectStepId(
  CloudToolSchema schema,
  bool Function(String serverId, String toolName) inFrozenSet,
) {
  final parsed = parsePrefixedToolName(schema.name);
  if (parsed == null || !inFrozenSet(parsed.serverId, parsed.toolName)) {
    return schema;
  }
  final original = schema.parametersSchema;
  final rawProps = original['properties'];
  final props = <String, Object?>{
    if (rawProps is Map)
      for (final e in rawProps.entries)
        if (e.key is String) e.key as String: e.value,
  };
  props[kPlanStepIdKey] = {
    'type': 'string',
    'description': '属于已确认计划的步骤 id，如 s1',
  };
  final params = Map<String, Object?>.of(original);
  params['properties'] = props;
  return CloudToolSchema(
    name: schema.name,
    description: schema.description,
    parametersSchema: params,
    annotations: schema.annotations,
    meta: schema.meta,
    visibility: schema.visibility,
  );
}

/// PlanGuard 无条件剥离 `_plan_step_id`（含无计划态误填）后下路由——插件
/// `additionalProperties: false` 亦无感。解析失败原样透传（下游工具自拒）。
({String argumentsJson, String? stepId}) stripPlanStepId(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return (argumentsJson: raw, stepId: null);
  }
  if (decoded is! Map || !decoded.containsKey(kPlanStepIdKey)) {
    return (argumentsJson: raw, stepId: null);
  }
  final id = decoded[kPlanStepIdKey];
  final cleaned = <String, Object?>{
    for (final e in decoded.entries)
      if (e.key is String) e.key as String: e.value,
  }..remove(kPlanStepIdKey);
  return (argumentsJson: jsonEncode(cleaned), stepId: id is String ? id : null);
}

// ---------------------------------------------------------------------------
// 会话级编排状态（跨续跑累计的 owner）
// ---------------------------------------------------------------------------

/// 编排阶段。awaitingProposal 挂起卡片期由 per-Run guard 内部状态承载
/// （单 guard 单 Run，批内共享），不进会话态。
enum PlanRunPhase { idle, active, completed }

/// Run 收口聚合记录（聚合卡 / 归档数据源）。
class PlanAggregateRecord {
  const PlanAggregateRecord({
    required this.goal,
    required this.status,
    required this.rows,
    required this.outOfBand,
    this.echoByStep = const {},
  });

  final String goal;
  final PlanAggregateStatus status;
  final List<PlanLedgerStepView> rows;
  final Map<String, int> outOfBand;

  /// 逐步骤首笔写调用实参摘要（R1 实参透明化；PlanGuard 写入）。
  final Map<String, String> echoByStep;
}

/// 会话级编排状态 owner（kernel 会话件，生命周期层级：会话级；实例经
/// assemble 独立入参注入——比照 SamplingQuota 先例不进 SessionContext 快照）：
/// 冻结集 / 台账 / 配额跨续跑累计；planGrant 本体仍 Run 级（Run 收口即
/// 销毁，续跑仅经显式手势重激活，不落盘、不跨 Run 存活——红线 6）。
class PlanRunState implements PlanGrantSource {
  PlanRunState({this.onAggregate, PlanQuota? quota})
      : quota = quota ?? PlanQuota();

  /// Run 收口聚合卡出口（广播端口：窗口插轨道卡；null = 无渲染面）。
  final void Function(PlanAggregateRecord record)? onAggregate;

  PlanRunPhase _phase = PlanRunPhase.idle;
  String? _goal;
  PlanLedger? _ledger;

  /// 逐步骤首笔写调用实参摘要（R1；PlanGuard 写入，endRun 进聚合记录）。
  final Map<String, String> stepEchoes = {};

  // ---- 同批伴随写协调（批内标志；propose 拦截同步登记、裁决后清除——
  //      AgentLoop P3-1 列表构造序 + 围栏单跳让位保证同批写可见，顺序无关）----
  bool _proposalPending = false;

  void markProposalPending() => _proposalPending = true;

  void clearProposalPending() => _proposalPending = false;

  bool get proposalPending => _proposalPending;

  /// 总管模式开关（窗口置入；B1 藏于上下文胶囊菜单，非持久化设置项）。
  bool armed = false;

  /// 每对调用配额（跨续跑累计——实例随本状态存活；注入位供测试小配额）。
  final PlanQuota quota;

  PlanRunPhase get phase => _phase;
  String? get goal => _goal;
  PlanLedger? get ledger => _ledger;

  /// phase-1 判据：本 Run 内 grant 生效（确认手势后 / 续跑重激活）。
  bool get isActive => _phase == PlanRunPhase.active;

  /// 续跑重激活的冻结集 = 用户确认集剔除用户剔除步（剔除步重纳入须新卡）；
  /// 收口未执行步原样保留（待继续）。
  List<FrozenPlanStep> get frozenSteps => [
        for (final v in _ledger?.view() ?? const <PlanLedgerStepView>[])
          if (!v.skippedByUser) v.step,
      ];

  /// 用户确认：冻结步骤落账、phase → active（grant 随本 Run 生效）。
  void adoptProposal({
    required String goal,
    required List<FrozenPlanStep> steps,
  }) {
    _goal = goal;
    _ledger = PlanLedger(steps: steps);
    _phase = PlanRunPhase.active;
  }

  /// Run 启动（编排层 plan() 前调用）：completed 态未被显式续跑即放弃——
  /// 用户直接发新消息 = 不续跑，冻结集清空、回到 idle。
  void beginRun() {
    if (_phase == PlanRunPhase.completed) _clear();
  }

  /// Run 收口（机械挂钩 McpAssembly.close，含 abort 路径）：剩余 pending 归
  /// skipped、销毁 grant（phase → completed）、经 [onAggregate] 渲染聚合卡。
  /// 幂等；无活跃计划返 false。
  bool endRun() {
    if (_phase != PlanRunPhase.active) return false;
    final ledger = _ledger!;
    ledger.markPendingSkipped();
    _phase = PlanRunPhase.completed;
    onAggregate?.call(PlanAggregateRecord(
      goal: _goal ?? '',
      status: ledger.aggregateStatus(),
      rows: ledger.view(),
      outOfBand: ledger.outOfBandAll,
      echoByStep: Map.of(stepEchoes),
    ));
    return true;
  }

  /// 续跑手势（聚合卡按钮）：completed → active，冻结集原样重激活、不重弹
  /// 全量卡；返回台账快照文本（合成续跑消息体）。非 completed 返 null。
  String? resume() {
    if (_phase != PlanRunPhase.completed || _ledger == null) return null;
    _phase = PlanRunPhase.active;
    return _ledger!.snapshotText(_goal ?? '');
  }

  /// 计划作废（卡片取消 / user_rejected）：不产生任何围栏与授权语义。
  void abandon() => _clear();

  /// PlanGrantSource（PermissionGateway 消费）：冻结集内（用户未剔除步）
  /// 非毁坏写免卡。毁坏性排除在网关侧显式判定（D1）。
  @override
  bool grants(String serverId, String toolName) =>
      isActive &&
      frozenSteps
          .any((s) => s.server == serverId && s.tool == toolName);

  void _clear() {
    _phase = PlanRunPhase.idle;
    _goal = null;
    _ledger = null;
  }
}
