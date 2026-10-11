/// 阅读轨 Markdown 只读渲染（M4-T3 / D12）。
///
/// 组成 = goodshare 自写解析器（`lib/doc/rich_text.dart` 随迁，零依赖）+
/// 本渲染器（宿主自写只读版）——不复用 goodshare 的 `ui/rich_text_view.dart`：
/// 其样式绑 goodshare tokens 与勾选/媒体交互面，与 goodhub ui-design 控制台
/// 风格不同源（ui-design §2 阅读轨排版：无衬线、行高 1.5~1.6、代码块微深底）。
///
/// - 降级铁律沿用解析器口径：**宁可样式平，不可吞内容**——媒体块
///   （Image/Audio/Video）M 阶段降级为链接文本行（Indigo 数据指针色，
///   ui-design §1），不内嵌播放器不丢信息；
/// - 行内链接不可点击（不引 url_launcher，goodshare 同口径）；
/// - todo 勾选只读呈现（☐/☑ 字形，无交互——宿主聊天无 todo_state_json 落点）；
/// - 恒 shrinkWrap（Column mainAxisSize.min）——聊天流逐条内嵌 ListView。
library;

import 'package:flutter/material.dart';

import '../doc/rich_text.dart';
import 'tokens/console_tokens.dart';

class RichTextView extends StatelessWidget {
  const RichTextView({super.key, required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final blocks = const MarkdownSubsetParser().parse(markdown);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final b in blocks) _block(context, b)],
    );
  }

  Widget _block(BuildContext context, RichBlock block) {
    switch (block) {
      case HeadingBlock(:final level, :final inline):
        final size = switch (level) {
          1 => 19.0,
          2 => 17.0,
          3 => 15.5,
          _ => 14.5,
        };
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text.rich(
            TextSpan(children: [for (final n in inline) _inline(context, n)]),
            style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, height: 1.4),
          ),
        );
      case ParagraphBlock(:final inline):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text.rich(
            TextSpan(children: [
              for (final n in inline) _inline(context, n),
            ]),
            style: const TextStyle(fontSize: 14.5, height: 1.55),
          ),
        );
      case QuoteBlock(:final children):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: consoleTokens(context).hairline),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final c in children) _block(context, c),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      case ListBlock(:final ordered, :final items):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < items.length; i++)
                _listItem(context, items[i], ordered ? '${i + 1}.' : '•'),
            ],
          ),
        );
      case CodeBlock(:final code, :final language):
        final t = consoleTokens(context);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: t.codeBg,
              borderRadius: BorderRadius.circular(t.cardRadius),
              border: Border.all(color: t.hairline),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (language != null && language.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(language,
                          style: TextStyle(
                              fontFamily: t.monoFamily,
                              fontSize: 10.5,
                              color: t.terminalMuted)),
                    ),
                  Text(code,
                      style: TextStyle(
                          fontFamily: t.monoFamily, fontSize: 12.5, height: 1.45)),
                ],
              ),
            ),
          ),
        );
      case TableBlock(:final header, :final rows):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              border: TableBorder.all(color: consoleTokens(context).hairline, width: 0.6),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    color: consoleTokens(context).codeBg,
                  ),
                  children: [
                    for (final h in header)
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(h,
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                  ],
                ),
                for (final row in rows)
                  TableRow(children: [
                    for (final cell in row)
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(cell,
                            style: const TextStyle(fontSize: 12.5, height: 1.4)),
                      ),
                  ]),
              ],
            ),
          ),
        );
      case DividerBlock():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(height: 0.7, color: consoleTokens(context).hairline),
        );
      case ImageBlock(:final url, :final alt):
        return _mediaLine(context, '🖼 图片', alt, url);
      case AudioBlock(:final url, :final label):
        return _mediaLine(context, '🎧 音频', label, url);
      case VideoBlock(:final url, :final label):
        return _mediaLine(context, '🎬 视频', label, url);
    }
  }

  /// 媒体块降级呈现（M 阶段不内嵌播放器/图片——链接文本行不丢信息）。
  Widget _mediaLine(BuildContext context, String kind, String label, String url) {
    final t = consoleTokens(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '$kind ', style: TextStyle(fontSize: 13, color: t.terminalMuted)),
          TextSpan(
            text: label.isEmpty ? url : label,
            style: TextStyle(
                fontSize: 13.5,
                color: t.dataRef,
                decoration: TextDecoration.underline,
                decorationColor: t.dataRef),
          ),
        ]),
      ),
    );
  }

  Widget _listItem(BuildContext context, ListItem item, String marker) {
    final lines = item.lines;
    final first = lines.isEmpty ? const <InlineNode>[InlineText('')] : lines.first;
    Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: item.done != null ? 22 : 18,
          child: Text(
            item.done == null ? marker : (item.done! ? '☑' : '☐'),
            style: const TextStyle(fontSize: 14, height: 1.55),
          ),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(children: [for (final n in first) _inline(context, n)]),
            style: TextStyle(
              fontSize: 14.5,
              height: 1.55,
              decoration: item.done == true ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ],
    );
    // 续行（≥2 空格缩进归属同项）：与首行同列缩进呈现。
    for (final cont in lines.skip(1)) {
      final extra = Padding(
        padding: EdgeInsets.only(left: item.done != null ? 22 : 18),
        child: Text.rich(
          TextSpan(children: [for (final n in cont) _inline(context, n)]),
          style: const TextStyle(fontSize: 14.5, height: 1.55),
        ),
      );
      row = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [row, extra],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: row,
    );
  }

  List<InlineSpan> _inlineSpans(BuildContext context, List<InlineNode> nodes) =>
      [for (final n in nodes) _inline(context, n)];

  InlineSpan _inline(BuildContext context, InlineNode node) {
    final t = consoleTokens(context);
    switch (node) {
      case InlineText(:final text):
        return TextSpan(text: text);
      case InlineStrong(:final children):
        return TextSpan(
            children: _inlineSpans(context, children),
            style: const TextStyle(fontWeight: FontWeight.w700));
      case InlineEm(:final children):
        return TextSpan(
            children: _inlineSpans(context, children),
            style: const TextStyle(fontStyle: FontStyle.italic));
      case InlineUnderline(:final children):
        return TextSpan(
            children: _inlineSpans(context, children),
            style: const TextStyle(decoration: TextDecoration.underline));
      case InlineStrikethrough(:final children):
        return TextSpan(
            children: _inlineSpans(context, children),
            style: const TextStyle(decoration: TextDecoration.lineThrough));
      case InlineHighlight(:final children):
        return TextSpan(
            children: _inlineSpans(context, children),
            style: TextStyle(backgroundColor: t.codeBg));
      case InlineCode(:final code):
        return TextSpan(
          text: code,
          style: TextStyle(
            fontFamily: t.monoFamily,
            fontSize: 13,
            backgroundColor: t.codeBg,
          ),
        );
      case InlineLink(:final label, :final url):
        return TextSpan(
          text: label,
          style: TextStyle(
            color: t.dataRef,
            decoration: TextDecoration.underline,
            decorationColor: t.dataRef,
          ),
          // 不可点击（goodshare 同口径，不引 url_launcher）；url 留审计可读。
          semanticsLabel: url,
        );
    }
  }
}
