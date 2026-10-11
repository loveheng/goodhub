import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/doc/rich_text.dart';

/// 解析器随迁冒烟（M4-T3/D12）：goodshare 原文件零改动随迁，其全量语义测试
/// 在 goodshare 仓；本仓只钉消费面关键口径——块识别与「降级不吞内容」铁律。
void main() {
  const parser = MarkdownSubsetParser();

  test('标题/段落/列表/代码块识别', () {
    final blocks = parser.parse(
        '# 大标题\n\n正文一段。\n\n- 甲\n- 乙\n\n```dart\nvoid main() {}\n```');
    expect(blocks, hasLength(4));
    expect(blocks[0], isA<HeadingBlock>());
    expect(blocks[1], isA<ParagraphBlock>());
    final list = blocks[2] as ListBlock;
    expect(list.ordered, isFalse);
    expect(list.items, hasLength(2));
    expect((blocks[3] as CodeBlock).language, 'dart');
    expect((blocks[3] as CodeBlock).code, contains('void main()'));
  });

  test('降级铁律：不认识的行不吞字符（降级为段落）', () {
    final raw = '普通段落\n怪标记 <<<??>>> 尾部';
    final blocks = parser.parse(raw);
    final text = [
      for (final b in blocks)
        if (b is ParagraphBlock)
          [for (final n in b.inline) if (n is InlineText) n.text].join(),
    ].join('\n');
    expect(text, contains('怪标记 <<<??>>> 尾部'));
  });

  test('todo 勾选解析为 done 标记（宿主只读呈现 ☐/☑）', () {
    final blocks = parser.parse('- [ ] 未完\n- [x] 已完');
    final list = blocks.single as ListBlock;
    expect(list.items[0].done, isFalse);
    expect(list.items[1].done, isTrue);
  });

  test('行内：粗体/行内代码/链接', () {
    final blocks = parser.parse('**加粗** 与 `code` 与 [链](https://x.y)');
    final para = blocks.single as ParagraphBlock;
    expect(para.inline.whereType<InlineStrong>(), isNotEmpty);
    expect(para.inline.whereType<InlineCode>().single.code, 'code');
    expect(para.inline.whereType<InlineLink>().single.url, 'https://x.y');
  });
}
