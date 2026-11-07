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


import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';


// S4 下沉：轨道模型 + codec 住 coordinator/chat_track_model.dart（内核
// 认识轨道语义，会话持久化不再是 UI 模型序列化）；本件留渲染映射与交互
// 生命周期，re-export 保持既有 UI import 面零扰动。
import 'track_entry_render.dart';
import '../../coordinator/chat_track_model.dart';
export '../../coordinator/chat_track_model.dart';


class DualTrackStream extends StatelessWidget {
  const DualTrackStream({
    super.key,
    required this.entries,
    this.controller,
    this.listenable,
    this.emptyHint = '',
    this.emptyExamples = const [],
    this.onExampleTap,
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

  /// 空态示例任务 chip（盘点 2026-11-06 #10）：已配置用户的空态此前仅静态
  /// 文字无下一步动作——补示例任务，点击即填入输入框（填充归调用方）。
  final List<String> emptyExamples;
  final ValueChanged<String>? onExampleTap;

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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  emptyHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: consoleTokens(context).terminalMuted,
                    fontSize: Fsz.body,
                  ),
                ),
                // 示例任务 chip（盘点 #10）：空态从「只读提示」变「可操作
                // 起点」——点击即填入输入框，回车/发送键即达。
                if (emptyExamples.isNotEmpty && onExampleTap != null) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final example in emptyExamples)
                        ActionChip(
                          label: Text(
                            example,
                            style: TextStyle(
                              fontSize: Fsz.note,
                              color: consoleTokens(context).l1Info,
                            ),
                          ),
                          onPressed: () => onExampleTap!(example),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    // P2 运行概要收敛：连续的灰阶通告行（遥测类 TrackNote）折叠为一条可展开
    // 概要——阅读轨不被系统通告刷屏；危险通告（Rose）保持独立凸显。
    // round-record（2026-10-31）：聊天主页已不再把系统通告交给本件（通告全额
    // 落「本轮记录」账本、阅读轨零占位），此处折叠转为**兜底**——仍可能拿到
    // TrackNote 的调用面（历史快照回放、联调页操作轨）照旧不刷屏。
    final rows = <Widget>[];
    final pendingNotes = <TrackNote>[];
    void flushNotes() {
      if (pendingNotes.isEmpty) return;
      // 单条不折叠：保持原通告行形态，零阅读成本。
      if (pendingNotes.length == 1) {
        rows.add(TrackEntryRender.renderEntry(context, pendingNotes.single));
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
        rows.add(TrackEntryRender.renderEntry(context, e));
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

}

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
