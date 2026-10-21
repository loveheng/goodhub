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

import '../../mcp/elicitation.dart';
import 'elicitation_card.dart';

/// 轨道条目（页面编排记录；sealed 供渲染穷举）。
sealed class TrackEntry {
  const TrackEntry();
}

/// C6（page-beautify P3）：完成通告文本——据此把「✓ 任务完成」从 Run 概要
/// 折叠中摘出、单独 Emerald 成行（chat_page 与本文件共此常量，防文本漂移）。
const String kTaskDoneNote = '✓ 任务完成';

/// A4（page-beautify P3）：首颗记忆胶囊的事前说明（chat_page onCapsule 幂等
/// 插入；恢复会话经序列化还原、不再触发插入）。
/// P2-12（2026-10-22）：思考轨表头的自述——「这是什么 + 影不影响结果」。
/// 与 [CloudThinkingDelta] 的展示 only 四不契约同口径（不进历史/不回放）。
const String kThinkingHint = '模型内部推理 · 不进对话历史，不影响结果';

const String kMemoryFirstNotice =
    '模型从对话中提取了一条事实写入记忆（可逐条撤销；顶部「本轮记忆」查看全部）';

/// 阅读轨文本（流式追加：页面往 [text] 写 delta）。
///
/// 自管件（window-slim P1-B/C/D 切片 C）：原页面 40ms 流控刷盘每帧整页
/// `setState` 只为刷新本条目文本——典型反模式。改由本件实现 [Listenable]，
/// [append] 写 delta 后仅自身通知，渲染侧经 `ListenableBuilder` 局部重绘，
/// 不再牵连整页重建（`StreamingRichText` 前缀块缓存仍收口细粒度）。
class TrackText extends TrackEntry with ChangeNotifier {
  TrackText(String initial) {
    text.write(initial);
  }

  final StringBuffer text = StringBuffer();

  /// 追加 delta 并通知自身监听者（仅本条目重绘，无整页 setState）。
  void append(String delta) {
    if (delta.isEmpty) return;
    text.write(delta);
    notifyListeners();
  }
}

/// 思考轨（2026-10-21 M1）：推理型云模型思维流（`reasoning_content`）的
/// **展示 only** 条目——内容不进历史/不回放（见 [CloudThinkingDelta] 契约）。
/// **默认收起**（用户拍板）：表头一行「思考过程 ▸」，点击展开/收起全文；
/// 持久化保留展开态（历史保真），恢复态按存档值呈现。
/// 自管件（同 TrackText 口径）：[append] 写 delta 后仅自身通知，渲染侧经
/// `ListenableBuilder` 局部重绘，不牵连整页重建。
class TrackThinking extends TrackEntry with ChangeNotifier {
  TrackThinking(String initial) {
    text.write(initial);
  }

  final StringBuffer text = StringBuffer();

  /// 展开态（默认收起；用户点击切换后持久化）。
  bool expanded = false;

  /// 追加 delta 并通知自身监听者（仅本条目重绘，无整页 setState）。
  void append(String delta) {
    if (delta.isEmpty) return;
    text.write(delta);
    notifyListeners();
  }

  /// 展开/收起切换。
  void toggle() {
    expanded = !expanded;
    notifyListeners();
  }
}

/// 用户轮次（发送即插卡）。
class TrackUser extends TrackEntry {
  const TrackUser(this.text);

  final String text;
}

/// 操作轨执行卡（CallCard 快照源；终态后页面不再 mutate）。
///
/// 自管件（window-slim P1-B/C/D 切片 C）：运行期相位/进度/预览/结果高频 mutate
/// 原每帧整页 `setState`——反模式。改由本件实现 [Listenable]，[patch] 改相位并
/// 仅自身通知，渲染侧经 `ListenableBuilder` 局部重绘。构造期直接赋值字段（如
/// 历史恢复解码）不触发通知，由随后整页重建读取，语义不变。
class TrackCall extends TrackEntry with ChangeNotifier {
  TrackCall({required this.tool});

  final String tool;
  CallCardPhase phase = CallCardPhase.running;
  String? progressNote;
  String preview = '';

  /// 终态结果全文（可展开查看；空 = 仅预览）。
  String resultText = '';

  /// A2（page-beautify）：服务端工具描述全文（run 起步由页面建映射注入；
  /// 恢复历史经 codec 还原）。CallCard 收起态显示首子句、可展开全文。
  String? description;

  /// 运行期更新相位/进度/预览/结果：合并写 + 单次自我通知（仅本卡局部重绘）。
  void patch({
    CallCardPhase? phase,
    String? progressNote,
    String? preview,
    String? resultText,
  }) {
    if (phase != null) this.phase = phase;
    if (progressNote != null) this.progressNote = progressNote;
    if (preview != null) this.preview = preview;
    if (resultText != null) this.resultText = resultText;
    notifyListeners();
  }
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

/// 引导卡（ux-hardening P0-1 冷启动）：会话内可操作提示——正文 + 单一
/// 动作按钮（如未配置服务的「去配置」）。
/// **瞬态条目**：动作回调不可序列化，页面在持久化前过滤（恢复会话不出
/// 现引导卡，由页面按当前配置状态重插）；编码侧兜底为通告行防万一直插。
class TrackGuide extends TrackEntry {
  const TrackGuide({
    required this.text,
    required this.actionLabel,
    this.onAction,
  });

  final String text;
  final String actionLabel;

  /// 动作回调（null = 锁定态：仅展示标签，不渲染按钮）。
  final VoidCallback? onAction;
}

/// 错误行动卡（ux-hardening P0-2）：任务中断的白话呈现——标题 + 建议 +
/// 可复制原始异常 + 「重试」动作。区别于 [TrackNote] 的纯通告：本卡携带
/// 自救入口。持久化保留（历史保真）；恢复会话 onAction=null 锁定为不可
/// 重试（恢复的历史里不存在可重跑的任务）。
class TrackError extends TrackEntry {
  TrackError({required this.title, required this.advice, required this.detail});

  final String title;
  final String advice;

  /// 原始异常文本（$error）——排障留痕，可复制。
  final String detail;

  /// 重试回调（null = 锁定态：恢复历史不可重试）。
  VoidCallback? onAction;

  /// 已点过重试 → 锁定为灰阶「已重试」（终态锁定，ui-design §3.2）。
  bool retried = false;
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

/// 本轮上下文归因条目（展示 only）：Run 装配后由页面插入，呈现「本轮携带
/// 哪些上下文」——记忆条目（scope 标签 + 内容）与已挂载服务；历史恢复态
/// 锁定呈现（onItemExclude=null，同 TrackMemoryCapsule 口径）。
/// 「本轮排除」为预留钩子：回调由页面注入才出现 ✕ 按钮，当前不接线，
/// 仅承载未来「排除 → 重新生成」的交互落点。
class ContextAttributionItem {
  const ContextAttributionItem({required this.source, required this.text});

  /// 来源标签（记忆 scope 如 `user` / `srv:goodshare`；服务则为其摘要名）。
  final String source;
  final String text;
}

class TrackContextAttribution extends TrackEntry {
  TrackContextAttribution({
    required this.memories,
    required this.services,
    this.droppedCount = 0,
    this.onItemExclude,
    this.onViewMemories,
  });

  /// 注入本轮 prompt 的记忆快照（原始顺序，页面上限内逐条展示）。
  final List<ContextAttributionItem> memories;

  /// 已挂载服务展示名快照（serverSummaries 值）。
  final List<ContextAttributionItem> services;

  /// 超预算丢弃的记忆条数（0 = 无截断）。
  final int droppedCount;

  /// 预留：单条排除回调（null = 不渲染排除按钮；当前页面不接线）。
  void Function(ContextAttributionItem item)? onItemExclude;

  /// P1-7（2026-10-22）：直接跳 AppBar「本轮记忆」汇总列表的回调。
  /// null = 详情仍按旧样逐条列出（历史恢复态同口径：无活页面可跳）。
  /// 动机：同一份记忆曾有三处展示（归因详情 / AppBar 列表 / 流内胶囊），用户
  /// 分辨不出哪一处是「可管理的那份」——此处降级为计数 + 直达入口。
  VoidCallback? onViewMemories;
}

/// elicitation 交互卡（server→宿主结构化提问；MCP 2025-06-18 elicitation/create）。
/// 未决态（answer == null）弹表单；已决态（answer != null）锁定呈现。
class TrackElicitation extends TrackEntry {
  TrackElicitation({required this.request});

  final ElicitationRequest request;
  final Completer<ElicitationAnswer> completer = Completer<ElicitationAnswer>();
  ElicitationAnswer? answer;
  DateTime? decidedAt;
}

class DualTrackStream extends StatelessWidget {
  const DualTrackStream({
    super.key,
    required this.entries,
    this.controller,
    this.listenable,
    this.emptyHint = '',
  });

  final List<TrackEntry> entries;
  final ScrollController? controller;

  /// 列表结构性变更端口（window-slim P1-B/C/D）：非空时外层包 `ListenableBuilder`，
  /// 列表增/删/清（controller 的 tracksListenable）仅本件重建；条目内部刷新（C：
  /// TrackText/TrackCall 自管）不触发本件，由其自身 ListenableBuilder 局部处理。
  /// 为空（如单测直接喂静态列表）则按原行为一次性构建。
  final Listenable? listenable;

  /// 空轨道提示（会话起始态）。
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    if (listenable == null) return _buildList(context);
    return ListenableBuilder(
      listenable: listenable!,
      builder: (ctx, _) => _buildList(ctx),
    );
  }

  Widget _buildList(BuildContext context) {
    if (entries.isEmpty && emptyHint.isNotEmpty) {
      // C5：空态提示同限宽（560——提示句不宜拉宽），居中。
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              emptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: consoleTokens(context).terminalMuted,
                fontSize: Fsz.body,
              ),
            ),
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
        // 以通告内容拼接为稳定 key：本件重建（列表增删）后 ExpansionTile
        // 展开态按 key 续接，不误塌缩（切片 C 引入外层 ListenableBuilder 后须保）。
        rows.add(
          _RunSummary(
            key: ValueKey(pendingNotes.map((n) => n.text).join('\u0000')),
            notes: List.of(pendingNotes),
          ),
        );
      }
      pendingNotes.clear();
    }

    for (final e in entries) {
      // C6：「✓ 任务完成」是 Run 级重要反馈——与遥测通告混排会被折叠降权
      // （滚回去看不到「任务成功了」），单独 Emerald 成行。
      if (e is TrackNote && e.text == kTaskDoneNote) {
        flushNotes();
        rows.add(_DoneNote(e));
      } else if (e is TrackNote && !e.danger) {
        pendingNotes.add(e);
      } else {
        flushNotes();
        rows.add(renderEntry(context, e));
      }
    }
    flushNotes();
    // C5：阅读轨限宽 720（与输入区同限）——宽屏下行宽 60+ 字阅读疲劳，
    // 中文长文舒适行宽约 30~40 字；桌面/折叠屏随 Center 居中。
    // B7：ListView(children:) → builder——rows 仍预构建（分组折叠语义所需），
    // 但 element/layout 懒化：几百轮长会话滚出视口的条目不再建 element
    // （原 children 模式一次性全量建）。彻底 builder 化需重排分组逻辑，
    // 待超长会话真机实测后再议。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView.builder(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          itemCount: rows.length,
          itemBuilder: (context, i) => rows[i],
        ),
      ),
    );
  }

  /// 条目 → 轨道 widget（公开静态：T3b 恢复装配复用 + 单测直测映射）。
  static Widget renderEntry(BuildContext context, TrackEntry entry) {
    switch (entry) {
      case TrackText():
        if (entry.text.isEmpty) return const SizedBox.shrink();
        final t = consoleTokens(context);
        // P1（stream-perf §4）：流式前缀块缓存 + 隔离重绘——解析与渲染隔离
        // 收编于 StreamingRichText（RichTextView 仍为块渲染器）。切片 C：本件自管
        // Listenable，delta 追加仅本条目局部重绘，不牵连整页（ListenableBuilder）。
        return ListenableBuilder(
          listenable: entry,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // C4：轮次标识——与用户轮「你」标签对称的极轻 assistant 标
                // （microSm 灰阶等宽），长会话多轮回看时轮次边界不再融化。
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
      case TrackThinking e:
        // 切片 C：本件自管 Listenable，思维流 delta 追加与展开切换仅本条目
        // 局部重绘（ListenableBuilder），不牵连整页。
        final t = consoleTokens(context);
        return ListenableBuilder(
          listenable: e,
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
                  onTap: e.toggle,
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
                          e.expanded ? ' ▾' : ' ▸',
                          style: TextStyle(
                            fontFamily: t.monoFamily,
                            fontSize: Fsz.note,
                            color: t.terminalMuted,
                          ),
                        ),
                        // P2-12（2026-10-22）：默认收起是对的，但只露「思考过程
                        // ▸」时用户要自己猜「这坨要不要看、看了算不算数」。补
                        // 一句自述把决策成本降到零——它不进 transcript、不参与
                        // 结果（CloudThinkingDelta 四不契约），故明说「不影响结果」。
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
                if (e.expanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    child: SelectableText(
                      e.text.toString(),
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
        // 切片 C：本件自管 Listenable，运行期相位/进度/结果变更仅本卡局部重绘
        // （ListenableBuilder），不再整页 setState。
        return ListenableBuilder(
          listenable: e,
          builder: (context, _) => CallCard(
            tool: e.tool,
            phase: e.phase,
            progressNote: e.progressNote,
            preview: e.preview,
            fullResult: e.resultText.isEmpty ? null : e.resultText,
            description: e.description,
          ),
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
      case TrackElicitation(
        :final request,
        :final answer,
        :final decidedAt,
        :final completer,
      ):
        return ElicitationCard(
          request: request,
          onDecision: answer == null
              ? (a) {
                  entry.answer = a;
                  entry.decidedAt = DateTime.now();
                  completer.complete(a);
                }
              : null,
          lockedAnswer: answer,
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
      case TrackGuide(:final text, :final actionLabel, :final onAction):
        return _TrackActionCard(
          danger: false,
          actionLabel: actionLabel,
          onAction: onAction,
          child: Text(
            text,
            style: const TextStyle(fontSize: Fsz.note, height: 1.4),
          ),
        );
      case TrackError(
        :final title,
        :final advice,
        :final detail,
        :final retried,
        :final onAction,
      ):
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
              if (detail.isNotEmpty)
                SelectableText(
                  detail,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetrySm,
                    color: t.terminalMuted,
                  ),
                ),
            ],
          ),
        );
      case TrackMemoryCapsule(
        :final key,
        :final value,
        :final onUndo,
        :final undone,
      ):
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
      case TrackContextAttribution(
        :final memories,
        :final services,
        :final droppedCount,
        :final onItemExclude,
        :final onViewMemories,
      ):
        return _ContextAttributionRow(
          memories: memories,
          services: services,
          droppedCount: droppedCount,
          onItemExclude: onItemExclude,
          onViewMemories: onViewMemories,
        );
    }
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
                  // P1-7：有直达入口时**不再在此重抄**记忆条目——同一份内容三处
                  // 展示（归因详情 / AppBar 本轮记忆 / 流内胶囊），用户认不出哪份
                  // 可管理。此处降级为计数 + 直达；历史恢复态（回调 null）保旧样。
                  if (onViewMemories != null)
                    ListTile(
                      key: const ValueKey('ctx-open-memory-list'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.bolt, size: 18, color: t.dataRef),
                      title: Text('本轮注入记忆 ${memories.length} 条'),
                      subtitle: const Text('点开「本轮记忆」查看全部'),
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

/// Run 概要条（P2）：连续灰阶通告折叠为一条可展开行——标题计等宽遥测轨,
/// 展开即原通告行列表。危险通告不进此条（Rose 独立凸显由页面分组保证）。

/// C6：完成通告独立行（Emerald + w600 微强调）——脱离 Run 概要折叠，重要
/// 反馈不被遥测通告稀释；SelectableText 保持排障复制口径。
class _DoneNote extends StatelessWidget {
  const _DoneNote(this.note);

  final TrackNote note;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SelectableText(
        note.text,
        style: TextStyle(
          fontSize: Fsz.note,
          fontWeight: FontWeight.w600,
          color: t.l1Ok,
        ),
      ),
    );
  }
}
class _RunSummary extends StatelessWidget {
  const _RunSummary({super.key, required this.notes});

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
            // P0-4（2026-10-22）：原「Run 概要（N 条通告）」把内部 Run 概念
            // 直出用户面（违反 ui-design §2「内部名禁直出」）；改人话。
            '${notes.length} 条系统通告（点开查看）',
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
    // 思考轨持久化保留（历史保真）：展开态随存档恢复（缺省 = 收起）。
    TrackThinking e => {
      'type': 'thinking',
      'text': e.text.toString(),
      'expanded': e.expanded,
    },
    TrackText(:final text) => {'type': 'text', 'text': text.toString()},
    TrackCall e => {
      'type': 'call',
      'tool': e.tool,
      'phase': e.phase.name,
      'progressNote': ?e.progressNote,
      'preview': e.preview,
      'resultText': e.resultText,
      // A2：描述全文持久化（恢复会话人话行不丢；缺省 = 旧数据无描述）。
      'description': ?e.description,
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
    TrackElicitation(:final request, :final answer, :final decidedAt) => {
      'type': 'elicitation',
      'message': request.message,
      'schema': request.schema,
      'action': answer?.accepted == true ? 'accept' : 'decline',
      'content': answer?.content,
      'reason': answer?.reason,
      'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
    },
    TrackNote(:final text, :final danger) => {
      'type': 'note',
      'text': text,
      'danger': danger,
    },
    // 瞬态条目：页面持久化前已过滤；此处兜底防直插（丢动作保文本）。
    TrackGuide(:final text) => {'type': 'note', 'text': text, 'danger': false},
    // 错误卡持久化保留（历史保真）：onAction 不序列化（恢复态锁定）。
    TrackError e => {
      'type': 'error',
      'title': e.title,
      'advice': e.advice,
      'detail': e.detail,
      'retried': e.retried,
    },
    TrackMemoryCapsule(:final key, :final value, :final undone) => {
      'type': 'memory',
      'key': key,
      'value': value,
      'undone': undone,
    },
    TrackContextAttribution(
      :final memories,
      :final services,
      :final droppedCount,
    ) =>
      {
        'type': 'context',
        'memories': [
          for (final m in memories) {'s': m.source, 't': m.text},
        ],
        'services': [
          for (final s in services) {'s': s.source, 't': s.text},
        ],
        'droppedCount': droppedCount,
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
        case 'thinking':
          // 历史恢复思考轨：按存档展开态呈现（缺省收起——默认收起拍板口径）。
          out.add(TrackThinking(m['text'] as String? ?? '')
            ..expanded = m['expanded'] as bool? ?? false);
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
              ..resultText = m['resultText'] as String? ?? ''
              ..description = m['description'] as String?,
          );
        case 'note':
          out.add(
            TrackNote(
              m['text'] as String? ?? '',
              danger: m['danger'] as bool? ?? false,
            ),
          );
        case 'error':
          // 恢复的错误卡：onAction=null 锁定（恢复历史里无可重跑的任务），
          // retried 原样保留呈现。
          out.add(
            TrackError(
              title: m['title'] as String? ?? '任务中断',
              advice: m['advice'] as String? ?? '',
              detail: m['detail'] as String? ?? '',
            )..retried = m['retried'] as bool? ?? false,
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
        case 'context':
          // 历史恢复归因条：仅展示快照（onItemExclude=null 锁定，同上口径）。
          List<ContextAttributionItem> items(Object? raw) => [
            for (final e in (raw as List? ?? const []))
              if (e is Map)
                ContextAttributionItem(
                  source: e['s'] as String? ?? '?',
                  text: e['t'] as String? ?? '',
                ),
          ];
          out.add(
            TrackContextAttribution(
              memories: items(m['memories']),
              services: items(m['services']),
              droppedCount: m['droppedCount'] as int? ?? 0,
            ),
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
        case 'elicitation':
          final action = m['action'] as String?;
          if (action == null) {
            out.add(_interruptedNote(m['message'] as String? ?? 'elicitation'));
            continue;
          }
          out.add(
            TrackElicitation(
              request: ElicitationRequest(
                message: m['message'] as String? ?? '',
                schema: m['schema'] is Map<String, Object?>
                    ? m['schema'] as Map<String, Object?>
                    : const {},
              ),
            )
              ..answer = action == 'accept'
                  ? ElicitationAnswer(
                      accepted: true,
                      content: m['content'] is Map<String, Object?>
                          ? m['content'] as Map<String, Object?>
                          : const {},
                    )
                  : ElicitationAnswer(accepted: false, reason: m['reason'] as String?),
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
