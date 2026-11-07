/// 交互卡族渲染（extensibility-hardening S4-4b 自 track_entry_render 拆出）：
/// 计划确认/计划台账/L2 确认/熔断排查/围栏拦截/elicitation 六类卡片的渲染
/// 子组件（行为等价机械搬移；跨文件引用故去私有化，类名 Track*Entry 族）。
library;

import 'package:flutter/material.dart';

import 'dart:async';

import '../../coordinator/plan_proposal_tool.dart';
import '../../coordinator/tool_breaker.dart';
import '../../coordinator/chat_track_model.dart';
import '../../coordinator/fenced_cloud_engine.dart';
import '../../coordinator/permission_gateway.dart';
import '../../coordinator/task_plan.dart';
import '../../mcp/elicitation.dart';
import '../task_plan_card.dart';
import '../task_result_card.dart';
import '../tokens/console_tokens.dart';
import 'breaker_card.dart';
import 'confirmation_card.dart';
import 'elicitation_card.dart';
import 'fence_block_card.dart';

class TrackPlanConfirmEntry extends StatelessWidget {
  const TrackPlanConfirmEntry({
    super.key,
    required this.entry,
    required this.card,
    required this.decision,
    required this.decidedAt,
    required this.lockedSummary,
    required this.completer,
  });
  final TrackPlanConfirm entry;
  final PlanProposalCard card;
  final PlanProposalDecision? decision;
  final DateTime? decidedAt;
  final String? lockedSummary;
  final Completer<PlanProposalDecision> completer;
  @override
  Widget build(BuildContext context) {
    return TaskPlanCard(
      plan: card,
      onDecision: decision == null
          ? (d) {
              entry.decision = d;
              entry.decidedAt = DateTime.now();
              entry.lockedSummary = TaskPlanCard.lockedSummaryFor(
                d,
                writeCount: card.rows.where((r) => r.isWrite).length,
                destructiveCount:
                    card.rows.where((r) => r.isWrite && r.destructive).length,
              );
              completer.complete(d);
            }
          : null,
      lockedSummary: decidedAt == null ? null : lockedSummary,
      lockedAt: decidedAt,
    );
  }
}

class TrackPlanResultEntry extends StatelessWidget {
  const TrackPlanResultEntry({super.key, required this.record, required this.onResume});
  final PlanAggregateRecord record;
  final VoidCallback? onResume;
  @override
  Widget build(BuildContext context) => TaskResultCard(record: record, onResume: onResume);
}

class TrackConfirmEntry extends StatelessWidget {
  const TrackConfirmEntry({
    super.key,
    required this.entry,
    required this.pending,
    required this.decision,
    required this.decidedAt,
    required this.completer,
  });
  final TrackConfirm entry;
  final ToolPendingConfirmation pending;
  final GateDecision? decision;
  final DateTime? decidedAt;
  final Completer<GateDecision> completer;
  @override
  Widget build(BuildContext context) {
    return ConfirmationCard(
      toolName: pending.toolName,
      argumentsJson: pending.argumentsJson,
      onDecision: decision == null
          ? (d) {
              entry.decision = d;
              entry.decidedAt = DateTime.now();
              completer.complete(d);
            }
          : null,
      lockedDecision: decision,
      lockedAt: decidedAt,
    );
  }
}

class TrackBreakerEntry extends StatelessWidget {
  const TrackBreakerEntry({
    super.key,
    required this.entry,
    required this.report,
    required this.wall,
    required this.lockedText,
    required this.decidedAt,
    required this.completer,
  });
  final TrackBreaker entry;
  final BreakerReport? report;
  final StepWallReport? wall;
  final String? lockedText;
  final DateTime? decidedAt;
  final Completer<Object?> completer;
  @override
  Widget build(BuildContext context) {
    return BreakerCard(
      report: report,
      wall: wall,
      lockedText: lockedText,
      lockedAt: decidedAt,
      onBreaker: report == null
          ? null
          : (r) {
              entry.lockedText = switch (r) {
                RetryOnce() => '⟳ 已单步重试',
                SkipOnce() => '⤼ 已跳过（错误回填）',
                ManualResult() => '👤 已人工接管',
              };
              entry.decidedAt = DateTime.now();
              completer.complete(r);
            },
      onStepWall: wall == null
          ? null
          : (relax) {
              entry.lockedText = relax ? '⤒ 已放宽 +10 续跑' : '⊘ 已终止';
              entry.decidedAt = DateTime.now();
              completer.complete(relax);
            },
    );
  }
}

class TrackFenceEntry extends StatelessWidget {
  const TrackFenceEntry({
    super.key,
    required this.entry,
    required this.info,
    required this.decision,
    required this.decidedAt,
    required this.completer,
  });
  final TrackFence entry;
  final PiiMaskBlockInfo info;
  final bool? decision;
  final DateTime? decidedAt;
  final Completer<bool> completer;
  @override
  Widget build(BuildContext context) {
    return FenceBlockCard(
      engineName: info.engineName,
      failureMessage: info.failureMessage,
      onDecision: decision == null
          ? (sendRaw) {
              entry.decision = sendRaw;
              entry.decidedAt = DateTime.now();
              completer.complete(sendRaw);
            }
          : null,
      lockedSendRaw: decision,
      lockedAt: decidedAt,
    );
  }
}

class TrackElicitationEntry extends StatelessWidget {
  const TrackElicitationEntry({
    super.key,
    required this.entry,
    required this.request,
    required this.answer,
    required this.decidedAt,
    required this.completer,
  });
  final TrackElicitation entry;
  final ElicitationRequest request;
  final ElicitationAnswer? answer;
  final DateTime? decidedAt;
  final Completer<ElicitationAnswer> completer;
  @override
  Widget build(BuildContext context) {
    return ElicitationCard(
      request: request,
      onDecision: answer == null
          ? (a) {
              entry.answer = a;
              entry.decidedAt = DateTime.now();
              completer.complete(a);
            }
          : null,
      lockedAnswer: answer,
      lockedAt: decidedAt,
    );
  }
}


/// 错误卡原始异常详情（盘点 2026-11-06 #5）：默认限 3 行——长堆栈此前全文
/// 展开，把标题+建议（用户真正该读的）顶出视口；等宽留痕口径不变（可
/// 选择复制），点「查看详情」展开/收起。
class ErrorDetail extends StatefulWidget {
  const ErrorDetail({super.key, required this.t, required this.detail});

  final ConsoleTokens t;
  final String detail;

  @override
  State<ErrorDetail> createState() => ErrorDetailState();
}

class ErrorDetailState extends State<ErrorDetail> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectableText(
          widget.detail,
          maxLines: _expanded ? null : 3,
          style: TextStyle(
            fontFamily: t.monoFamily,
            fontSize: Fsz.telemetrySm,
            color: t.terminalMuted,
          ),
        ),
        if (!_expanded)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = true),
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '▼ 查看详情',
                style: TextStyle(fontSize: Fsz.telemetry, color: t.l1Info),
              ),
            ),
          ),
      ],
    );
  }
}

