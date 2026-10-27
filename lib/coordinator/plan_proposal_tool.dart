/// `propose_task_plan` 元工具执行器（多插件任务编排 B1）——DiscoveryExecutor
/// 同族本地拦截位：先于 ToolRouter、不达插件、不进网关导出 Allowlist
/// （控制面原语黑名单纪律，PC 不可见）。规格 SSOT：docs/design/task-orchestration.md。
///
/// - **挂起语义**：收到调用 → 渲染批量确认卡 → Run 不中断，该 tool_call 挂起
///   等手势（L2 网关同一先例）；卡片取消 / abort（窗口级联完成 completer）→
///   回填 user_rejected，模型无围栏收尾；
/// - **同批伴随写**：拦截即向 [PlanGuard.markProposalPending] 同步登记（AgentLoop
///   P3-1 列表构造序保证同批写调用可见，写面 deferred_to_plan 由围栏回填）；
/// - **校验层拒绝即 ToolResult 引导、不弹卡**；单服务写集 / 无写步骤自动降级
///   「无需计划」（零 UI）；headless 无确认界面恒拒绝（fail-closed，§4.3）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';
import 'plan_guard.dart';
import 'task_plan.dart';
import 'tool_router.dart' show ToolRouter;

/// 批量确认卡数据（写步骤行 + 读信息行；UI 按 [PlanStepRow.isWrite] 分流）。
class PlanProposalCard {
  const PlanProposalCard({required this.goal, required this.rows});

  final String goal;
  final List<PlanStepRow> rows;
}

/// 单步确认结果（开关开 + 可选单步叮嘱）。
class PlanStepApproval {
  const PlanStepApproval({required this.stepId, this.note});

  final String stepId;
  final String? note;
}

/// 批量确认卡裁决回执：approved=false = 取消（计划作废）。
class PlanProposalDecision {
  const PlanProposalDecision({
    required this.approved,
    this.approvals = const [],
  });

  final bool approved;

  /// 开关为开的写步骤集（剔除步不在内）；各步叮嘱合并回填 user_note。
  final List<PlanStepApproval> approvals;
}

/// 确认卡委托（UI 实现；null = headless fail-closed——提议恒拒绝）。
abstract interface class PlanProposalDelegate {
  Future<PlanProposalDecision> confirmPlan(PlanProposalCard card);
}

class PlanProposalTool implements ToolExecutor {
  PlanProposalTool({
    required this.inner,
    required this.router,
    required this.state,
    required this.isWriteTool,
    this.delegate,
    this.availabilityIssue,
  });

  static const String toolName = 'propose_task_plan';

  final ToolExecutor inner;
  final ToolRouter router;
  final PlanRunState state;

  /// 写判定（= PermissionGateway.classify tearoff——校验与网关同口径）。
  final bool Function(String toolName, Map<String, Object?>? annotations)
      isWriteTool;

  /// 批量确认卡委托（null = headless fail-closed）。
  final PlanProposalDelegate? delegate;

  /// 起草期预检（R6：未挂载/未信任/离线 → 卡面置灰；null = 不预检）。
  final String? Function(String serverId)? availabilityIssue;

  /// 元工具声明（readOnlyHint: true——提议无副作用，卡即其交互；裸名随
  /// AgentLoop tools 下发，由本执行器在最外层拦截，不进网关确认）。
  static CloudToolSchema schema() => const CloudToolSchema(
        name: toolName,
        description: '跨多个服务的写操作任务先提议计划（一次批量授权）：'
            'goal = 整体目标一句话；steps 每步 = {id 步骤号, server 目标服务 id, '
            'tool 裸工具名, intent 一句话意图}，不带参数（执行期现算）。'
            '约束：先用只读工具探测并备齐写工具必填上下文；写步骤 ≤8；'
            '只列写步骤（单服务写集无需计划，直接调用）。',
        parametersSchema: {
          'type': 'object',
          'properties': {
            'goal': {'type': 'string', 'description': '整体目标一句话'},
            'steps': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string', 'description': '步骤 id，如 s1'},
                  'server': {'type': 'string', 'description': '目标服务 id'},
                  'tool': {'type': 'string', 'description': '裸工具名'},
                  'intent': {'type': 'string', 'description': '一句话意图'},
                },
                'required': ['id', 'server', 'tool', 'intent'],
              },
            },
          },
          'required': ['goal', 'steps'],
        },
        annotations: {'readOnlyHint': true},
      );

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    if (call.name != toolName) return inner.execute(call);
    if (state.proposalPending) {
      return _text('已有计划在确认中——等待该计划确认或取消后再提议'
          '（同批多个提议以首个为准）');
    }
    if (state.isActive) {
      return _text('当前已确认计划执行中（计划一经确认即冻结，模型不可自改）；'
          '如需调整，待本计划收口后重新提议');
    }
    final proposal = PlanProposal.fromArgumentsJson(call.argumentsJson);
    if (proposal == null) {
      return ToolExecutionResult(
        isError: true,
        content: 'propose_task_plan 入参畸形：需 {"goal": string, '
            '"steps": [{"id","server","tool","intent"}]}，tool 为裸工具名'
            '（先经只读工具确认目标服务真实工具名）',
      );
    }
    final check = validatePlanProposal(
      proposal: proposal,
      face: buildPlanFaceContext(
        router: router,
        availabilityIssue: availabilityIssue,
      ),
      isWriteTool: isWriteTool,
    );
    switch (check) {
      case PlanCheckRejected(:final reason):
        return ToolExecutionResult(isError: true, content: '计划被拒绝：$reason');
      case PlanCheckUnnecessary(:final reason):
        return _text('无需计划：$reason');
      case PlanCheckOk(:final writeSteps, :final readRows):
        return _confirm(proposal.goal, [...writeSteps, ...readRows]);
    }
  }

  Future<ToolExecutionResult> _confirm(
      String goal, List<PlanStepRow> rows) async {
    final planDelegate = delegate;
    if (planDelegate == null) {
      // §4.3 headless 无 UI 恒拒绝——严禁悬挂或静默放行。
      return ToolExecutionResult(
        isError: true,
        content: '宿主无计划确认界面（无人值守）：计划提议已拒绝，'
            '未产生任何授权语义',
      );
    }
    state.markProposalPending(); // 同步登记——同批伴随写据此 deferred
    PlanProposalDecision decision;
    try {
      decision = await planDelegate
          .confirmPlan(PlanProposalCard(goal: goal, rows: rows));
    } on Object catch (e) {
      // DEGRADE: 确认界面异常按取消处理（保守缺省），留痕不抛穿执行环。
      debugPrint('[DEGRADE] plan-proposal: 确认卡委托失败按取消: $e');
      state.clearProposalPending();
      state.abandon();
      return ToolExecutionResult(
        isError: true,
        content: '计划确认界面异常，计划未生效：$e',
      );
    }
    state.clearProposalPending();
    if (!decision.approved) {
      state.abandon(); // 未确认/被取消的计划不产生任何围栏与授权语义
      return ToolExecutionResult(
        isError: false,
        content: jsonEncode({
          'status': 'user_rejected',
          'message': '计划已取消：计划与同批并入的写作废；'
              '如任务仍需执行，可按常规单步确认逐条调用或直接收尾',
        }),
      );
    }
    final noteByStep = {
      for (final a in decision.approvals) a.stepId: a.note,
    };
    final frozen = <FrozenPlanStep>[];
    final skipped = <String>[];
    final failed = <Map<String, String>>[];
    for (final row in rows) {
      if (!row.isWrite) continue;
      if (!noteByStep.containsKey(row.step.id)) {
        skipped.add(row.step.id); // 用户在卡上剔除
        continue;
      }
      // R6 二次校验（TOCTOU）：确认手势那一刻对冻结集再做存活快照校验——
      // 起草后掉线的步骤当场置 failed、不入 grant。
      final issue = availabilityIssue?.call(row.step.server);
      if (issue != null) {
        failed.add({'id': row.step.id, 'reason': issue});
        continue;
      }
      frozen.add(FrozenPlanStep(
        id: row.step.id,
        server: row.step.server,
        tool: row.step.tool,
        intent: row.step.intent,
        note: noteByStep[row.step.id],
      ));
    }
    state.adoptProposal(goal: goal, steps: frozen);
    return ToolExecutionResult(
      isError: false,
      content: jsonEncode({
        'status': 'approved',
        'plan': [
          for (final f in frozen)
            {
              'id': f.id,
              'server': f.server,
              'tool': f.tool,
              if (f.note != null && f.note!.isNotEmpty) 'user_note': f.note,
            },
        ],
        'skipped': skipped,
        'failed': failed,
        'message': '计划已确认并冻结（写面围栏生效）。逐步执行剩余写步骤，'
            '调用时带 _plan_step_id 标注归属步骤；单步叮嘱已并入 user_note；'
            'failed 步骤为确认时服务失效（不入授权集，勿重试，收尾时说明）。',
      }),
    );
  }

  static ToolExecutionResult _text(String message) =>
      ToolExecutionResult(isError: false, content: message);
}

/// 可见面上下文组装（提议时刻的 router 投影快照）。
PlanFaceContext buildPlanFaceContext({
  required ToolRouter router,
  String? Function(String serverId)? availabilityIssue,
}) {
  return PlanFaceContext(
    mountedServerIds: router.serverIds.toSet(),
    privateServerIds: router.privateServerIds,
    activePrivateSlotId: router.effectiveSlot,
    toolOf: (serverId, toolName) {
      final prefixed = ToolRouter.prefixed(serverId, toolName);
      for (final s in router.schemasFor(serverId)) {
        if (s.name == prefixed) return s;
      }
      return null;
    },
    availabilityIssue: availabilityIssue,
  );
}
