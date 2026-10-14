/// 顶部状态胶囊（药丸）——ui-design §3.1 的最小落地（M1 应用内组件形态）。
///
/// L1 静默执行/就绪用 Emerald/Cyan 弱提示；L2 待确认 Amber；熔断/中止 Rose。
library;

import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';

enum CapsuleTone { idle, l1, l2, danger }

class StatusCapsule extends StatelessWidget {
  const StatusCapsule({
    required this.label,
    this.tone = CapsuleTone.idle,
    super.key,
  });

  /// 等宽阶段名（如 `goodshare::list_items`，§3.1 中列）。
  final String label;
  final CapsuleTone tone;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final color = switch (tone) {
      CapsuleTone.idle => t.terminalMuted,
      CapsuleTone.l1 => t.l1Info,
      CapsuleTone.l2 => t.l2Warn,
      CapsuleTone.danger => t.danger,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
        color: Theme.of(context).cardColor,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // §4.2 紧凑动效：状态点颜色随相位过渡（150~200ms，禁 Spring）。
          AnimatedContainer(
            width: 7,
            height: 7,
            duration: t.fastDuration,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontFamily: t.monoFamily,
              fontSize: Fsz.telemetry,
              color: Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
        ],
      ),
    );
  }
}
