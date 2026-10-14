/// P1 前缀块缓存单测（stream-perf §4/§5）：
/// ① 安全切点逐规则单测（跨行上下文禁切）；② 增量≡全量 AST 等价性 fuzz
/// （枚举所有安全切点 + 逐字流式喂入的全程不变量）；③ 禁切规则 load-bearing
/// 反证；④ widget 行为（稳定/尾块拆分、RepaintBoundary、缓存实例复用）。
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/components/streaming_rich_text.dart';
import 'package:goodhub/ui/rich_text_view.dart';
// markdown_subset.dart 已 export 抽象库 rich_text.dart（serializeBlocks 等）。
import 'package:rich_text/markdown_subset.dart';

const _parser = MarkdownSubsetParser();

String _ser(List<RichBlock> blocks) => serializeBlocks(blocks);

/// 全量 parse 的序列化（等价性基准）。
String _full(String text) => _ser(_parser.parse(text));

/// 增量视角：parse(前缀) + parse(尾部) 的序列化。
String _inc(String text, int cut) => _ser([
      ..._parser.parse(text.substring(0, cut)),
      ..._parser.parse(text.substring(cut)),
    ]);

/// 行边界偏移（含幻尾行位置）。
List<int> _lineStarts(String text) {
  final out = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) out.add(i + 1);
  }
  return out;
}

/// 计量 parser：包裹真实 parser，累计 parse 调用次数与入参字符数
/// （P1 优化效果的机械证明：增量解析总量 vs 全量重解析口径）。
class _CountingParser implements RichTextParser {
  final _inner = const MarkdownSubsetParser();
  int parseCalls = 0;
  int chars = 0;

  @override
  List<RichBlock> parse(String markdown) {
    parseCalls++;
    chars += markdown.length;
    return _inner.parse(markdown);
  }

  @override
  List<InlineNode> parseInline(String text) => _inner.parseInline(text);
}

void main() {
  group('安全切点逐规则（P1，stream-perf §4）', () {
    test('空行 / 硬块起始可切；段落中行禁切', () {
      expect(isSafeCut('# a\n\nb', 4), isTrue, reason: '空行恒分隔');
      expect(isSafeCut('text\n# h\nx', 5), isTrue, reason: '标题是硬块起始');
      expect(isSafeCut('text\n- item\nx', 5), isTrue, reason: '列表项是硬块起始');
      expect(isSafeCut('a\nb', 2), isFalse, reason: '段落合并风险，禁切');
      expect(isSafeCut('a\nb\nc', 2), isFalse);
      expect(isSafeCut('a\nb\nc', 4), isFalse);
    });

    test('末行未完结禁切（分类可被 delta 撤销）', () {
      // 标题/引用/列表/数学开头行虽增长稳定，但一律等换行到达才切
      // （保守口径：末行分类撤销会回头吞掉已稳定边界）。
      expect(isSafeCut('text\n# h', 5), isFalse, reason: '末行未完结');
      expect(isSafeCut('text\n- item', 5), isFalse);
      expect(isSafeCut('text\n> q', 5), isFalse);
      expect(isSafeCut('a\n\$\$', 2), isFalse, reason: '末行数学开头行未完结');
      expect(isSafeCut('text\n# h\n', 10), isFalse, reason: '幻尾行禁切');
      expect(isSafeCut('text\n# h\n', 5), isTrue, reason: '标题行已完结（幻尾行仅禁自身）');
      expect(isSafeCut('text\n# h\nx', 5), isTrue, reason: '换行 + 后续行到达后可切');
    });

    test('未闭合代码围栏内禁切；闭合后恢复可切', () {
      expect(isSafeCut('```dart\ncode\nmore', 8), isFalse, reason: '围栏内一切行皆是内容');
      expect(isSafeCut('```dart\ncode\n```\nx', 17), isFalse, reason: '闭合围栏行本身在围栏内');
      expect(isSafeCut('```dart\ncode\n```\n# h\nx', 17), isTrue, reason: '闭合后遇硬块起始可切');
      expect(isSafeCut('```\n```\n# h\nx', 8), isTrue, reason: '空围栏闭合后可切');
    });

    test('\$\$ 数学块：开头行可切、跨度内禁切、闭合后恢复', () {
      expect(isSafeCut('a\n\$\$\nb', 2), isTrue,
          reason: '数学开头行是硬块起始（parser _isBlockStart 含 \$\$ 开头行）');
      expect(isSafeCut('\$\$\nx\n\$\$\n# h\nz', 8), isTrue, reason: '闭合后遇硬块起始可切');
      expect(isSafeCut('\$\$\nx\n\$\$\n# h\nz', 3), isFalse, reason: '跨度内禁切');
      expect(isSafeCut('\$\$\nx\n\$\$', 3), isFalse, reason: '裸 \$\$ 开后跨行等待闭合');
      expect(isSafeCut('a\n\$\$x = 1\$\$\nb', 2), isTrue, reason: '开闭同行的单行数学');
      expect(isSafeCut('x\n\$\$ a | b\n--- | ---\nz', 2), isTrue,
          reason: '数学开头行先于表格裁决（含 | 也是数学块，非表格行）');
    });

    test('幻尾行禁切（后续 delta 落上会与前块合并）', () {
      expect(isSafeCut('a\n', 2), isFalse, reason: '幻尾行不是真分隔');
      expect(isSafeCut('a\n\n', 2), isTrue, reason: '真空中行可切');
      expect(isSafeCut('a\n\n', 3), isFalse, reason: '幻尾行禁切');
      expect(isSafeCut('# h\n', 4), isFalse);
    });

    test('引用续行 / 列表续行禁切', () {
      expect(isSafeCut('> a\n> b\nc', 4), isFalse, reason: '引用块跨行吸收');
      expect(isSafeCut('x\n> a\n> b', 2), isTrue, reason: '引用首行前可切');
      expect(isSafeCut('- a\n- b\nc', 4), isFalse, reason: '列表跨项吸收');
      expect(isSafeCut('1. a\n- b\nc', 5), isFalse, reason: '有序列表吸收无序项');
      expect(isSafeCut('- a\n  cont\n- b', 4), isFalse, reason: '缩进续行');
      expect(isSafeCut('- a\n  cont\n- b\nc', 11), isFalse, reason: '续行后的新列表项');
      expect(isSafeCut('x\n- b\nc', 2), isTrue, reason: '段落后的列表首项可切');
      expect(isSafeCut('> q\n- b\nc', 4), isTrue, reason: '引用后的列表可切');
    });

    test('裸待办行不是硬块起始（开放段落吸收，禁切）', () {
      expect(isSafeCut('任务：\n[ ] 第一项\nx', 4), isFalse,
          reason: '_isBlockStart 不含 _todo → 段落吸收待办行');
      expect(isSafeCut('- a\n[ ] b\nc', 4), isFalse, reason: '列表吸收裸待办');
      expect(isSafeCut('- a\n[ ] b\nc', 7), isFalse, reason: '待办后的列表项仍被同列表吸收');
    });

    test('开放表格按列数吸收后续行，禁切', () {
      expect(isSafeCut('a | b\n--- | ---\nc | d\ne', 16), isFalse,
          reason: '尾行与前缀末行同含 | → 开放表格吸收');
      expect(isSafeCut('h1 | h2\n--- | ---\n- x | y\nz', 17), isFalse,
          reason: '列表正则可中的行仍被开放表格吸收（管道规则前置裁决）');
      expect(isSafeCut('text\n| a |\n| - |\nz', 5), isTrue, reason: '表格首行前可切');
      expect(isSafeCut('a | b\n--- | ---\n\nplain', 16), isTrue,
          reason: '表格后空行可切');
      expect(isSafeCut('a | b\n--- | ---\nplain', 16), isFalse,
          reason: '表格后直接接普通行：段落合并规则保守禁切');
    });

    test('表格前瞻行未完结禁切（分隔线资格可被撤销）', () {
      expect(isSafeCut('x\n| a |\n| - |', 2), isFalse,
          reason: '分隔线是增长末行 → | - | 可变成 | -x 撤销表格资格');
      expect(isSafeCut('x\n| a |\n| - |\nz', 2), isTrue, reason: '前瞻行完结后可切');
    });

    test('引用定义全文闩锁：出现即禁一切切点', () {
      expect(isSafeCut('a\n\n[ref]: http://x', 2), isFalse, reason: '定义在任何位置都禁切');
      expect(isSafeCut('see [l][ref]\n\n[ref]: http://x', 12), isFalse);
      expect(isSafeCut('a\n\nb', 2), isTrue, reason: '无定义时空行可切（对照）');
    });

    test('非行边界 / 文档头 / 空文本不可切', () {
      expect(isSafeCut('abc', 1), isFalse, reason: '非行边界');
      expect(isSafeCut('abc', 0), isFalse, reason: '文档头');
      expect(isSafeCut('a\nb', 0), isFalse);
      expect(isSafeCut('', 0), isFalse);
    });
  });

  group('禁切规则 load-bearing 反证（P1）', () {
    test('围栏内切点确实产生 AST 分叉', () {
      const text = '```dart\ncode\n```\nx';
      // 切在闭合围栏行前（偏移 13）：前缀围栏未闭合 + 尾包整个闭合行
      expect(isSafeCut(text, 13), isFalse);
      expect(_inc(text, 13), isNot(_full(text)),
          reason: '不切才会分叉——规则不是摆设');
    });

    test('引用续行切点产生分叉', () {
      const text = '> a\n> b';
      expect(_inc(text, 4), isNot(_full(text)));
    });

    test('引用定义切点产生分叉', () {
      const text = 'see [l][ref]\n\n[ref]: http://x';
      expect(_inc(text, 12), isNot(_full(text)),
          reason: '前缀 parse 无定义 → [l][ref] 不解析为链接');
    });

    test('数学块跨度内切点产生分叉', () {
      const text = 'a\n\$\$\nx\n\$\$\nb';
      expect(isSafeCut(text, 5), isFalse, reason: '裸 \$\$ 开后跨度内禁切');
      expect(_inc(text, 5), isNot(_full(text)),
          reason: '前缀数学未闭合降级段落 → 与全文 MathBlock 分叉');
    });
  });

  group('增量 ≡ 全量等价性 fuzz（P1，stream-perf §5 门禁）', () {
    // 语料调色板：覆盖段落/标题/列表/引用/表格/围栏/数学块/媒体/引用定义/未闭合行内。
    const palette = <String>[
      'plain text',
      '## heading two',
      '# big heading',
      '- bullet one',
      '* star bullet',
      '1. ordered one',
      '2. ordered two',
      '[ ] todo open',
      '[x] todo done',
      '> quote line',
      '>> deep quote',
      '```dart',
      '```',
      '~~~',
      '---',
      '***',
      'a | b',
      'h1 | h2',
      '--- | ---',
      'c | d',
      '',
      '  indented continuation',
      '![img](http://e.com/a.png)',
      '[clip](http://e.com/b.mp4)',
      'inline **bold** and `code`',
      'text with | pipe inside',
      '[ref]: http://example.com/r',
      'see [label][ref] usage',
      'unclosed **bold',
      '`unclosed code',
      'trailing text',
      r'$$x = 1$$',
      r'$$ a | b',
      r'$$ math $$',
      r'$$',
      r'x = 1 $$',
      r'text $$ inline $$ more',
    ];

    String genText(Random rnd) {
      final n = 3 + rnd.nextInt(12);
      final lines = [for (var i = 0; i < n; i++) palette[rnd.nextInt(palette.length)]];
      final body = lines.join('\n');
      return rnd.nextBool() ? body : '$body\n';
    }

    test('fuzz A：凡判定安全的切点，parse(前缀)+parse(尾部) ≡ parse(全文)', () {
      var safeCuts = 0;
      for (var seed = 0; seed < 300; seed++) {
        final text = genText(Random(seed));
        final full = _full(text);
        for (final c in _lineStarts(text)) {
          if (!isSafeCut(text, c)) continue;
          safeCuts++;
          expect(_inc(text, c), full,
              reason: 'seed=$seed cut=$c text=<<<$text>>>');
        }
      }
      expect(safeCuts, greaterThan(200), reason: 'fuzz 非空转：安全切点要有足量覆盖');
    });

    test('fuzz B：largestSafeCut(text,0) ≡ 最大安全切点（两实现互锁）', () {
      for (var seed = 0; seed < 300; seed++) {
        final text = genText(Random(seed));
        int? maxSafe;
        for (final c in _lineStarts(text)) {
          if (isSafeCut(text, c)) maxSafe = c;
        }
        expect(largestSafeCut(text, 0), maxSafe, reason: 'seed=$seed text=<<<$text>>>');
      }
    });

    test('fuzz C：逐字流式喂入，每个前缀快照 cache.blocks ≡ 全量 parse', () {
      for (var seed = 0; seed < 120; seed++) {
        final text = genText(Random(seed * 7 + 1));
        final cache = StreamingBlockCache();
        for (var i = 0; i <= text.length; i++) {
          cache.ingest(text.substring(0, i));
          expect(_ser(cache.blocks), _full(text.substring(0, i)),
              reason: 'seed=$seed prefix=$i text=<<<$text>>>');
        }
      }
    });

    test('fuzz D：随机分块喂入（模拟 delta 边界），终态 ≡ 全量 parse', () {
      for (var seed = 0; seed < 120; seed++) {
        final rnd = Random(seed * 13 + 5);
        final text = genText(rnd);
        final cache = StreamingBlockCache();
        var pos = 0;
        while (pos < text.length) {
          final step = 1 + rnd.nextInt(9);
          cache.ingest(text.substring(0, min(pos + step, text.length)));
          pos = min(pos + step, text.length);
          expect(_ser(cache.blocks), _full(text.substring(0, pos)),
              reason: 'seed=$seed pos=$pos text=<<<$text>>>');
        }
        expect(cache.stableLen, greaterThanOrEqualTo(0));
      }
    });

    test('引用定义中途到达：闩锁退化全量，快照恒等价', () {
      const text = 'para one\n\nsee [l][ref] here\n\n[ref]: http://x';
      final cache = StreamingBlockCache();
      for (var i = 0; i <= text.length; i++) {
        cache.ingest(text.substring(0, i));
        expect(_ser(cache.blocks), _full(text.substring(0, i)),
            reason: 'prefix=$i');
      }
      // 定义到达后稳定长度冻结在 0（全量模式）。
      expect(cache.stableLen, 0);
    });

    test('稳定前缀只增不减（切点单调推进）', () {
      const text = '# h\n\np1\n\n- a\n- b\n\n```\nc\n```\n\ntail';
      final cache = StreamingBlockCache();
      var last = 0;
      for (var i = 1; i <= text.length; i++) {
        cache.ingest(text.substring(0, i));
        expect(cache.stableLen, greaterThanOrEqualTo(last), reason: 'prefix=$i');
        last = cache.stableLen;
        expect(_ser(cache.blocks), _full(text.substring(0, i)), reason: 'prefix=$i');
      }
      expect(cache.stableLen, greaterThan(0), reason: '多块文本应产生稳定前缀');
    });
  });

  group('P1 优化效果（机械证明）', () {
    test('流式喂入的解析总量远小于「每 delta 全量重解析」', () {
      final counter = _CountingParser();
      final cache = StreamingBlockCache(parser: counter);
      // 模拟 AI 长回答：多段落 + 列表 + 代码块 + 数学块（~1.4K 字符）。
      const text =
          '# 结论\n\n'
          '第一段正文，包含 **粗体** 与 `行内码`，长度适中便于观察解析量差异。\n\n'
          '- 要点一\n- 要点二\n- 要点三\n\n'
          '```dart\nvoid main() {\n  print("hello");\n}\n```\n\n'
          '第二段正文继续展开说明，\$\$x = y\$\$ 行内数学与普通文字混排。\n\n'
          '> 引用备注一行\n\n'
          '收尾段落。';
      var fullEveryTime = 0;
      for (var i = 1; i <= text.length; i++) {
        cache.ingest(text.substring(0, i));
        fullEveryTime += i; // 全量重解析口径的累计字符量
      }
      expect(_ser(cache.blocks), _full(text), reason: '终态正确性兜底');
      expect(counter.parseCalls, lessThan(text.length + 16),
          reason: '解析调用 ≈ delta 数 + 块数（每块稳定时额外整段解析一次）');
      expect(counter.chars, lessThan(fullEveryTime ~/ 3),
          reason: '增量解析总字符量应低于全量重解析口径的 1/3'
              '（实测 ${counter.chars} / 全量口径 $fullEveryTime）');
    });
  });

  group('widget 行为（P1 渲染隔离）', () {
    Future<void> pump(WidgetTester tester, String text) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: StreamingRichText(text: text))),
        );

    /// 稳定前缀的 RepaintBoundary（限定在 StreamingRichText 子树内——
    /// MaterialApp/Scaffold 框架自带若干 RepaintBoundary，不可全局 find）。
    Finder stableBoundary() => find.descendant(
          of: find.byType(StreamingRichText),
          matching: find.byType(RepaintBoundary),
        );

    testWidgets('稳定/尾块拆分 + RepaintBoundary 隔离', (tester) async {
      await pump(tester, '# 标题\n\n正文开头');
      expect(find.byType(RichTextView), findsNWidgets(2),
          reason: '稳定前缀（标题）+ 活跃尾块（段落）');
      expect(stableBoundary(), findsOneWidget,
          reason: '稳定前缀独立图层，尾块更新不重绘前缀');
      expect(find.textContaining('标题', findRichText: true), findsOneWidget);
      expect(find.textContaining('正文开头', findRichText: true), findsOneWidget);
    });

    testWidgets('尾块增长不重建稳定前缀 widget（实例复用）', (tester) async {
      await pump(tester, '# 标题\n\n正文');
      final stableBefore = tester.widget<RepaintBoundary>(stableBoundary()).child;
      await pump(tester, '# 标题\n\n正文继续写更多');
      final stableAfter = tester.widget<RepaintBoundary>(stableBoundary()).child;
      expect(identical(stableBefore, stableAfter), isTrue,
          reason: '稳定长度未增长 → 缓存 widget 实例跨 build 复用');
      expect(find.textContaining('正文继续写更多', findRichText: true), findsOneWidget);
    });

    testWidgets('新块闭合后稳定前缀推进（缓存失效重建）', (tester) async {
      await pump(tester, '# 标题\n\n正文');
      final stableBefore = tester.widget<RepaintBoundary>(stableBoundary()).child;
      // 空行到达 → 段落闭合入稳定前缀，新尾块开始
      await pump(tester, '# 标题\n\n正文\n\n新段');
      final stableAfter = tester.widget<RepaintBoundary>(stableBoundary()).child;
      expect(identical(stableBefore, stableAfter), isFalse,
          reason: '稳定长度增长 → 渲染缓存失效重建');
      expect(find.byType(RichTextView), findsNWidgets(2));
      expect(find.textContaining('新段', findRichText: true), findsOneWidget);
    });

    testWidgets('单段流式（无稳定前缀）仅一个渲染器', (tester) async {
      await pump(tester, '第一段 ');
      expect(find.byType(RichTextView), findsOneWidget);
      expect(stableBoundary(), findsNothing);
      await pump(tester, '第一段 继续');
      expect(find.byType(RichTextView), findsOneWidget);
      expect(find.text('第一段 继续'), findsOneWidget);
    });

    testWidgets('空文本渲染空占位（不崩）', (tester) async {
      await pump(tester, '');
      expect(find.byType(RichTextView), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('数学块降级渲染（源码 + \$\$ 定界符，不吞内容）', (tester) async {
      await pump(tester, 'a\n\n\$\$x = 1\$\$\n\nb');
      expect(find.text(r'$$x = 1$$'), findsOneWidget);
      expect(find.textContaining('b', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
