/// 阅读轨富文本只读渲染（M4-T3 / D12）。
///
/// 输入 = 已解析块树 `List<RichBlock>`（DIP：parse 由调用点经 `rich_text` 实现库
/// `markdown_subset.dart` 完成，本组件只依赖抽象库 `rich_text.dart` 的 AST）+
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
import 'package:flutter/services.dart';
import 'package:rich_text/rich_text.dart';

import 'tokens/console_tokens.dart';

class RichTextView extends StatelessWidget {
  const RichTextView({super.key, required this.blocks});

  final List<RichBlock> blocks;

  /// 长按复制 URL + Toast 反馈（P2 低优拍板：链接不可点，复制替代跳转）。
  static void _copyUrl(BuildContext context, String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('✓ 已复制链接'),
          duration: Duration(milliseconds: 1500),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
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
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        );
      case ParagraphBlock(:final inline):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text.rich(
            TextSpan(children: [for (final n in inline) _inline(context, n)]),
            style: const TextStyle(fontSize: Fsz.reading, height: 1.55),
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
                    children: [for (final c in children) _block(context, c)],
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
                      child: Text(
                        language,
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.microSm,
                          color: t.terminalMuted,
                        ),
                      ),
                    ),
                  Text(
                    code,
                    style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: Fsz.note,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case MathBlock(:final source):
        // 数学块降级（M 阶段不引 KaTeX）：LaTeX 源码等宽呈现，`$$` 定界符
        // 保留可读——样式平但不吞内容（降级铁律）。
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
              child: Text(
                '\$\$$source\$\$',
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.note,
                  height: 1.45,
                ),
              ),
            ),
          ),
        );
      case TableBlock(:final header, :final rows, :final align):
        final t = consoleTokens(context);
        // 列对齐（parser 透传的 GFM 对齐标记；缺省左对齐）。
        TextAlign alignOf(int c) => switch (align == null || c >= align.length
            ? TableAlign.left
            : align[c]) {
          TableAlign.left => TextAlign.left,
          TableAlign.center => TextAlign.center,
          TableAlign.right => TextAlign.right,
        };
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              // 关键：列宽按内容自适应（IntrinsicColumnWidth）。否则 Table 默认
              // FlexColumnWidth(1) 在横向滚动的无限宽约束下塌成 0 宽，单元格重叠
              // 错乱；超宽内容交给外层横向滚动兜底（宁可横向滚不挤变形）。
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(
                color: t.hairline,
                width: 0.6,
              ),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  decoration: BoxDecoration(color: t.codeBg),
                  children: [
                    for (var c = 0; c < header.length; c++)
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          header[c],
                          textAlign: alignOf(c),
                          style: const TextStyle(
                            fontSize: Fsz.note,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
                for (final row in rows)
                  TableRow(
                    children: [
                      for (var c = 0; c < row.length; c++)
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            row[c],
                            textAlign: alignOf(c),
                            style: const TextStyle(
                              fontSize: Fsz.note,
                              height: 1.4,
                            ),
                          ),
                        ),
                    ],
                  ),
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
  /// 长按复制 URL（P2 拍板：链接不可点、零新依赖，复制替代跳转）。
  Widget _mediaLine(
    BuildContext context,
    String kind,
    String label,
    String url,
  ) {
    final t = consoleTokens(context);
    return GestureDetector(
      onLongPress: () => _copyUrl(context, url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$kind ',
                style: TextStyle(fontSize: Fsz.body, color: t.terminalMuted),
              ),
              TextSpan(
                text: label.isEmpty ? url : label,
                style: TextStyle(
                  fontSize: Fsz.mediaLabel,
                  color: t.dataRef,
                  decoration: TextDecoration.underline,
                  decorationColor: t.dataRef,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _listItem(BuildContext context, ListItem item, String marker) {
    final lines = item.lines;
    final first = lines.isEmpty
        ? const <InlineNode>[InlineText('')]
        : lines.first;
    Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: item.done != null ? 22 : 18,
          child: Text(
            item.done == null ? marker : (item.done! ? '☑' : '☐'),
            style: const TextStyle(fontSize: Fsz.listPrimary, height: 1.55),
          ),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(children: [for (final n in first) _inline(context, n)]),
            style: TextStyle(
              fontSize: Fsz.reading,
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
          style: const TextStyle(fontSize: Fsz.reading, height: 1.55),
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
          style: const TextStyle(fontWeight: FontWeight.w700),
        );
      case InlineEm(:final children):
        return TextSpan(
          children: _inlineSpans(context, children),
          style: const TextStyle(fontStyle: FontStyle.italic),
        );
      case InlineUnderline(:final children):
        return TextSpan(
          children: _inlineSpans(context, children),
          style: const TextStyle(decoration: TextDecoration.underline),
        );
      case InlineStrikethrough(:final children):
        return TextSpan(
          children: _inlineSpans(context, children),
          style: const TextStyle(decoration: TextDecoration.lineThrough),
        );
      case InlineHighlight(:final children):
        return TextSpan(
          children: _inlineSpans(context, children),
          style: TextStyle(backgroundColor: t.codeBg),
        );
      case InlineCode(:final code):
        return TextSpan(
          text: code,
          style: TextStyle(
            fontFamily: t.monoFamily,
            fontSize: Fsz.body,
            backgroundColor: t.codeBg,
          ),
        );
      case InlineMath(:final source):
        // 行内数学降级：`$` 定界符 + 等宽，不引 KaTeX（样式平不吞内容）。
        return TextSpan(
          text: '\$$source\$',
          style: TextStyle(
            fontFamily: t.monoFamily,
            fontSize: Fsz.body,
            backgroundColor: t.codeBg,
          ),
        );
      case InlineLink(:final label, :final url):
        // 不可点击（goodshare 同口径，不引 url_launcher）；长按复制 URL
        // 替代跳转（P2 拍板），url 留审计可读（semanticsLabel）。
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            onLongPress: () => _copyUrl(context, url),
            child: Text(
              label,
              style: TextStyle(
                fontSize: Fsz.reading,
                height: 1.55,
                color: t.dataRef,
                decoration: TextDecoration.underline,
                decorationColor: t.dataRef,
              ),
              semanticsLabel: url,
            ),
          ),
        );
    }
  }
}
