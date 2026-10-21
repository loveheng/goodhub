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
import 'status_strip.dart';

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

class CallCard extends StatefulWidget {
  const CallCard({
    super.key,
    required this.tool,
    required this.phase,
    this.progressNote,
    this.preview = '',
    this.fullResult,
    this.description,
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

  /// A2（page-beautify）：服务端工具描述（人话化展示；null/空 = 不渲染描述行）。
  /// 收起态显示首子句短标签，长描述可展开全文（SelectableText 便于复制）。
  final String? description;

  @override
  State<CallCard> createState() => _CallCardState();
}

class _CallCardState extends State<CallCard> {
  /// 终态压缩单行（2026-10-18，用户拍板）：success/failed/cancelled 默认收成
  /// 「✓/✕/⊘ + 人话动作」一行——对话流默认只留「做了什么」，请求/返回细节
  /// （工具名遥测/描述/结果 JSON）点击才展开；running/stuck 保持完整呈现。
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final isTerminal =
        widget.phase == CallCardPhase.success ||
        widget.phase == CallCardPhase.failed ||
        widget.phase == CallCardPhase.cancelled;
    final Color stripe = switch (widget.phase) {
      CallCardPhase.running || CallCardPhase.success => t.l1Ok,
      CallCardPhase.stuck => t.l2Warn,
      CallCardPhase.failed || CallCardPhase.cancelled => t.danger,
    };
    final String statusLine = switch (widget.phase) {
      CallCardPhase.running => widget.progressNote ?? '执行中…',
      CallCardPhase.stuck =>
        '${widget.progressNote ?? '执行中…'} ｜ ⚠ 响应停滞，可用顶部 [ABORT] 中止',
      CallCardPhase.cancelled =>
        widget.progressNote ??
            (widget.preview.isEmpty ? '(无文本返回)' : widget.preview),
      _ => widget.preview.isEmpty ? '(无文本返回)' : widget.preview,
    };
    // 终态单行人话摘要：描述首子句优先，无描述回退裸工具名（**剥 `<serverId>__`
    // 前缀**——P0-4，2026-10-22：直接吃 `widget.tool` 会把路由遥测串直出阅读轨，
    // 与 StatusStrip 的状态带口径不一致）。
    final description = widget.description?.trim() ?? '';
    final summary = description.isNotEmpty
        ? StatusStrip.shortClause(description)
        : StatusStrip.plainToolName(widget.tool);
    final symbol = switch (widget.phase) {
      CallCardPhase.success => '✓',
      CallCardPhase.failed => '✕',
      _ => '⊘',
    };
    // P0-5 第二通道（ui-design §6）：终态三态一度全灰，只有 3dp 竖条与单个
    // ✓/✕/⊘ 可辨——失败/中止被扫读当「已完成」。非成功终态的摘要取出itting
    // 灰阶改取相位语义色（符号仍为字形通道：色弱/强光下两条都可读）。
    final summaryColor = switch (widget.phase) {
      CallCardPhase.failed || CallCardPhase.cancelled => stripe,
      _ => t.terminalMuted,
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
              child: (isTerminal && !_expanded)
                  ? InkWell(
                      onTap: () => setState(() => _expanded = true),
                      child: Padding(
                        // 热区补足（§4.4）：单行文本 + 上下 padding ≈ 44dp。
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Text(
                              symbol,
                              style: TextStyle(
                                fontSize: Fsz.telemetry,
                                color: summaryColor, // 与摘要同相位色（§6 双通道）
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                summary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: Fsz.telemetry,
                                  // 成功=终态灰阶审计感；失败/中止=相位色（§6 双通道）
                                  color: summaryColor,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.expand_more,
                              size: 14,
                              color: t.terminalMuted,
                            ),
                          ],
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 整卡单一开关（2026-10-18 用户拍板）：头部行任意点按
                        // = 全展开/全收起，箭头随态翻转（expand_more↔less）；
                        // running 态头部不可点（无收起语义）。
                        InkWell(
                          onTap: isTerminal
                              ? () => setState(() => _expanded = !_expanded)
                              : null,
                          child: Padding(
                            // 热区补足（§4.4）：头部行 + 上下 padding ≈ 44dp。
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.tool,
                                    style: TextStyle(
                                      fontFamily: t.monoFamily,
                                      fontSize: Fsz.telemetry,
                                      color: isTerminal &&
                                              widget.phase !=
                                                  CallCardPhase.failed
                                          ? t.l1Ok
                                          : stripe,
                                    ),
                                  ),
                                ),
                                if (isTerminal)
                                  Icon(
                                    _expanded
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    size: 14,
                                    color: t.terminalMuted,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // A2：人话描述行——工具名（等宽遥测轨）下方的灰阶动作
                        // 说明；整卡展开态即全文直出（SelectableText 便于复制），
                        // 不再独立折叠。
                        if (description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: SelectableText(
                              description,
                              style: TextStyle(
                                fontSize: Fsz.note,
                                color: t.terminalMuted,
                              ),
                            ),
                          ),
                        const SizedBox(height: 2),
                        // 终态结果区：展开态全文直出（无 fullResult 时仅预览）。
                        if (isTerminal)
                          SelectableText(
                            (widget.fullResult?.trim().isNotEmpty ?? false)
                                ? widget.fullResult!
                                : statusLine,
                            style: TextStyle(
                              fontSize: Fsz.telemetry,
                              fontFamily: t.monoFamily,
                              color: t.terminalMuted, // 终态锁定灰阶审计感
                            ),
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


