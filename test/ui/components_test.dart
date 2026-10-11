import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/permission_gateway.dart'
    show GateDecision;
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/ui/components/breaker_card.dart';
import 'package:goodhub/ui/components/confirmation_card.dart';
import 'package:goodhub/ui/components/fence_block_card.dart';
import 'package:goodhub/ui/components/status_capsule.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

Widget host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, extensions: const [ConsoleTokens.fallback]),
      home: Scaffold(body: ListView(children: [child])),
    );

GateDecision? captured;
void onDecision(GateDecision d) => captured = d;

void main() {
  setUp(() => captured = null);

  group('ConfirmationCard（L2 确认卡）', () {
    testWidgets('交互态：工具名 + 参数区 + 豁免勾选，确认回传 rememberSession', (tester) async {
      await tester.pumpWidget(host(ConfirmationCard(
        toolName: 'update_item',
        argumentsJson: '{"id":"n1","title":"新标题"}',
        onDecision: onDecision,
      )));
      expect(find.text('update_item'), findsOneWidget);
      expect(find.text('入参 (2)'), findsOneWidget);
      expect(find.text('确认执行'), findsOneWidget);

      await tester.tap(find.text('本会话记住该工具（会话结束/中止即失效）'));
      await tester.tap(find.text('确认执行'));
      expect(captured!.approved, isTrue);
      expect(captured!.rememberSession, isTrue);
    });

    testWidgets('拒绝带理由回传 reason', (tester) async {
      await tester.pumpWidget(host(ConfirmationCard(
        toolName: 'delete_item',
        argumentsJson: '{"id":"n1"}',
        onDecision: onDecision,
      )));
      await tester.enterText(
          find.widgetWithText(TextField, '拒绝理由（可空，将回传模型原地修正）'), '先别删');
      await tester.tap(find.text('拒绝'));
      expect(captured!.approved, isFalse);
      expect(captured!.reason, '先别删');
    });

    testWidgets('终态锁定：灰阶文案、无按钮', (tester) async {
      await tester.pumpWidget(host(ConfirmationCard(
        toolName: 'delete_item',
        argumentsJson: '{}',
        lockedDecision: const GateDecision(approved: false, reason: '不行'),
        lockedAt: DateTime(2026, 10, 11, 10, 42),
      )));
      expect(find.text('✕ 已拒绝（原因：不行）'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('BreakerCard（排查卡）', () {
    testWidgets('熔断态：错误摘要 + 单步重试/跳过/人工接管三操作', (tester) async {
      Object? resolution;
      await tester.pumpWidget(host(BreakerCard(
        report: const BreakerReport(
          toolName: 'flaky',
          consecutiveFailures: 2,
          lastError: 'ECONNREFUSED',
          argumentsJson: '{}',
        ),
        onBreaker: (r) => resolution = r,
      )));
      expect(find.text('flaky 连续 2 次报错'), findsOneWidget);
      expect(find.textContaining('ECONNREFUSED'), findsOneWidget);

      await tester.tap(find.text('跳过'));
      expect(resolution, isA<SkipOnce>());

      await tester.tap(find.text('单步重试'));
      expect(resolution, isA<RetryOnce>());
    });

    testWidgets('人工接管：展开输入框，提交 ManualResult', (tester) async {
      Object? resolution;
      await tester.pumpWidget(host(BreakerCard(
        report: const BreakerReport(
          toolName: 'flaky',
          consecutiveFailures: 2,
          lastError: 'x',
          argumentsJson: '{}',
        ),
        onBreaker: (r) => resolution = r,
      )));
      await tester.tap(find.text('人工接管'));
      await tester.pump();
      await tester.enterText(
          find.widgetWithText(TextField, '人工结果（将以正常数据回填模型）'), '人工查到的答案');
      await tester.tap(find.text('提交结果'));
      expect(resolution, isA<ManualResult>());
      expect((resolution! as ManualResult).text, '人工查到的答案');
    });

    testWidgets('步数墙态：放宽 +10 / 终止', (tester) async {
      bool? relax;
      await tester.pumpWidget(host(BreakerCard(
        wall: const StepWallReport(turnsUsed: 10, limit: 10),
        onStepWall: (r) => relax = r,
      )));
      expect(find.textContaining('连续 10 轮'), findsOneWidget);
      await tester.tap(find.text('放宽 +10 续跑'));
      expect(relax, isTrue);
      await tester.tap(find.text('终止'));
      expect(relax, isFalse);
    });

    testWidgets('终态锁定：文案 + 无按钮', (tester) async {
      await tester.pumpWidget(host(BreakerCard(
        wall: const StepWallReport(turnsUsed: 10, limit: 10),
        lockedText: '⤒ 已放宽 +10 续跑',
        lockedAt: DateTime(2026, 10, 11, 11, 5),
      )));
      expect(find.textContaining('已放宽 +10 续跑'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  testWidgets('StatusCapsule：等宽标签 + 语义色点', (tester) async {
    await tester.pumpWidget(host(const Column(
      children: [
        StatusCapsule(label: 'goodshare::list_items', tone: CapsuleTone.l1),
        StatusCapsule(label: 'failed', tone: CapsuleTone.danger),
      ],
    )));
    expect(find.text('goodshare::list_items'), findsOneWidget);
    expect(find.text('failed'), findsOneWidget);
  });

  test('ConsoleTokens：语义色与基础 token 固定值', () {
    const t = ConsoleTokens.fallback;
    expect(t.l1Ok, const Color(0xFF34D399)); // Emerald 400
    expect(t.l2Warn, const Color(0xFFF59E0B)); // Amber 500
    expect(t.danger, const Color(0xFFF43F5E)); // Rose 500
    expect(t.cardRadius, 10);
    expect(t.fastDuration, const Duration(milliseconds: 180));
    expect(t.monoFamily, 'monospace');
  });
}
