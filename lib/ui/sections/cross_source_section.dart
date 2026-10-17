/// 设置页 · 跨源授权语义段（window-slim P1-A 分段拆解，2026-10-17 自
/// settings_page 迁出）：D5 恒 L2 弹卡不豁免的口径展示。
///
/// 迁移语义原样保留：策略行三条口径（恒 L2 弹卡 / 看不清不放行 / 不记忆不豁免）
/// 文案与 l2Warn 图标同色。「去联调页实测」入口已摘除（2026-10-17 用户拍板），
/// 联调页仍可由代码侧直达（ui/gateway_loop_debug_page.dart 保留）。
library;

import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';

/// 段 widget：纯展示段（无领域态、无注入位）。
class CrossSourceSection extends StatelessWidget {
  const CrossSourceSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '跨源授权（\$ref 联合授权）',
              style: const TextStyle(
                fontSize: Fsz.sectionTitle,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'A 应用的工具输出经 \$ref 句柄传给 B 应用工具时，宿主弹卡确认后'
              '才注水放行——句柄是模型侧行话，真实数据永不出网关。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            _policyRow(
              context,
              Icons.gavel_outlined,
              '恒 L2 弹卡确认',
              '每次跨源都需确认——会话豁免不适用（豁免按工具粒度防不住数据面风险）',
            ),
            _policyRow(
              context,
              Icons.visibility_off_outlined,
              // P1-7：策略行标题去黑话（禁盲签 → 看得懂的动作口径）。
              '看不清不放行',
              '数据摘要不可读即拒；摘要封顶 300 字符（标题+前 5 行）',
            ),
            _policyRow(
              context,
              Icons.lock_outline,
              '不记忆不豁免',
              '与隐私围栏同口径：显式确认不落盘、不旁路 N7 出站围栏',
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 策略行：l2Warn 图标 + 「口径：说明」两段式（P1-7 去黑话后的朗读口径）。
Widget _policyRow(
  BuildContext context,
  IconData icon,
  String title,
  String desc,
) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 15, color: consoleTokens(context).l2Warn),
      const SizedBox(width: 8),
      Expanded(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$title：',
                style: const TextStyle(fontSize: Fsz.telemetry),
              ),
              TextSpan(
                text: desc,
                style: TextStyle(
                  fontSize: Fsz.telemetry,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  ),
);
