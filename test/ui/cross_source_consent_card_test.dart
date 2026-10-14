/// M3-T4 跨源授权卡组件单测：D5 语义钉子（禁盲签 / 无豁免 / 终态锁定）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/components/cross_source_consent_card.dart';

Widget host(Widget card) => MaterialApp(home: Scaffold(body: card));

void main() {
  testWidgets('正常 preview：允许/拒绝回调触发', (tester) async {
    final decisions = <bool>[];
    await tester.pumpWidget(host(CrossSourceConsentCard(
      handle: r'$ref:goodshare:abc',
      fromServer: 'goodshare',
      toServer: 'todo',
      preview: '会议纪要第一行\n第二行',
      onDecision: decisions.add,
    )));
    expect(find.text('数据摘要：'), findsOneWidget);
    expect(find.text(r'$ref:goodshare:abc'), findsOneWidget);
    await tester.tap(find.text('允许注水'));
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(decisions, [true, false]);
  });

  testWidgets('D5 禁盲签：preview 空 → 允许按钮禁用，拒绝可用', (tester) async {
    final decisions = <bool>[];
    await tester.pumpWidget(host(CrossSourceConsentCard(
      handle: r'$ref:goodshare:abc',
      fromServer: 'goodshare',
      toServer: 'todo',
      preview: '',
      onDecision: decisions.add,
    )));
    expect(find.text('（无预览——禁盲签，不可放行）'), findsOneWidget);
    final allow = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '允许注水'));
    expect(allow.onPressed, isNull, reason: '盲签防线：无预览不可放行');
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(decisions, [false]);
  });

  testWidgets('D5 无豁免：卡内无「记住」类勾选控件', (tester) async {
    await tester.pumpWidget(host(CrossSourceConsentCard(
      handle: r'$ref:goodshare:abc',
      fromServer: 'goodshare',
      toServer: 'todo',
      preview: '内容',
      onDecision: (_) {},
    )));
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('终态锁定：无按钮，锁定文案 + 时间戳（审计感）', (tester) async {
    final at = DateTime.parse('2026-10-11T12:00:00');
    await tester.pumpWidget(host(CrossSourceConsentCard(
      handle: r'$ref:goodshare:abc',
      fromServer: 'goodshare',
      toServer: 'todo',
      preview: '内容',
      lockedDecision: true,
      lockedAt: at,
    )));
    expect(find.text('✓ 已允许注水 · 12:00'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(() => CrossSourceConsentCard(
          handle: 'h',
          fromServer: 'a',
          toServer: 'b',
          preview: 'p',
          lockedDecision: true,
        ), throwsAssertionError, reason: '锁态必须带 lockedAt');
  });
}
