/// 任务计划批量确认卡（多插件任务编排 B1）——「多步开关列表卡」决策卡富形态
/// （ui-design §3.2 规范先行条目）：一次手势授权多个可独立开关的写步骤。
///
/// - 步骤行 = 键值两列 + 行尾微型物理开关（禁大圆角胶囊，总纲③）；默认全开、
///   单项可关（剔除即不授权，ToolResult user_skipped 回填）；
/// - 每步可展开单行叮嘱输入（阅读轨人话，随确认并入 user_note）；
/// - 只读信息行静态灰阶、无开关；毁坏性步骤不配开关，改危险色徽标 +
///   「执行时逐条确认」灰字（D1）；
/// - 未就绪步骤整行置灰 + 人话原因（起草期预检 R6）；确认后整卡转灰阶审计行
///   （终态呈现通则，开关与输入禁残留）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:goodhub/coordinator/plan_proposal_tool.dart';
import 'package:goodhub/coordinator/task_plan.dart';

import 'tokens/console_tokens.dart';

class TaskPlanCard extends StatefulWidget {
  const TaskPlanCard({
    required this.plan,
    this.onDecision,
    this.lockedSummary,
    this.lockedAt,
    super.key,
  }) : assert(
         (onDecision == null) == (lockedSummary != null),
         '交互态给 onDecision，终态给 lockedSummary',
       );

  final PlanProposalCard plan;

  /// 交互态回调（终态时为 null）。
  final void Function(PlanProposalDecision decision)? onDecision;

  /// 终态审计行（「✓ 已批准 … · 剔除 … · HH:mm」）。
  final String? lockedSummary;
  final DateTime? lockedAt;

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 终态审计行（页面裁决后锁定呈现用；✓ 已批准 N 项 · 剔除 M 项 · HH:mm）。
  /// 剔除 = 用户关掉的步；毁坏步不计入剔除（独立标注「逐条确认」）。
  static String lockedSummaryFor(
    PlanProposalDecision d, {
    required int writeCount,
    int destructiveCount = 0,
  }) {
    if (!d.approved) return '✕ 已取消（计划与同批并入的写作废）';
    final removed = writeCount - d.approvals.length - destructiveCount;
    return '✓ 已批准 ${d.approvals.length} 项 · 剔除 $removed 项'
        '${destructiveCount > 0 ? ' · 毁坏 $destructiveCount 项逐条确认' : ''}'
        ' · ${_hhmm(DateTime.now())}';
  }

  @override
  State<TaskPlanCard> createState() => _TaskPlanCardState();
}

class _TaskPlanCardState extends State<TaskPlanCard> {
  late final List<bool> _enabled;
  final _notes = <String, TextEditingController>{};
  final _noteExpanded = <String>{};

  @override
  void initState() {
    super.initState();
    final writes = widget.plan.rows.where((r) => r.isWrite).toList();
    // 预检置灰步默认不可授权（服务未就绪，确认手势时二次校验也会剔除）。
    _enabled = [
      for (final r in writes) r.blockedReason == null,
    ];
    if (widget.onDecision != null) {
      // §4.1：L2 拦截卡族弹出 → 双击警示震动（同步连发）。
      HapticFeedback.heavyImpact();
      HapticFeedback.heavyImpact();
    }
  }

  @override
  void dispose() {
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<PlanStepRow> get _writes =>
      widget.plan.rows.where((r) => r.isWrite).toList();

  List<PlanStepRow> get _reads =>
      widget.plan.rows.where((r) => !r.isWrite).toList();

  void _decide(bool approved) {
    final writes = _writes;
    // D1：毁坏性步骤不入批量授权（卡面即无开关）——执行期逐条实参级 L2。
    final approvals = <PlanStepApproval>[
      for (var i = 0; i < writes.length; i++)
        if (_enabled[i] && !writes[i].destructive)
          PlanStepApproval(
            stepId: writes[i].step.id,
            note: _notes[writes[i].step.id]?.text.trim(),
          ),
    ];
    widget.onDecision?.call(PlanProposalDecision(
      approved: approved,
      approvals: approved ? approvals : const [],
    ));
  }



  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final locked = widget.lockedSummary;
    if (locked != null) {
      return _frame(
        context,
        barColor: t.terminalMuted,
        child: Text(
          locked,
          style: TextStyle(
            color: t.terminalMuted,
            fontSize: Fsz.note,
            fontFamily: t.monoFamily,
          ),
        ),
      );
    }
    return _frame(
      context,
      barColor: t.l2Warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('任务计划确认',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '写步骤 ${_writes.length}/$kMaxPlanWriteSteps',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                    color: t.terminalMuted,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            widget.plan.goal,
            style: const TextStyle(fontSize: Fsz.body, height: 1.4),
          ),
          const SizedBox(height: 8),
          for (final row in _writes) _writeRow(context, row),
          if (_reads.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (final row in _reads) _readRow(context, row),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _decide(false),
                child: Text('取消', style: TextStyle(color: t.danger)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: t.l2Warn),
                onPressed: () => _decide(true),
                child: const Text('确认执行'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 写步骤行：键值两列 + 微型物理开关 + 毁坏徽标 / 预检置灰 + 可展开叮嘱。
  Widget _writeRow(BuildContext context, PlanStepRow row) {
    final t = consoleTokens(context);
    final index = _writes.indexOf(row);
    final blocked = row.blockedReason;
    final destructive = row.destructive;
    final on = _enabled[index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (destructive) ...[
              _badge(context, '毁坏', t.danger),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row.step.server}__${row.step.tool}',
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.telemetry,
                      color: blocked != null ? t.terminalMuted : t.l2Warn,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    blocked != null
                        ? '${row.step.intent}（$blocked）'
                        : row.step.intent,
                    style: TextStyle(
                      fontSize: Fsz.note,
                      color: blocked != null ? t.terminalMuted : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (destructive)
              Text(
                '执行时逐条确认',
                style: TextStyle(fontSize: Fsz.micro, color: t.terminalMuted),
              )
            else
              Switch(
                value: on,
                onChanged: blocked == null
                    ? (v) => setState(() => _enabled[index] = v)
                    : null, // 预检置灰步不可开
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
        if (!destructive && on && blocked == null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _noteExpanded.contains(row.step.id)
                    ? _noteExpanded.remove(row.step.id)
                    : _noteExpanded.add(row.step.id);
              }),
              icon: const Icon(Icons.edit_note, size: 16),
              label: Text(
                _noteExpanded.contains(row.step.id) ? '收起叮嘱' : '＋叮嘱',
                style: const TextStyle(fontSize: Fsz.micro),
              ),
            ),
          ),
        if (!destructive && on && blocked == null &&
            _noteExpanded.contains(row.step.id))
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: TextField(
              controller: _notes.putIfAbsent(
                  row.step.id, () => TextEditingController()),
              decoration: const InputDecoration(
                labelText: '单步叮嘱（可空，如「按穷游标准、上限 3000」）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontSize: Fsz.note),
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  /// 读信息行：静态灰阶、无开关（规范条目口径）。
  Widget _readRow(BuildContext context, PlanStepRow row) {
    final t = consoleTokens(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        '[只读] ${row.step.server}__${row.step.tool} —— ${row.step.intent}',
        style: TextStyle(
          fontSize: Fsz.micro,
          color: t.terminalMuted,
          fontFamily: t.monoFamily,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _badge(BuildContext context, String label, Color color) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: Fsz.micro,
            color: color,
            fontFamily: consoleTokens(context).monoFamily,
          ),
        ),
      );

  Widget _frame(
    BuildContext context, {
    required Color barColor,
    required Widget child,
  }) {
    final t = consoleTokens(context);
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
              Container(width: 4, color: barColor),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
