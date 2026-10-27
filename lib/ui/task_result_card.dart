/// 计划执行聚合卡（多插件任务编排 B1）——Run 收口后的步骤台账呈现：
/// 整体状态语义色（Emerald 完成 / 琥珀部分 / 玫瑰失败，只由写步骤判定）+
/// 逐步骤状态与首笔实参摘要 + 计划外补调与配额用量 + 续跑按钮（部分完成 /
/// 失败且回调在位时；completed 无剩余可补，历史恢复态锁定）。规格 SSOT：
/// docs/design/task-orchestration.md「聚合卡」节；视觉规范 = ui-design §3.2。
library;

import 'package:flutter/material.dart';
import 'package:goodhub/coordinator/task_plan.dart';

import 'tokens/console_tokens.dart';

class TaskResultCard extends StatelessWidget {
  const TaskResultCard({
    required this.record,
    this.onResume,
    super.key,
  });

  final PlanAggregateRecord record;

  /// 续跑手势（聚合卡按钮；null = 锁定态：历史恢复 / 无续跑语义）。
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final (color, statusText) = switch (record.status) {
      PlanAggregateStatus.completed => (t.l1Ok, '完成'),
      PlanAggregateStatus.partial => (t.l2Warn, '部分完成'),
      PlanAggregateStatus.failed => (t.danger, '失败'),
    };
    final outOfBandTotal =
        record.outOfBand.values.fold<int>(0, (a, b) => a + b);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
        color: Theme.of(context).cardColor,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.cardRadius),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: color),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('计划执行结果',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            Text(
                              statusText,
                              style: TextStyle(
                                  fontSize: Fsz.note, color: color),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          record.goal,
                          style: const TextStyle(
                              fontSize: Fsz.body, height: 1.4),
                        ),
                        const SizedBox(height: 8),
                        for (final row in record.rows)
                          _stepRow(context, row),
                        if (outOfBandTotal > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '⚠ 计划外补调 $outOfBandTotal 次（已拒绝，'
                              '见围栏审计）',
                              style: TextStyle(
                                  fontSize: Fsz.micro,
                                  color: t.terminalMuted),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '配额上限 ${_quotaHint()} 次/对（派发即计、'
                            '跨续跑累计）',
                            style: TextStyle(
                                fontSize: Fsz.micro,
                                color: t.terminalMuted),
                          ),
                        ),
                        if (onResume != null &&
                            record.status != PlanAggregateStatus.completed)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: onResume,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('续跑（补剩余步骤）'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 步骤行：`[s1] server__tool —— intent`（遥测 mono）+ 状态（ok×k / failed /
  /// skipped）+ 首笔实参摘要灰行（超长折叠）。
  Widget _stepRow(BuildContext context, PlanLedgerStepView row) {
    final t = consoleTokens(context);
    final echo = record.echoByStep[row.step.id];
    final statusColor = row.skipped
        ? t.terminalMuted
        : row.ok > 0
            ? t.l1Ok
            : row.calls > 0
                ? t.danger
                : t.terminalMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '[${row.step.id}]',
                style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                    color: t.terminalMuted),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${row.step.server}__${row.step.tool} —— ${row.step.intent}',
                  style: TextStyle(
                      fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                row.statusText,
                style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                    color: statusColor),
              ),
            ],
          ),
          if (echo != null)
            Text(
              echo,
              style: TextStyle(
                  fontSize: Fsz.micro, color: t.terminalMuted, height: 1.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  String _quotaHint() => '$kPlanPairQuotaDefault';
}
