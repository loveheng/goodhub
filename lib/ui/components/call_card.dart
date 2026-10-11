/// 操作轨执行卡（M3-T2 状态机全量；ui-design §3.2 操作卡片状态机 SSOT 的
/// 组件实现，与 ConfirmationCard/BreakerCard 同族）。
///
/// 抽象口径（2026-10-11 评审）：状态机语义在组件内实现一次——Emerald=执行中/
/// 成功、Amber=疑似卡死（D4）、Rose=熔断/中止、灰阶=终态锁定审计感；渲染为
/// 单实现（现消费者仅 debug 页操作轨），双轨消息流将来若需紧凑形态优先加
/// `dense` 参数，不做接口+多实现的投机框架。组件无内部状态：页面持可变编排
/// 记录，每帧以当前快照重建——终态锁定由页面保证（终态后不再 mutate）。
library;

import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';

/// 卡片生命周期相位（ui-design §3.2 左侧状态竖条语义色的映射源）。
enum CallCardPhase {
  /// 执行中（Started 即插卡；Emerald）。
  running,

  /// 疑似卡死（D4：无更新超阈值，只提示不自动中止；Amber）。
  stuck,

  /// 成功终态（Emerald 竖条 + 正文灰阶弱化）。
  success,

  /// 失败终态（Rose）。
  failed,

  /// 用户中止终态（Rose + 灰阶正文；与 failed 区分，architecture §10）。
  cancelled,
}

class CallCard extends StatelessWidget {
  const CallCard({
    super.key,
    required this.tool,
    required this.phase,
    this.progressNote,
    this.preview = '',
  });

  final String tool;

  /// 当前相位。
  final CallCardPhase phase;

  /// Running(progress) 呈现（微型百分比 / server 帧消息）；仅 running/stuck 相位有意义。
  final String? progressNote;

  /// 终态结果预览（首两行）。
  final String preview;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final isTerminal =
        phase == CallCardPhase.success || phase == CallCardPhase.failed || phase == CallCardPhase.cancelled;
    final Color stripe = switch (phase) {
      CallCardPhase.running || CallCardPhase.success => t.l1Ok,
      CallCardPhase.stuck => t.l2Warn,
      CallCardPhase.failed || CallCardPhase.cancelled => t.danger,
    };
    final String statusLine = switch (phase) {
      CallCardPhase.running => progressNote ?? '执行中…',
      CallCardPhase.stuck =>
        '${progressNote ?? '执行中…'} ｜ ⚠ 疑似卡死：无更新超阈值（可中止）',
      _ => preview.isEmpty ? '(无文本返回)' : preview,
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ui-design §3.2：左侧状态竖条语义色
            Container(width: 3, color: stripe),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool,
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: 12,
                      color: isTerminal && phase != CallCardPhase.failed
                          ? t.l1Ok
                          : stripe,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    statusLine,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: isTerminal ? t.monoFamily : null,
                      color: isTerminal
                          ? t.terminalMuted // 终态锁定灰阶审计感
                          : Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
