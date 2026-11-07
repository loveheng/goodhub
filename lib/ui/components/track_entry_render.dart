/// 轨道条目渲染映射（extensibility-hardening S4-4b 自 dual_track_stream 拆出）：
/// renderEntry 穷举 switch + 各条目渲染子组件（行为等价机械搬移）。列表编排
/// （分组折叠/限宽/空态）仍住 dual_track_stream；模型+codec 住
/// coordinator/chat_track_model.dart。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../coordinator/chat_track_model.dart';
import 'call_card.dart';
import 'streaming_rich_text.dart';
import 'track_entry_gate_cards.dart';
import '../tokens/console_tokens.dart';

/// 条目 → 轨道 widget（S4-4b 拆出：原 [DualTrackStream.renderEntry] 巨型
/// switch 迁此，公开类承载；DualTrackStream 保留同名静态转发零调用方扰动）。
class TrackEntryRender {
  /// 条目 → 轨道 widget（公开静态：T3b 恢复装配复用 + 单测直测映射）。
  static Widget renderEntry(BuildContext context, TrackEntry entry) {
    return switch (entry) {
      TrackText() => _TrackTextEntry(entry),
      TrackThinking e => _TrackThinkingEntry(e),
      TrackUser(:final text) => _TrackUserEntry(text: text),
      TrackCall e => _TrackCallEntry(e),
      TrackPlanConfirm(
        :final card,
        :final decision,
        :final decidedAt,
        :final lockedSummary,
        :final completer,
      ) =>
        TrackPlanConfirmEntry(
          entry: entry,
          card: card,
          decision: decision,
          decidedAt: decidedAt,
          lockedSummary: lockedSummary,
          completer: completer,
        ),
      TrackPlanResult(:final record, :final onResume) =>
        TrackPlanResultEntry(record: record, onResume: onResume),
      TrackConfirm(
        :final pending,
        :final decision,
        :final decidedAt,
        :final completer,
      ) =>
        TrackConfirmEntry(
          entry: entry,
          pending: pending,
          decision: decision,
          decidedAt: decidedAt,
          completer: completer,
        ),
      TrackBreaker(
        :final report,
        :final wall,
        :final lockedText,
        :final decidedAt,
        :final completer,
      ) =>
        TrackBreakerEntry(
          entry: entry,
          report: report,
          wall: wall,
          lockedText: lockedText,
          decidedAt: decidedAt,
          completer: completer,
        ),
      TrackFence(
        :final info,
        :final decision,
        :final decidedAt,
        :final completer,
      ) =>
        TrackFenceEntry(
          entry: entry,
          info: info,
          decision: decision,
          decidedAt: decidedAt,
          completer: completer,
        ),
      TrackElicitation(
        :final request,
        :final answer,
        :final decidedAt,
        :final completer,
      ) =>
        TrackElicitationEntry(
          entry: entry,
          request: request,
          answer: answer,
          decidedAt: decidedAt,
          completer: completer,
        ),
      TrackNote(:final text, :final danger) =>
        _TrackNoteEntry(text: text, danger: danger),
      TrackGuide(:final text, :final actionLabel, :final onAction) =>
        _TrackGuideEntry(
          text: text,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
      TrackError(
        :final title,
        :final advice,
        :final detail,
        :final retried,
        :final onAction,
      ) =>
        _TrackErrorEntry(
          title: title,
          advice: advice,
          detail: detail,
          retried: retried,
          onAction: onAction,
        ),
      TrackMemoryCapsule(:final key, :final value, :final onUndo, :final undone) =>
        _TrackMemoryEntry(
          memKey: key,
          value: value,
          onUndo: onUndo,
          undone: undone,
        ),
      TrackContextAttribution(
        :final memories,
        :final services,
        :final droppedCount,
        :final onItemExclude,
        :final onViewMemories,
      ) =>
        _TrackContextAttributionEntry(
          memories: memories,
          services: services,
          droppedCount: droppedCount,
          onItemExclude: onItemExclude,
          onViewMemories: onViewMemories,
        ),
    };
  }
}


/// 阅读轨文本条目（按卡片类型拆出的子组件；原 [DualTrackStream.renderEntry]
/// 巨型 switch 拆分，行为等价）。
class _TrackTextEntry extends StatelessWidget {
  const _TrackTextEntry(this.entry);
  final TrackText entry;
  @override
  Widget build(BuildContext context) {
    if (entry.text.isEmpty) return const SizedBox.shrink();
    final t = consoleTokens(context);
    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'GoodHub',
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.microSm,
                color: t.terminalMuted,
              ),
            ),
            const SizedBox(height: 2),
            StreamingRichText(text: entry.text.toString()),
          ],
        ),
      ),
    );
  }
}

class _TrackThinkingEntry extends StatelessWidget {
  const _TrackThinkingEntry(this.entry);
  final TrackThinking entry;
  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) => Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(t.cardRadius),
          border: Border.all(color: t.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(t.cardRadius),
              onTap: entry.toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '思考过程',
                      style: TextStyle(
                        fontFamily: t.monoFamily,
                        fontSize: Fsz.note,
                        color: t.terminalMuted,
                      ),
                    ),
                    Text(
                      entry.expanded ? ' ▾' : ' ▸',
                      style: TextStyle(
                        fontFamily: t.monoFamily,
                        fontSize: Fsz.note,
                        color: t.terminalMuted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      kThinkingHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Fsz.microSm,
                        color: t.terminalMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (entry.expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: SelectableText(
                  entry.text.toString(),
                  style: TextStyle(
                    fontSize: Fsz.note,
                    height: 1.5,
                    color: t.terminalMuted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrackUserEntry extends StatelessWidget {
  const _TrackUserEntry({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
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
            Container(width: 3, color: t.dataRef),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '你',
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.microSm,
                      color: t.dataRef,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    text,
                    style: const TextStyle(
                      fontSize: Fsz.reading,
                      height: 1.5,
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

class _TrackCallEntry extends StatelessWidget {
  const _TrackCallEntry(this.entry);
  final TrackCall entry;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) => CallCard(
        tool: entry.tool,
        phase: entry.phase,
        progressNote: entry.progressNote,
        preview: entry.preview,
        fullResult: entry.resultText.isEmpty ? null : entry.resultText,
        description: entry.description,
      ),
    );
  }
}

class _TrackNoteEntry extends StatelessWidget {
  const _TrackNoteEntry({required this.text, required this.danger});
  final String text;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SelectableText(
        text,
        style: TextStyle(
          fontSize: Fsz.note,
          color: danger ? t.danger : t.terminalMuted,
        ),
      ),
    );
  }
}

class _TrackGuideEntry extends StatelessWidget {
  const _TrackGuideEntry({
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });
  final String text;
  final String actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    return _TrackActionCard(
      danger: false,
      actionLabel: actionLabel,
      onAction: onAction,
      child: Text(
        text,
        style: const TextStyle(fontSize: Fsz.note, height: 1.4),
      ),
    );
  }
}

class _TrackErrorEntry extends StatelessWidget {
  const _TrackErrorEntry({
    required this.title,
    required this.advice,
    required this.detail,
    required this.retried,
    required this.onAction,
  });
  final String title;
  final String advice;
  final String detail;
  final bool retried;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return _TrackActionCard(
      danger: true,
      actionLabel: retried ? null : '重试',
      onAction: retried ? null : onAction,
      lockedLabel: retried ? '↻ 已重试' : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '✕ $title',
            style: TextStyle(
              fontSize: Fsz.note,
              fontWeight: FontWeight.w600,
              color: t.danger,
            ),
          ),
          Text(
            advice,
            style: const TextStyle(fontSize: Fsz.note, height: 1.4),
          ),
          if (detail.isNotEmpty) ErrorDetail(t: t, detail: detail),
        ],
      ),
    );
  }
}

class _TrackMemoryEntry extends StatelessWidget {
  const _TrackMemoryEntry({
    required this.memKey,
    required this.value,
    required this.onUndo,
    required this.undone,
  });
  final String memKey;
  final String value;
  final void Function()? onUndo;
  final bool undone;
  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '⚡ 已记录 $key=$value',
            style: TextStyle(
              fontFamily: t.monoFamily,
              fontSize: Fsz.note,
              color: t.terminalMuted,
            ),
          ),
          if (!undone && onUndo != null)
            TextButton(
              onPressed: onUndo,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28),
              ),
              child: Text(
                '✕ 撤销',
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.note,
                  color: t.dataRef,
                ),
              ),
            )
          else if (undone)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '✕ 已撤销',
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.note,
                  color: t.terminalMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrackContextAttributionEntry extends StatelessWidget {
  const _TrackContextAttributionEntry({
    required this.memories,
    required this.services,
    required this.droppedCount,
    required this.onItemExclude,
    required this.onViewMemories,
  });
  final List<ContextAttributionItem> memories;
  final List<ContextAttributionItem> services;
  final int droppedCount;
  final void Function(ContextAttributionItem item)? onItemExclude;
  final VoidCallback? onViewMemories;
  @override
  Widget build(BuildContext context) {
    return _ContextAttributionRow(
      memories: memories,
      services: services,
      droppedCount: droppedCount,
      onItemExclude: onItemExclude,
      onViewMemories: onViewMemories,
    );
  }
}



/// 轨道行动卡（引导卡 / 错误卡共用，ux-hardening P0-1/P0-2）：细边框容器
/// + 危险态 Rose 左竖条（同 TrackUser 数据指针条族，ui-design §3.2 同轴
/// 卡片族纪律）；动作钮等宽遥测轨数据指针色，锁定态灰阶弱化。
class _TrackActionCard extends StatelessWidget {
  const _TrackActionCard({
    required this.danger,
    required this.child,
    this.actionLabel,
    this.onAction,
    this.lockedLabel,
  });

  final bool danger;
  final Widget child;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 锁定态角标（如「↻ 已重试」）——替代动作钮的灰阶呈现。
  final String? lockedLabel;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (danger) Container(width: 3, color: t.danger),
            if (danger) const SizedBox(width: 8),
            Expanded(child: child),
            if (actionLabel != null && onAction != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                child: Text(
                  actionLabel!,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.note,
                    color: t.dataRef,
                  ),
                ),
              )
            else if (lockedLabel != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  lockedLabel!,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.note,
                    color: t.terminalMuted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 本轮上下文归因 pill（展示 only）：收起态一行等宽遥测轨（数据指针色
/// Indigo，ui-design §1），点击弹 BottomSheet 详情——来源标签（等宽微底色
/// 容器）+ 内容（阅读轨小字）+ 预留排除位（onItemExclude 非空才渲染）。
/// **静默即无（P1-6 降噪）**：无记忆注入且无超预算丢弃时不渲染——「服务
/// N 个」与输入条状态带的上下文胶囊重复，每轮必出是遥测噪音，稀释真正的
/// 回答。携带记忆注入或丢弃计数时才出现（这两样用户别处看不到）。
class _ContextAttributionRow extends StatelessWidget {
  const _ContextAttributionRow({
    required this.memories,
    required this.services,
    required this.droppedCount,
    required this.onItemExclude,
    required this.onViewMemories,
  });

  final List<ContextAttributionItem> memories;
  final List<ContextAttributionItem> services;
  final int droppedCount;
  final void Function(ContextAttributionItem item)? onItemExclude;
  final VoidCallback? onViewMemories;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    // P1-6 降噪：无记忆注入且无超预算丢弃 → 不渲染（服务数与状态带胶囊
    // 重复，每轮必出属遥测噪音）。
    if (memories.isEmpty && droppedCount == 0) {
      return const SizedBox.shrink();
    }
    final label =
        '本轮上下文：记忆 ${memories.length} 条 · 服务 ${services.length} 个'
        '${droppedCount > 0 ? '（超预算丢弃 $droppedCount）' : ''}';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(t.cardRadius),
        onTap: () => _showDetailSheet(context, t),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '≡ $label ▾',
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.note,
                  color: t.dataRef,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetailSheet(BuildContext context, ConsoleTokens t) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetCtx) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本轮携带上下文',
                  style: TextStyle(
                    fontSize: Fsz.telemetry,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '以下内容在本轮回答前已注入模型（快照，仅展示）',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
                ),
                if (droppedCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '另有 $droppedCount 条记忆超出预算未注入（可经 query_memory 检索）',
                    style: TextStyle(fontSize: Fsz.note, color: t.l2Warn),
                  ),
                ],
                if (memories.isNotEmpty) ...[
                  const Divider(height: 16),
                  // P1-7：有直达入口时**不再在此重抄**记忆条目——同一份内容多处
                  // 展示（归因详情 / AppBar 本轮记录 / 流内胶囊），用户认不出哪份
                  // 可管理。此处降级为计数 + 直达；历史恢复态（回调 null）保旧样。
                  if (onViewMemories != null)
                    ListTile(
                      key: const ValueKey('ctx-open-memory-list'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.bolt, size: 18, color: t.dataRef),
                      title: Text('本轮注入记忆 ${memories.length} 条'),
                      subtitle: const Text('点开「本轮记录」查看全部'),
                      trailing: Icon(Icons.chevron_right, size: 18,
                          color: t.terminalMuted),
                      onTap: () {
                        Navigator.pop(context);
                        onViewMemories?.call();
                      },
                    )
                  else ...[
                    Text(
                      '宿主记忆（${memories.length}）',
                      style: TextStyle(
                        fontSize: Fsz.telemetry,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    for (final m in memories)
                      _ContextItemRow(item: m, onExclude: onItemExclude),
                  ],
                ],
                if (services.isNotEmpty) ...[
                  const Divider(height: 16),
                  Text(
                    '已挂载服务（${services.length}）',
                    style: TextStyle(
                      fontSize: Fsz.telemetry,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final s in services)
                    _ContextItemRow(item: s, onExclude: onItemExclude),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情单行：等宽来源标签（数据指针色）+ 内容（阅读轨小字）+ 预留排除按钮。
class _ContextItemRow extends StatelessWidget {
  const _ContextItemRow({required this.item, required this.onExclude});

  final ContextAttributionItem item;
  final void Function(ContextAttributionItem item)? onExclude;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: t.hairline,
              borderRadius: BorderRadius.circular(t.cardRadius),
            ),
            child: Text(
              item.source,
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.note,
                color: t.dataRef,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(item.text, style: TextStyle(fontSize: Fsz.note)),
          ),
          // 预留排除位：回调未接线（null）时不占位，交互零痕迹。
          if (onExclude != null)
            IconButton(
              icon: const Icon(Icons.close, size: 14),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              tooltip: '本轮排除此上下文',
              onPressed: () => onExclude!(item),
            ),
        ],
      ),
    );
  }
}
