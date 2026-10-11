import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/ui/components/breaker_card.dart';
import 'package:goodhub/ui/components/call_card.dart';
import 'package:goodhub/ui/components/dual_track_stream.dart';
import 'package:goodhub/ui/rich_text_view.dart';

void main() {
  Future<void> pump(WidgetTester tester, List<TrackEntry> entries,
          {String emptyHint = ''}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DualTrackStream(entries: entries, emptyHint: emptyHint),
        ),
      ));

  testWidgets('事件→轨道映射：用户轮/执行卡终态/通告/空提示缺席', (tester) async {
    await pump(tester, [
      const TrackUser('把行动项写进 todo'),
      TrackCall(tool: 'list_items')
        ..phase = CallCardPhase.success
        ..preview = 'r1 ⏎ r2',
      const TrackNote('✓ 收尾（1 轮）', danger: false),
    ]);

    expect(find.text('把行动项写进 todo'), findsOneWidget);
    expect(find.text('你'), findsOneWidget, reason: '用户轮次标签（D9 同轴卡片族）');
    expect(find.byType(CallCard), findsOneWidget);
    expect(find.text('r1 ⏎ r2'), findsOneWidget, reason: '终态预览');
    expect(find.text('✓ 收尾（1 轮）'), findsOneWidget);
  });

  testWidgets('Abort 终态：cancelled 相位呈现（区别 Failed，architecture §10）',
      (tester) async {
    await pump(tester, [
      TrackCall(tool: 'add_item')
        ..phase = CallCardPhase.cancelled
        ..progressNote = '已中止（在途调用结果仍会回填）',
    ]);
    expect(find.text('已中止（在途调用结果仍会回填）'), findsOneWidget);
    expect(find.byType(CallCard), findsOneWidget);
  });

  testWidgets('阅读轨经 RichTextView 渲染 Markdown（D12 自写方案）', (tester) async {
    final text = TrackText('');
    text.text.write('# 结论\n\n**要点** 与 `code`');
    await pump(tester, [text]);
    expect(find.byType(RichTextView), findsOneWidget);
    expect(find.text('结论'), findsOneWidget);
    expect(find.text('要点'), findsOneWidget);
    expect(find.text('code'), findsOneWidget);
  });

  testWidgets('空轨道出提示；流式追加复用同一条目（不碎卡）', (tester) async {
    await pump(tester, const [], emptyHint: '下达任务');
    expect(find.text('下达任务'), findsOneWidget);

    final text = TrackText('');
    final entries = <TrackEntry>[text];
    await pump(tester, entries);
    text.text.write('第一段 ');
    await pump(tester, entries);
    expect(find.text('第一段 '), findsOneWidget);
    expect(find.byType(RichTextView), findsOneWidget,
        reason: '同一 TrackText 重建单组件——流式不新增轨道条目');
  });

  testWidgets('TrackBreaker/TrackFence 渲染（排查卡/围栏卡内嵌）', (tester) async {
    await pump(tester, [
      TrackBreaker.breaker(BreakerReport(
        toolName: 'add_item',
        consecutiveFailures: 2,
        lastError: 'boom',
        argumentsJson: '{}',
      )),
    ]);
    expect(find.byType(BreakerCard), findsOneWidget);
    expect(find.textContaining('add_item'), findsWidgets);
  });
}
