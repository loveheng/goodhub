import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/permission_gateway.dart'
    show GateDecision;
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/ui/components/breaker_card.dart';
import 'package:goodhub/ui/components/call_card.dart';
import 'package:goodhub/ui/components/confirmation_card.dart';
import 'package:goodhub/ui/components/fence_block_card.dart';
import 'package:goodhub/ui/components/status_capsule.dart';
import 'package:goodhub/ui/components/status_strip.dart';
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
    testWidgets('P1-6 白话层：三操作各附后果说明（用户知选哪个、后果是什么）',
        (tester) async {
      await tester.pumpWidget(host(BreakerCard(
        report: const BreakerReport(
          toolName: 'flaky',
          consecutiveFailures: 2,
          lastError: 'ECONNREFUSED',
          argumentsJson: '{}',
        ),
        onBreaker: (_) {},
      )));
      expect(find.textContaining('单步重试 = 原地再试一次'), findsOneWidget);
      expect(find.textContaining('跳过 = 把「出错了」作为结果告诉模型'),
          findsOneWidget);
      expect(find.textContaining('人工接管 = 你直接把正确结果填给模型'),
          findsOneWidget);
    });

    testWidgets('P1-6 白话层：步数墙两操作后果说明', (tester) async {
      await tester.pumpWidget(host(BreakerCard(
        wall: const StepWallReport(turnsUsed: 10, limit: 10),
        onStepWall: (_) {},
      )));
      expect(find.textContaining('放宽 = 再给 10 轮继续尝试'), findsOneWidget);
      expect(find.textContaining('终止 = 就此结束任务'), findsOneWidget);
    });

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

  group('FenceBlockCard（N7 围栏拦截卡，D4）', () {
    testWidgets('交互态：引擎名 + 失败原因 + 双选项，明文发送回传 true', (tester) async {
      bool? sendRaw;
      await tester.pumpWidget(host(FenceBlockCard(
        engineName: 'openai/gpt-4o',
        failureMessage: 'PII 遮蔽超时（3s）',
        onDecision: (v) => sendRaw = v,
      )));
      expect(find.text('PII 围栏拦截'), findsOneWidget);
      expect(find.text('openai/gpt-4o'), findsOneWidget);
      expect(find.textContaining('遮蔽失败：PII 遮蔽超时'), findsOneWidget);

      await tester.tap(find.text('我已知悉，明文发送一次'));
      expect(sendRaw, isTrue);
    });

    testWidgets('取消发送回传 false（围栏拦截生效）', (tester) async {
      bool? sendRaw;
      await tester.pumpWidget(host(FenceBlockCard(
        engineName: 'x',
        failureMessage: 'boom',
        onDecision: (v) => sendRaw = v,
      )));
      await tester.tap(find.text('取消发送'));
      expect(sendRaw, isFalse);
    });

    testWidgets('终态锁定：灰阶文案、无按钮', (tester) async {
      await tester.pumpWidget(host(FenceBlockCard(
        engineName: 'x',
        failureMessage: 'boom',
        lockedSendRaw: true,
        lockedAt: DateTime(2026, 10, 11, 12, 8),
      )));
      expect(find.textContaining('已于 12:08 明文发送一次'), findsOneWidget);
      expect(find.textContaining('不记忆'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
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

  group('StatusStrip（输入条状态带，§3.1）', () {
    test('fmtElapsed：mm:ss 格式化（跨分钟不进小时位）', () {
      expect(StatusStrip.fmtElapsed(DateTime.now()), '00:00');
      expect(
        StatusStrip.fmtElapsed(
            DateTime.now().subtract(const Duration(seconds: 65))),
        '01:05',
      );
      expect(
        StatusStrip.fmtElapsed(
            DateTime.now().subtract(const Duration(minutes: 60))),
        '60:00',
      );
    });

    test('pillText 人话化（P1-6：breaker/fence 去黑话）', () {
      expect(StatusStrip.pillText('breaker'), '工具报错，待处理');
      expect(StatusStrip.pillText('fence'), '敏感信息，待确认');
      expect(StatusStrip.pillText('thinking'), '思考中');
      // 工具名等宽原名透传（不进人话表）。
      expect(StatusStrip.pillText('goodshare::list_items'),
          'goodshare::list_items');
    });

    testWidgets('运行态显示已耗时 + 人话相位（P1-4：_runStartedAt 死代码修复）',
        (tester) async {
      await tester.pumpWidget(host(StatusStrip(
        t: ConsoleTokens.fallback,
        pillTone: CapsuleTone.l1,
        pillLabel: 'thinking',
        running: true,
        runStartedAt: DateTime.now().subtract(const Duration(seconds: 3)),
        contextId: null,
        localPluginCount: 0,
        hasEndpoints: false,
        endpointName: (id) => id,
        onOpenMenu: () {},
      )));
      expect(find.text('思考中'), findsOneWidget,
          reason: 'thinking 人话化——工具结束后的 Run 中相位（P1-4）');
      expect(find.text('00:03'), findsOneWidget, reason: '运行态状态带显示已耗时');
    });

    testWidgets('非运行态无计时；空闲相位人话', (tester) async {
      await tester.pumpWidget(host(StatusStrip(
        t: ConsoleTokens.fallback,
        pillTone: CapsuleTone.idle,
        pillLabel: 'idle',
        running: false,
        runStartedAt: null,
        contextId: null,
        localPluginCount: 0,
        hasEndpoints: false,
        endpointName: (id) => id,
        onOpenMenu: () {},
      )));
      expect(find.text('空闲'), findsOneWidget);
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .toList();
      expect(
        texts.any((t) => t != null && RegExp(r'^\d{2}:\d{2}$').hasMatch(t)),
        isFalse,
        reason: '非运行态不显示计时',
      );
    });
  });

  group('CallCard 终态单行摘要（2026-10-18 压缩 + P0-4/P0-5 修正）', () {
    testWidgets('折叠摘要剥服务端前缀：无描述时不直出 <serverId>__<tool>',
        (tester) async {
      await tester.pumpWidget(host(const CallCard(
        tool: 'goodshare__list_items',
        phase: CallCardPhase.success,
      )));
      expect(find.text('list_items'), findsOneWidget,
          reason: '阅读轨不得出现路由遥测串（ui-design §2 双轨排印）');
      expect(find.text('goodshare__list_items'), findsNothing,
          reason: '折叠态不展示遥测轨原名（点开才见）');
    });

    testWidgets('有描述时摘要取人话首子句', (tester) async {
      await tester.pumpWidget(host(const CallCard(
        tool: 'goodshare__add_item',
        phase: CallCardPhase.success,
        description: '把一段文本或链接存入「拾贝」收集器（例如用户说"帮我存一下"时使用）。',
      )));
      expect(find.text('把一段文本或链接存入「拾贝」收集器'), findsOneWidget);
    });

    // P0-5：成功/失败/中止三态一度同为灰阶，扫读会把「失败」当「已完成」。
    testWidgets('失败/中止摘要取相位色（成功仍灰阶）——§6 双通道', (tester) async {
      final t = ConsoleTokens.fallback;
      Color? summaryColor(String data) =>
          tester.widget<Text>(find.text(data)).style?.color;

      await tester.pumpWidget(host(const CallCard(
        tool: 'delete_item',
        phase: CallCardPhase.success,
      )));
      expect(summaryColor('delete_item'), t.terminalMuted,
          reason: '成功=终态灰阶审计感（既定口径不变）');

      await tester.pumpWidget(host(const CallCard(
        tool: 'delete_item',
        phase: CallCardPhase.failed,
      )));
      expect(summaryColor('delete_item'), t.danger, reason: '失败= Rose 语义色');

      await tester.pumpWidget(host(const CallCard(
        tool: 'delete_item',
        phase: CallCardPhase.cancelled,
      )));
      expect(summaryColor('delete_item'), t.danger, reason: '中止= Rose（≠ Failed 语义仍靠符号 ✕/⊘ 区分）');
    });
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
