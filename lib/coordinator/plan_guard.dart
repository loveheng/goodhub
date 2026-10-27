/// PlanGuard——计划围栏装饰器（多插件任务编排 B1）。
///
/// 规格 SSOT：`docs/design/task-orchestration.md`。**装饰链序铁律**：
/// `PlanProposalTool → PlanGuard → PermissionGateway → ToolRouter`——围栏在
/// 网关**之前**，阶段外写调用直接拒绝（不产生确认卡，杜绝批量卡与单步卡
/// 同屏打架）。
///
/// - **两段裁决**：phase-0（总管模式武装、计划确认前）一切 L2 写拒绝并引导
///   提议；phase-1（确认后）`(serverId, toolName)` ∈ 冻结集且非毁坏 → 放行
///   （网关凭 planGrant 免卡）、∈ 集且毁坏 → 逐条实参级 L2（D1）、∉ 集且
///   L2 → 三段式终结拒绝（R5）；L1 只读直通（围栏只管写）；
/// - **同批伴随写**：同批 tool_calls 含 propose_task_plan 时其余 L2 写统一
///   deferred_to_plan（isError=false，模型不重试）——批内协调依赖 AgentLoop
///   P3-1 的「列表构造序同步前缀」时序：propose 拦截在同步前缀登记标志，
///   写调用（先序）经单跳让位后再判定，顺序无关；
/// - **step-id 协议**：无条件剥离（含无计划态误填）后下路由；按 id 归属台账，
///   缺失/无效走「同对最早未终态步骤」启发式（inferred 标记）；
/// - **配额**：每 (server, tool) 对派发即计数、成败均计、跨续跑累计；超限
///   不熔断，结果附引导注记（软上限）；
/// - **实参透明化（R1）**：每步首笔写调用的实参摘要经 [onStepEcho] 回显轨道
///   并入 [PlanRunState.stepEchoes]（planGrant 免卡 ≠ 免视）。
library;

import 'dart:convert';

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';
import 'task_plan.dart';
import 'tool_router.dart' show ToolRouter, parsePrefixedToolName;

class PlanGuard implements ToolExecutor {
  PlanGuard({
    required this.inner,
    required this.state,
    required this.isWriteTool,
    required this.annotationsFor,
    this.onStepEcho,
  });

  /// 被装饰的内层（PermissionGateway 一侧）。
  final ToolExecutor inner;

  /// 会话级编排状态（冻结集 / 台账 / 配额 / 总管开关的唯一事实源）。
  final PlanRunState state;

  /// 写判定（= PermissionGateway.classify == l2Write 的 tearoff——禁第二判定源）。
  final bool Function(String toolName, Map<String, Object?>? annotations)
      isWriteTool;

  /// 注解目录查询（= PermissionGateway.annotationsFor——同一份目录）。
  final Map<String, Object?>? Function(String prefixedName) annotationsFor;

  /// 实参摘要回显（轨道流；null = 不回显，stepEchoes 照记）。
  final void Function(String message)? onStepEcho;

  /// 冻结集激活期对冻结集写工具注入 step-id 可选属性（每轮经既有
  /// toolsProvider 重取——propose 回填后的首轮即生效、Run 收口自然消失；
  /// 非编排会话与冻结集外的工具 Schema 恒干净，四轮收口口径）。
  List<CloudToolSchema> injectStepIds(List<CloudToolSchema> base) {
    if (!state.isActive) return base;
    final frozen = state.frozenSteps;
    return injectPlanStepIdSchema(
      base,
      inFrozenSet: (serverId, toolName) =>
          frozen.any((s) => s.server == serverId && s.tool == toolName),
    );
  }

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall rawCall) async {
    // ① step-id 无条件剥离（含无计划态误填；解析失败原样透传）
    final stripped = stripPlanStepId(rawCall.argumentsJson);
    final call = stripped.argumentsJson == rawCall.argumentsJson
        ? rawCall
        : AssembledToolCall(
            id: rawCall.id,
            name: rawCall.name,
            argumentsJson: stripped.argumentsJson,
          );

    // ② 宿主元工具 / 本地工具（无服务前缀）直通——计划围栏只管插件写面
    final parsed = parsePrefixedToolName(call.name);
    if (parsed == null) return inner.execute(call);

    // ③ L1 只读直通（台账只聚合写调用）
    final annotations = annotationsFor(call.name);
    if (!isWriteTool(parsed.toolName, annotations)) {
      return inner.execute(call);
    }

    // ④ 同批伴随写 deferred（无论模式；propose 同步前缀已登记的批次直通到此）
    if (state.proposalPending) return _deferredToPlan();

    // ⑤ phase-0 / 专科模式：单跳让位，令同批后序 propose 的同步前缀先登记
    //    （AgentLoop P3-1 列表构造序保证——写先于 propose 的批次同样命中
    //    deferred，顺序无关；此时所有批内同步前缀必已完成）。
    if (!state.isActive) {
      await Future<void>.delayed(Duration.zero);
      if (state.proposalPending) return _deferredToPlan();
      if (state.armed) {
        return ToolExecutionResult(
          isError: true,
          content: '[PLAN_REQUIRED] ${ToolRouter.prefixed(parsed.serverId, parsed.toolName)} '
              '调用已拒绝（总管模式：写操作需先经计划确认）。'
              '请调用 propose_task_plan 提议计划（goal + steps，每步 = '
              '目标服务 + 工具名 + 一句话意图，不带参数）。',
        );
      }
      return inner.execute(call); // 专科模式：既有网关轻确认
    }

    // ⑥ phase-1 围栏（冻结集四分支）
    final ledger = state.ledger!;
    final attribution = ledger.attribute(
      serverId: parsed.serverId,
      toolName: parsed.toolName,
      stepId: stripped.stepId,
    );
    if (attribution == null) {
      // 原始计划全量步（含剔除步）——剔除对 = 「用户已在计划卡剔除」，
      // 从未入计划 = 「不在已确认计划内」（R5 文案分类学）。
      final inPlan = state.ledger!.view().any((v) =>
          v.step.server == parsed.serverId && v.step.tool == parsed.toolName);
      if (inPlan) {
        // 计划外补调：记录进台账（聚合卡展示），执行拒绝——用户已显式剔除。
        ledger.recordOutOfBand(parsed.serverId, parsed.toolName);
        return _fatal(parsed.serverId, parsed.toolName, '用户已在计划卡剔除');
      }
      return _fatal(parsed.serverId, parsed.toolName, '不在已确认计划内');
    }
    final step = attribution.step;
    final count = state.quota.register(parsed.serverId, parsed.toolName); // 派发即计数
    final isFirstCall = !state.stepEchoes.containsKey(step.id);
    if (isFirstCall) {
      final summary = _echoSummary(
        stepId: step.id,
        call: call,
        serverId: parsed.serverId,
        toolName: parsed.toolName,
        inferred: attribution.inferred,
        note: step.note,
      );
      state.stepEchoes[step.id] = summary;
      onStepEcho?.call(summary);
    }
    ledger.recordDispatch(step);
    final result = await inner.execute(call);
    ledger.recordResult(step, isError: result.isError);
    if (state.quota.isOverLimit(count)) {
      return ToolExecutionResult(
        isError: result.isError,
        content: '${result.content}\n\n[宿主注：工具 '
            '${ToolRouter.prefixed(parsed.serverId, parsed.toolName)} 计划内调用'
            '已达配额上限 ${state.quota.pairLimit}（累计 $count 次，派发即计）——'
            '请收尾或说明剩余工作，避免写放大]',
      );
    }
    return result;
  }

  /// 同批伴随写统一回填（拍板：isError=false，模型不重试；计划取消则作废——
  /// user_rejected 回填已告知）。
  ToolExecutionResult _deferredToPlan() => ToolExecutionResult(
        isError: false,
        content: jsonEncode({
          'status': 'deferred_to_plan',
          'message': '已并入同批次计划提议，待计划确认后执行',
        }),
      );

  /// 三段式终结文案（R5）：围栏拒绝 isError=true，照常计入 C1 熔断——
  /// 排查卡的「跳过」即顽固重试的出口（保留不豁免）。
  ToolExecutionResult _fatal(String serverId, String toolName, String reason) =>
      ToolExecutionResult(
        isError: true,
        content: '[FATAL_PERMISSION_DENIED] '
            '${ToolRouter.prefixed(serverId, toolName)} '
            '本次任务不可调用（原因：$reason）。'
            '严禁重试，跳过此步骤继续剩余计划。',
      );

  /// 首笔写调用实参摘要（R1：关键参数键值一行；超长截断）。
  String _echoSummary({
    required String stepId,
    required AssembledToolCall call,
    required String serverId,
    required String toolName,
    required bool inferred,
    required String? note,
  }) {
    String brief;
    Object? decoded;
    try {
      decoded = jsonDecode(call.argumentsJson);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map && decoded.isNotEmpty) {
      final pairs = <String>[];
      for (final e in decoded.entries.take(4)) {
        var value = '${e.value}'.replaceAll('\n', ' ');
        if (value.length > 24) value = '${value.substring(0, 24)}…';
        pairs.add('${e.key}=$value');
      }
      brief = pairs.join(', ');
      if (decoded.length > 4) brief += ' …';
    } else {
      brief = call.argumentsJson.length > 60
          ? '${call.argumentsJson.substring(0, 60)}…'
          : call.argumentsJson;
    }
    return '[$stepId] '
        '${ToolRouter.prefixed(serverId, toolName)}'
        '${inferred ? '（推断归属）' : ''} ← $brief'
        '${note == null || note.isEmpty ? '' : ' ｜ 叮嘱：$note'}';
  }
}
