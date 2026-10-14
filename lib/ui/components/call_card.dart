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
    this.fullResult,
  });

  final String tool;

  /// 当前相位。
  final CallCardPhase phase;

  /// Running(progress) 呈现（微型百分比 / server 帧消息）；仅 running/stuck 相位有意义。
  final String? progressNote;

  /// 终态结果预览（首两行）。
  final String preview;

  /// 终态结果全文（非空且长于预览时可展开查看）。
  final String? fullResult;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final isTerminal =
        phase == CallCardPhase.success ||
        phase == CallCardPhase.failed ||
        phase == CallCardPhase.cancelled;
    final Color stripe = switch (phase) {
      CallCardPhase.running || CallCardPhase.success => t.l1Ok,
      CallCardPhase.stuck => t.l2Warn,
      CallCardPhase.failed || CallCardPhase.cancelled => t.danger,
    };
    final String statusLine = switch (phase) {
      CallCardPhase.running => progressNote ?? '执行中…',
      CallCardPhase.stuck => '${progressNote ?? '执行中…'} ｜ ⚠ 响应停滞，可用顶部 [ABORT] 中止',
      CallCardPhase.cancelled =>
        progressNote ?? (preview.isEmpty ? '(无文本返回)' : preview),
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
            // ui-design §3.2 左侧状态竖条语义色；§4.2 颜色随相位紧凑过渡。
            AnimatedContainer(
              width: 3,
              duration: t.fastDuration,
              color: stripe,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool,
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.telemetry,
                      color: isTerminal && phase != CallCardPhase.failed
                          ? t.l1Ok
                          : stripe,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (isTerminal)
                    _ExpandableResult(
                      preview: statusLine,
                      fullResult: fullResult,
                    )
                  else
                    Text(
                      statusLine,
                      style: TextStyle(
                        fontSize: Fsz.telemetry,
                        color: Theme.of(context).hintColor,
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

/// 终态结果区：默认两行截断预览，可展开全文（SelectableText 便于复制排障）。
class _ExpandableResult extends StatefulWidget {
  const _ExpandableResult({required this.preview, this.fullResult});

  final String preview;
  final String? fullResult;

  @override
  State<_ExpandableResult> createState() => _ExpandableResultState();
}

class _ExpandableResultState extends State<_ExpandableResult> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final style = TextStyle(
      fontSize: Fsz.telemetry,
      fontFamily: t.monoFamily,
      color: t.terminalMuted, // 终态锁定灰阶审计感
    );
    final full = widget.fullResult?.trim() ?? '';
    final canExpand =
        full.isNotEmpty && full != widget.preview.trim();
    if (!canExpand) {
      return Text(widget.preview, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          _expanded ? widget.fullResult! : widget.preview,
          style: style,
          maxLines: _expanded ? null : 2,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 28),
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(
              _expanded ? '收起' : '展开全文',
              style: TextStyle(fontSize: Fsz.micro, color: t.terminalMuted),
            ),
          ),
        ),
      ],
    );
  }
}
