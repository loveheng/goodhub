/// 跨源 $ref 联合授权卡（M3-T4 组件化；architecture §9 + D5 拍板 2026-10-11）。
///
/// D5：**恒 L2 弹卡、会话豁免不适用**——豁免按工具粒度（C7）防不住数据面风险
/// （每张卡句柄内容不同），与 N7 围栏「显式确认不记忆不豁免」同精神；本卡
/// 不提供「记住」勾选。Amber 警示语义（ui-design §1：L2 写操作/跨 App 联合
/// 授权）；**禁盲签**（§9）：preview 为空只允许拒绝；preview 300 字符封顶由
/// refPreview 产出方保证，组件不重复截断。终态锁定灰阶审计感（§3.2）。
library;

import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';

class CrossSourceConsentCard extends StatelessWidget {
  const CrossSourceConsentCard({
    super.key,
    required this.handle,
    required this.fromServer,
    required this.toServer,
    required this.preview,
    this.onDecision,
    this.lockedDecision,
    this.lockedAt,
  }) : assert(
         (onDecision == null) == (lockedDecision != null),
         '锁态必须带 lockedDecision，非锁态必须带 onDecision',
       ),
       assert(lockedDecision == null || lockedAt != null, '锁态必须带 lockedAt');

  final String handle;
  final String fromServer;
  final String toServer;

  /// 注水数据摘要（refPreview 产出：标题+前 5 行/300 字符封顶）；空 = 禁盲签。
  final String preview;

  /// 决策回调（true=允许注水）；null = 锁态。
  final ValueChanged<bool>? onDecision;

  final bool? lockedDecision;
  final DateTime? lockedAt;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final locked = onDecision == null;
    final blindSign = preview.trim().isEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.l2Warn),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 3, height: 16, color: t.l2Warn),
              const SizedBox(width: 8),
              Text(
                '跨源引用确认',
                style: TextStyle(
                  fontSize: Fsz.listPrimary,
                  fontWeight: FontWeight.w600,
                  color: t.l2Warn,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _metaRow(t, '句柄', handle),
          _metaRow(t, '来源', '[$fromServer] → 目标 [$toServer]'),
          const SizedBox(height: 8),
          Text(
            '数据摘要：',
            style: TextStyle(
              fontSize: Fsz.telemetry,
              color: Theme.of(context).hintColor,
            ),
          ),
          if (blindSign) ...[
            const SizedBox(height: 4),
            Text(
              '（无预览——禁盲签，不可放行）',
              style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
            ),
          ] else ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(t.cardRadius),
                color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
              ),
              child: Text(
                preview,
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.telemetrySm,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (locked)
            Text(
              lockedDecision! ? '✓ 已允许注水${_atSuffix()}' : '✕ 已拒绝${_atSuffix()}',
              style: TextStyle(
                fontSize: Fsz.telemetry,
                fontFamily: t.monoFamily,
                color: lockedDecision! ? t.terminalMuted : t.danger,
              ),
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => onDecision!(false),
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: blindSign ? null : () => onDecision!(true),
                  child: const Text('允许注水'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _atSuffix() => lockedAt == null ? '' : ' · ${_hhmm(lockedAt!)}';

  Widget _metaRow(ConsoleTokens t, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 38,
          child: Text(
            label,
            style: TextStyle(fontSize: Fsz.telemetry, color: t.terminalMuted),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          ),
        ),
      ],
    ),
  );
}
