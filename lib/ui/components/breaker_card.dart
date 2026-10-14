/// 熔断/步数墙排查卡（ui-design §3.2：Rose 竖条 + 结构化错误摘要等宽 +
/// 三操作（单步重试/跳过/人工接管）；步数墙变体 = 放宽 +10 续跑 / 终止）。
///
/// 弹出触觉 = 重度确认震动（§4.1）；决议后锁定为灰阶弱化态。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';

import '../tokens/console_tokens.dart';

class BreakerCard extends StatefulWidget {
  const BreakerCard({
    this.report,
    this.wall,
    this.onBreaker,
    this.onStepWall,
    this.lockedText,
    this.lockedAt,
    super.key,
  }) : assert((report == null) != (wall == null), '熔断卡给 report，步数墙卡给 wall');

  /// 熔断模式数据（C1 排查卡）。
  final BreakerReport? report;

  /// 步数墙模式数据（§12）。
  final StepWallReport? wall;

  final void Function(BreakerResolution resolution)? onBreaker;
  final void Function(bool relax)? onStepWall;

  /// 终态锁定文案（由页面按决议生成；null = 交互态）。
  final String? lockedText;
  final DateTime? lockedAt;

  @override
  State<BreakerCard> createState() => _BreakerCardState();
}

class _BreakerCardState extends State<BreakerCard> {
  final _takeoverCtrl = TextEditingController();
  var _takingOver = false;

  @override
  void initState() {
    super.initState();
    if (widget.lockedText == null) {
      // §4.1：Abort/熔断 → 重度确认震动
      unawaited(HapticFeedback.heavyImpact());
    }
  }

  @override
  void dispose() {
    _takeoverCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final locked = widget.lockedText;
    if (locked != null) {
      final at = widget.lockedAt ?? DateTime.now();
      return _frame(
        context,
        barColor: t.terminalMuted,
        child: Text(
          '$locked（${_hhmm(at)}）',
          style: TextStyle(color: t.terminalMuted, fontSize: Fsz.body),
        ),
      );
    }
    final isWall = widget.wall != null;
    return _frame(
      context,
      barColor: t.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isWall ? '步数墙' : '两步熔断',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isWall
                      ? '连续 ${widget.wall!.turnsUsed} 轮工具调用未收尾（上限 ${widget.wall!.limit}）'
                      : '${widget.report!.toolName} 连续 ${widget.report!.consecutiveFailures} 次报错',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (!isWall) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: t.hairline,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                widget.report!.lastError,
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.telemetrySm,
                ),
                maxLines: 6,
              ),
            ),
          ],
          if (isWall) ...[
            const SizedBox(height: 8),
            // 语义色纪律：终止 = 危险动作（Rose 主按钮）；放宽续跑 = 常规按钮。
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => widget.onStepWall?.call(true),
                  child: const Text('放宽 +10 续跑'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: t.danger),
                  onPressed: () => widget.onStepWall?.call(false),
                  child: const Text('终止'),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 8),
            if (_takingOver) ...[
              TextField(
                controller: _takeoverCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '人工结果（将以正常数据回填模型）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: Fsz.body),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _takingOver = false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: t.danger),
                    onPressed: () {
                      final text = _takeoverCtrl.text.trim();
                      if (text.isEmpty) return;
                      widget.onBreaker?.call(ManualResult(text));
                    },
                    child: const Text('提交结果'),
                  ),
                ],
              ),
            ] else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _takingOver = true),
                    child: const Text('人工接管'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => widget.onBreaker?.call(const SkipOnce()),
                    child: const Text('跳过'),
                  ),
                  const SizedBox(width: 8),
                  // 重试 = 常规恢复动作（Rose 留给卡框/标题的熔断语义）。
                  FilledButton(
                    onPressed: () => widget.onBreaker?.call(const RetryOnce()),
                    child: const Text('单步重试'),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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
        // IntrinsicHeight：ListView 无界高度下 stretch 竖条须按内容自量
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
