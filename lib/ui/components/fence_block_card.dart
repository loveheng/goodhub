/// N7 PII 围栏拦截卡（M2-T5c，拍板 D4 有人值守面：双选项显式确认）。
///
/// 遮蔽操作失败时出卡：用户可选「取消发送」（围栏拦截生效）或
/// 「我已知悉，明文发送一次」（仅本次放行，**不记忆不豁免**——下次失败
/// 再确认，D4）。Amber 竖条（待决交互）+ 终态锁定灰阶审计感，与 L2
/// 确认卡/排查卡同语汇（ui-design §3.2）。弹出手感 = 双击警示震动。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/console_tokens.dart';

class FenceBlockCard extends StatefulWidget {
  const FenceBlockCard({
    required this.engineName,
    required this.failureMessage,
    this.onDecision,
    this.lockedSendRaw,
    this.lockedAt,
    super.key,
  }) : assert(
         (onDecision == null) == (lockedSendRaw != null),
         '交互态给 onDecision，终态给 lockedSendRaw/lockedAt',
       );

  /// 出事引擎名（围栏装饰的内层引擎，如 openai/gpt-4o）。
  final String engineName;

  /// 围栏失败原因（PiiMaskException.message）。
  final String failureMessage;

  /// 交互态回调（终态时为 null）。true = 明文发送一次；false = 取消。
  final void Function(bool sendRaw)? onDecision;

  /// 终态锁定：已作出的裁决（灰阶展示，无按钮）。
  final bool? lockedSendRaw;
  final DateTime? lockedAt;

  @override
  State<FenceBlockCard> createState() => _FenceBlockCardState();
}

class _FenceBlockCardState extends State<FenceBlockCard> {
  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    if (widget.onDecision != null) {
      // §4.1：拦截卡弹出 → 双击警示震动（同步连发，不挂 Timer）
      HapticFeedback.heavyImpact();
      HapticFeedback.heavyImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final locked = widget.lockedSendRaw;
    if (locked != null) {
      final at = widget.lockedAt ?? DateTime.now();
      final text = locked
          ? '⚠ 已于 ${_hhmm(at)} 明文发送一次（不记忆，下次失败再确认）'
          : '⊘ 已于 ${_hhmm(at)} 取消发送';
      return _frame(
        context,
        barColor: t.terminalMuted,
        child: Text(
          text,
          style: TextStyle(color: t.terminalMuted, fontSize: Fsz.body),
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
              const Text(
                'PII 围栏拦截',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.engineName,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                    color: t.l2Warn,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: t.hairline,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '遮蔽失败：${widget.failureMessage}',
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.telemetrySm,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '本次发送无法完成 PII 遮蔽。取消即中止本次云端请求；'
            '明文发送将把未遮蔽内容（可能含手机号/邮箱/证件号）送出设备，'
            '仅生效一次、不记忆不豁免。',
            style: TextStyle(
              fontSize: Fsz.note,
              color: t.terminalMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => widget.onDecision?.call(false),
                child: const Text('取消发送'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: t.danger),
                onPressed: () => widget.onDecision?.call(true),
                child: const Text('我已知悉，明文发送一次'),
              ),
            ],
          ),
        ],
      ),
    );
  }

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
