/// 双轨消息流（M4-T3，F5.1）：阅读轨（Markdown 流式）+ 操作轨（卡片状态机）
/// 同轴混排组件。交互 SSOT = docs/product/chat-interaction.md §2（事件→轨道
/// 映射）；视觉 = ui-design §3.2 + console tokens。
///
/// - **条目 = 可变编排记录，组件无内部状态**：页面持 `_track` 列表按事件流
///   mutate，每帧以当前快照重建——终态锁定由页面保证（终态后不再 mutate，
///   ui-design §3.2 审计感）；与 CallCard「无内部状态」口径同构；
/// - **卡片组件全量复用 M2/M3 正式实现**：ConfirmationCard/BreakerCard/
///   FenceBlockCard 直接内嵌（含终态锁定形态），不另造；
/// - 用户轮次（TrackUser）：Indigo 竖条卡片（数据指针色，ui-design §1），
///   与操作卡同族排版——拒绝左右气泡（ui-design §3.2 同轴纪律）；
/// - 阅读轨文本经 StreamingRichText 渲染（P1 前缀块缓存；RichTextView 为
///   块渲染器，Markdown 只读，D12 自写方案）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../coordinator/permission_gateway.dart';
import '../../coordinator/fenced_cloud_engine.dart';
import '../../coordinator/tool_breaker.dart';
import 'breaker_card.dart';
import 'call_card.dart';
import 'confirmation_card.dart';
import 'fence_block_card.dart';
import 'streaming_rich_text.dart';
import '../tokens/console_tokens.dart';

/// 轨道条目（页面编排记录；sealed 供渲染穷举）。
sealed class TrackEntry {
  const TrackEntry();
}

/// 阅读轨文本（流式追加：页面往 [text] 写 delta）。
class TrackText extends TrackEntry {
  TrackText(String initial) {
    text.write(initial);
  }

  final StringBuffer text = StringBuffer();
}

/// 用户轮次（发送即插卡）。
class TrackUser extends TrackEntry {
  const TrackUser(this.text);

  final String text;
}

/// 操作轨执行卡（CallCard 快照源；终态后页面不再 mutate）。
class TrackCall extends TrackEntry {
  TrackCall({required this.tool});

  final String tool;
  CallCardPhase phase = CallCardPhase.running;
  String? progressNote;
  String preview = '';

  /// 终态结果全文（可展开查看；空 = 仅预览）。
  String resultText = '';
}

/// L2 确认卡（GateDelegate 待决挂起；用户操作后锁定终态）。
class TrackConfirm extends TrackEntry {
  TrackConfirm({required this.pending});

  final ToolPendingConfirmation pending;
  final Completer<GateDecision> completer = Completer<GateDecision>();
  GateDecision? decision;
  DateTime? decidedAt;
}

/// 熔断排查卡 / 步数墙卡。
class TrackBreaker extends TrackEntry {
  TrackBreaker.breaker(this.report) : wall = null;
  TrackBreaker.wall(this.wall) : report = null;

  final BreakerReport? report;
  final StepWallReport? wall;
  final Completer<Object?> completer = Completer<Object?>();
  String? lockedText;
  DateTime? decidedAt;
}

/// N7 围栏拦截卡（双选项）。
class TrackFence extends TrackEntry {
  TrackFence(this.info);

  final PiiMaskBlockInfo info;
  final Completer<bool> completer = Completer<bool>();
  bool? decision;
  DateTime? decidedAt;
}

/// 通告行（收尾/错误/状态注记；danger = Rose）。
class TrackNote extends TrackEntry {
  const TrackNote(this.text, {required this.danger});

  final String text;
  final bool danger;
}

/// 记忆胶囊（P2-6 / §3.6）：气泡底「⚡ 已记录 key=value [✕撤销]」嵌片——
/// 模型 In-band 捎带落库后页面插入；撤销回调由页面注入（session 域 →
/// workspace_states.remove），撤销后锁定终态呈现「已撤销」。
/// 恢复的历史胶囊不接撤销回调（onUndo=null 锁定，completer 同口径）。
class TrackMemoryCapsule extends TrackEntry {
  TrackMemoryCapsule({required this.key, required this.value, this.onUndo});

  final String key;
  final String value;

  /// 撤销回调（null = 撤销不可用：已撤销锁定 / 历史恢复态）。
  void Function()? onUndo;
  bool undone = false;
}

class DualTrackStream extends StatelessWidget {
  const DualTrackStream({
    super.key,
    required this.entries,
    this.controller,
    this.emptyHint = '',
  });

  final List<TrackEntry> entries;
  final ScrollController? controller;

  /// 空轨道提示（会话起始态）。
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty && emptyHint.isNotEmpty) {
      return Center(
        child: Text(
          emptyHint,
          style: TextStyle(
            color: consoleTokens(context).terminalMuted,
            fontSize: Fsz.body,
          ),
        ),
      );
    }
    // P2 运行概要收敛：连续的灰阶通告行（遥测类 TrackNote）折叠为一条可展开
    // 概要——阅读轨不被系统通告刷屏；危险通告（Rose）保持独立凸显。
    final rows = <Widget>[];
    final pendingNotes = <TrackNote>[];
    void flushNotes() {
      if (pendingNotes.isEmpty) return;
      // 单条不折叠：保持原通告行形态，零阅读成本。
      if (pendingNotes.length == 1) {
        rows.add(renderEntry(context, pendingNotes.single));
      } else {
        rows.add(_RunSummary(notes: List.of(pendingNotes)));
      }
      pendingNotes.clear();
    }

    for (final e in entries) {
      if (e is TrackNote && !e.danger) {
        pendingNotes.add(e);
      } else {
        flushNotes();
        rows.add(renderEntry(context, e));
      }
    }
    flushNotes();
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      children: rows,
    );
  }

  /// 条目 → 轨道 widget（公开静态：T3b 恢复装配复用 + 单测直测映射）。
  static Widget renderEntry(BuildContext context, TrackEntry entry) {
    switch (entry) {
      case TrackText(:final text):
        if (text.isEmpty) return const SizedBox.shrink();
        // P1（stream-perf §4）：流式前缀块缓存 + 隔离重绘——解析与渲染隔离
        // 收编于 StreamingRichText（RichTextView 仍为块渲染器）。
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: StreamingRichText(text: text.toString()),
        );
      case TrackUser(:final text):
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
      case TrackCall e:
        return CallCard(
          tool: e.tool,
          phase: e.phase,
          progressNote: e.progressNote,
          preview: e.preview,
          fullResult: e.resultText.isEmpty ? null : e.resultText,
        );
      case TrackConfirm(
        :final pending,
        :final decision,
        :final decidedAt,
        :final completer,
      ):
        return ConfirmationCard(
          toolName: pending.toolName,
          argumentsJson: pending.argumentsJson,
          onDecision: decision == null
              ? (d) {
                  entry.decision = d;
                  entry.decidedAt = DateTime.now();
                  completer.complete(d);
                }
              : null,
          lockedDecision: decision,
          lockedAt: decidedAt,
        );
      case TrackBreaker(
        :final report,
        :final wall,
        :final lockedText,
        :final decidedAt,
        :final completer,
      ):
        return BreakerCard(
          report: report,
          wall: wall,
          lockedText: lockedText,
          lockedAt: decidedAt,
          onBreaker: report == null
              ? null
              : (r) {
                  entry.lockedText = switch (r) {
                    RetryOnce() => '⟳ 已单步重试',
                    SkipOnce() => '⤼ 已跳过（错误回填）',
                    ManualResult() => '👤 已人工接管',
                  };
                  entry.decidedAt = DateTime.now();
                  completer.complete(r);
                },
          onStepWall: wall == null
              ? null
              : (relax) {
                  entry.lockedText = relax ? '⤒ 已放宽 +10 续跑' : '⊘ 已终止';
                  entry.decidedAt = DateTime.now();
                  completer.complete(relax);
                },
        );
      case TrackFence(
        :final info,
        :final decision,
        :final decidedAt,
        :final completer,
      ):
        return FenceBlockCard(
          engineName: info.engineName,
          failureMessage: info.failureMessage,
          onDecision: decision == null
              ? (sendRaw) {
                  entry.decision = sendRaw;
                  entry.decidedAt = DateTime.now();
                  completer.complete(sendRaw);
                }
              : null,
          lockedSendRaw: decision,
          lockedAt: decidedAt,
        );
      case TrackNote(:final text, :final danger):
        final t = consoleTokens(context);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          // 排障场景通告（尤其 ✕ 错误行）可长按复制。
          child: SelectableText(
            text,
            style: TextStyle(
              fontSize: Fsz.note,
              color: danger ? t.danger : t.terminalMuted,
            ),
          ),
        );
      case TrackMemoryCapsule(:final key, :final value, :final onUndo, :final undone):
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
                    '✕撤销',
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
}

/// Run 概要条（P2）：连续灰阶通告折叠为一条可展开行——标题计等宽遥测轨,
/// 展开即原通告行列表。危险通告不进此条（Rose 独立凸显由页面分组保证）。
class _RunSummary extends StatelessWidget {
  const _RunSummary({required this.notes});

  final List<TrackNote> notes;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          dense: true,
          iconColor: t.terminalMuted,
          collapsedIconColor: t.terminalMuted,
          title: Text(
            'Run 概要（${notes.length} 条通告）',
            style: TextStyle(
              fontFamily: t.monoFamily,
              fontSize: Fsz.telemetrySm,
              color: t.terminalMuted,
            ),
          ),
          children: [
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  n.text,
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
// ---------------------------------------------------------------------------
// 序列化（M4-T3b）：TrackEntry ↔ JSON——ConversationStore 只存 JSON，编解码
// 留在 UI 层（TrackEntry 是 UI 模型，层级纪律：④ 沙盒不 import ⑤）。
// ---------------------------------------------------------------------------

extension TrackEntryCodec on TrackEntry {
  static List<Map<String, Object?>> encode(List<TrackEntry> entries) => [
    for (final e in entries) _encode(e),
  ];

  static Map<String, Object?> _encode(TrackEntry e) => switch (e) {
    TrackUser(:final text) => {'type': 'user', 'text': text},
    TrackText(:final text) => {'type': 'text', 'text': text.toString()},
    TrackCall e => {
      'type': 'call',
      'tool': e.tool,
      'phase': e.phase.name,
      'progressNote': ?e.progressNote,
      'preview': e.preview,
      'resultText': e.resultText,
    },
    TrackConfirm(:final pending, :final decision, :final decidedAt) => {
      'type': 'confirm',
      'toolName': pending.toolName,
      'argumentsJson': pending.argumentsJson,
      'approved': ?decision?.approved,
      'reason': ?decision?.reason,
      'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
    },
    TrackBreaker(
      :final report,
      :final wall,
      :final lockedText,
      :final decidedAt,
    ) =>
      {
        'type': report != null ? 'breaker' : 'wall',
        'toolName': ?report?.toolName,
        'consecutiveFailures': ?report?.consecutiveFailures,
        'lastError': ?report?.lastError,
        'argumentsJson': ?report?.argumentsJson,
        'turnsUsed': ?wall?.turnsUsed,
        'limit': ?wall?.limit,
        'lockedText': ?lockedText,
        'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
      },
    TrackFence(:final info, :final decision, :final decidedAt) => {
      'type': 'fence',
      'engineName': info.engineName,
      'failureMessage': info.failureMessage,
      'sendRaw': ?decision,
      'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
    },
    TrackNote(:final text, :final danger) => {
      'type': 'note',
      'text': text,
      'danger': danger,
    },
    TrackMemoryCapsule(:final key, :final value, :final undone) => {
      'type': 'memory',
      'key': key,
      'value': value,
      'undone': undone,
    },
  };

  /// 恢复轨道（终态锁定呈现）：
  /// - 进行态卡片（running/stuck）收敛为 cancelled +「会话中断」预览——
  ///   恢复的历史里不存在仍在执行的工具；
  /// - 未决交互卡（confirm/breaker/fence 无裁决）降级为 Rose 通告行「会话
  ///   中断于待决卡片」——严禁恢复成可交互死卡（completer 无人应答）；
  /// - 未知条目降级为通告行（降级铁律：留痕不吞）。
  static List<TrackEntry> decode(List<dynamic> raw) {
    final out = <TrackEntry>[];
    for (final item in raw) {
      if (item is! Map) {
        out.add(const TrackNote('⚠ 存在无法恢复的轨道条目（格式未知）', danger: true));
        continue;
      }
      final m = Map<String, Object?>.from(item);
      final decidedAt = m['decidedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(m['decidedAt'] as int)
          : null;
      switch (m['type']) {
        case 'user':
          out.add(TrackUser(m['text'] as String? ?? ''));
        case 'text':
          out.add(TrackText(m['text'] as String? ?? ''));
        case 'call':
          final phase = CallCardPhase.values.firstWhere(
            (p) => p.name == m['phase'],
            orElse: () => CallCardPhase.cancelled,
          );
          final settled =
              phase == CallCardPhase.running || phase == CallCardPhase.stuck;
          out.add(
            TrackCall(tool: m['tool'] as String? ?? '?')
              ..phase = settled ? CallCardPhase.cancelled : phase
              ..preview = settled ? '(会话中断)' : (m['preview'] as String? ?? '')
              ..progressNote = m['progressNote'] as String?
              ..resultText = m['resultText'] as String? ?? '',
          );
        case 'note':
          out.add(
            TrackNote(
              m['text'] as String? ?? '',
              danger: m['danger'] as bool? ?? false,
            ),
          );
        case 'memory':
          // 历史恢复胶囊：不接撤销回调（onUndo=null 锁定呈现——恢复态无
          // 活页面的 store 绑定；撤销语义仅限当轮）。
          out.add(
            TrackMemoryCapsule(
              key: m['key'] as String? ?? '?',
              value: m['value'] as String? ?? '',
            )..undone = m['undone'] as bool? ?? false,
          );
        case 'confirm':
          final approved = m['approved'] as bool?;
          if (approved == null) {
            out.add(_interruptedNote(m['toolName'] as String? ?? '确认卡'));
            continue;
          }
          out.add(
            TrackConfirm(
                pending: ToolPendingConfirmation(
                  toolName: m['toolName'] as String? ?? '?',
                  argumentsJson: m['argumentsJson'] as String? ?? '{}',
                ),
              )
              ..decision = GateDecision(
                approved: approved,
                reason: m['reason'] as String?,
              )
              ..decidedAt = decidedAt,
          );
        case 'breaker':
          if (m['toolName'] is! String) {
            out.add(const TrackNote('⚠ 会话中断于排查卡', danger: true));
            continue;
          }
          out.add(
            TrackBreaker.breaker(
                BreakerReport(
                  toolName: m['toolName'] as String,
                  consecutiveFailures: m['consecutiveFailures'] as int? ?? 0,
                  lastError: m['lastError'] as String? ?? '',
                  argumentsJson: m['argumentsJson'] as String? ?? '{}',
                ),
              )
              ..lockedText = m['lockedText'] as String?
              ..decidedAt = decidedAt,
          );
        case 'wall':
          out.add(
            TrackBreaker.wall(
                StepWallReport(
                  turnsUsed: m['turnsUsed'] as int? ?? 0,
                  limit: m['limit'] as int? ?? 0,
                ),
              )
              ..lockedText = m['lockedText'] as String?
              ..decidedAt = decidedAt,
          );
        case 'fence':
          final sendRaw = m['sendRaw'] as bool?;
          if (sendRaw == null) {
            out.add(const TrackNote('⚠ 会话中断于围栏拦截卡', danger: true));
            continue;
          }
          out.add(
            TrackFence(
                PiiMaskBlockInfo(
                  engineName: m['engineName'] as String? ?? '?',
                  failureMessage: m['failureMessage'] as String? ?? '',
                  cause: '（历史会话：原始异常不可序列化，恢复期以消息文本为准）',
                ),
              )
              ..decision = sendRaw
              ..decidedAt = decidedAt,
          );
        default:
          out.add(const TrackNote('⚠ 存在无法恢复的轨道条目（类型未知）', danger: true));
      }
    }
    return out;
  }

  static TrackNote _interruptedNote(String what) =>
      TrackNote('⚠ 会话中断于待决卡片（$what 未裁决）', danger: true);
}
