/// 任务计划卡组件单测（多插件任务编排 B1，#10 UI 测试）：
/// 确认卡开关 + 单步叮嘱语义 / 读步骤灰行 / 毁坏徽标不配开关 / 预检置灰 /
/// 终态审计行锁定；聚合卡状态语义色 + 续跑按钮状态机 + 逐笔实参摘要；
/// 轨道编解码 round-trip（归档保真）；ChatPlanDelegate 待决挂起语义。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/plan_proposal_tool.dart';
import 'package:goodhub/coordinator/task_plan.dart';
import 'package:goodhub/ui/components/chat_gate_delegates.dart';
import 'package:goodhub/ui/components/dual_track_stream.dart';
import 'package:goodhub/ui/components/status_capsule.dart';
import 'package:goodhub/ui/task_plan_card.dart';
import 'package:goodhub/ui/task_result_card.dart';

Widget host(Widget card) => MaterialApp(home: Scaffold(body: card));

PlanProposalCard _card() => PlanProposalCard(
      goal: '规划云南五日游并落库各插件',
      rows: const [
        PlanStepRow(
          step: PlanProposalStep(
              id: 's1', server: 'shiguang', tool: 'create_event', intent: '记录行程骨架'),
          isWrite: true,
        ),
        PlanStepRow(
          step: PlanProposalStep(
              id: 's2', server: 'note', tool: 'create_note', intent: '攻略要点存笔记'),
          isWrite: true,
        ),
        PlanStepRow(
          step: PlanProposalStep(
              id: 's3', server: 'shiguang', tool: 'delete_all', intent: '清空重来'),
          isWrite: true,
          destructive: true,
        ),
        PlanStepRow(
          step: PlanProposalStep(
              id: 's4', server: 'book', tool: 'add_bookmark', intent: '收藏地址'),
          isWrite: true,
          blockedReason: '服务已离线',
        ),
        PlanStepRow(
          step: PlanProposalStep(
              id: 's5', server: 'shiguang', tool: 'list_events', intent: '查现有日程'),
          isWrite: false,
        ),
      ],
    );

void main() {
  group('TaskPlanCard 确认卡', () {
    testWidgets('步骤行开关默认全开 + 单步叮嘱输入随确认回传', (tester) async {
      PlanProposalDecision? decision;
      await tester.pumpWidget(host(TaskPlanCard(
        plan: _card(),
        onDecision: (d) => decision = d,
      )));
      expect(find.text('规划云南五日游并落库各插件'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(3),
          reason: '仅非毁坏、非置灰写步骤有开关（s1/s2；s3 毁坏、s4 置灰）');
      // 展开 s1 叮嘱并输入
      final s1Area = find.text('shiguang__create_event');
      expect(s1Area, findsOneWidget);
      await tester.tap(find.text('＋叮嘱').first);
      await tester.pump();
      await tester.enterText(
          find.byType(TextField), '按穷游标准、上限 3000');
      await tester.tap(find.text('确认执行'));
      await tester.pump();
      expect(decision, isNotNull);
      expect(decision!.approved, isTrue);
      expect(decision!.approvals.map((a) => a.stepId), ['s1', 's2']);
      expect(decision!.approvals[0].note, '按穷游标准、上限 3000');
      expect(decision!.approvals[1].note, isNull);
    });

    testWidgets('单项剔除：开关关 → 不入 approvals（user_skipped 语义）',
        (tester) async {
      PlanProposalDecision? decision;
      await tester.pumpWidget(host(TaskPlanCard(
        plan: _card(),
        onDecision: (d) => decision = d,
      )));
      await tester.tap(find.byType(Switch).first); // s1 关
      await tester.pump();
      await tester.tap(find.text('确认执行'));
      await tester.pump();
      expect(decision!.approvals.map((a) => a.stepId), ['s2'],
          reason: '毁坏步不入批量授权（D1）');
      expect(
        TaskPlanCard.lockedSummaryFor(decision!, writeCount: 3, destructiveCount: 1),
        contains('毁坏 1 项逐条确认'),
      );
    });

    testWidgets('毁坏步骤：无开关 + 危险徽标 + 逐条确认标注（D1）', (tester) async {
      await tester.pumpWidget(host(TaskPlanCard(
        plan: _card(),
        onDecision: (_) {},
      )));
      expect(find.text('毁坏'), findsOneWidget);
      expect(find.text('执行时逐条确认'), findsOneWidget);
    });

    testWidgets('预检置灰：开关禁用 + 置灰原因行（R6 起草期）', (tester) async {
      await tester.pumpWidget(host(TaskPlanCard(
        plan: _card(),
        onDecision: (_) {},
      )));
      expect(find.textContaining('服务已离线'), findsOneWidget);
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      final disabled = switches.where((s) => s.onChanged == null);
      expect(disabled, hasLength(1),
          reason: '置灰步开关禁用（不可授权），其余写步开关可用');
    });

    testWidgets('读信息行：静态灰阶、无开关', (tester) async {
      await tester.pumpWidget(host(TaskPlanCard(
        plan: _card(),
        onDecision: (_) {},
      )));
      expect(find.textContaining('[只读] shiguang__list_events'), findsOneWidget);
    });

    testWidgets('取消：approved=false 全作废', (tester) async {
      PlanProposalDecision? decision;
      await tester.pumpWidget(host(TaskPlanCard(
        plan: _card(),
        onDecision: (d) => decision = d,
      )));
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(decision!.approved, isFalse);
    });

    testWidgets('终态锁定：审计行 + 无开关无按钮', (tester) async {
      await tester.pumpWidget(host(TaskPlanCard(
        plan: _card(),
        lockedSummary: '✓ 已批准 2 项 · 剔除 1 项 · 12:30',
        lockedAt: DateTime.parse('2026-10-24T12:30:00'),
      )));
      expect(find.textContaining('已批准 2 项'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('确认执行'), findsNothing);
    });
  });

  group('TaskResultCard 聚合卡', () {
    PlanAggregateRecord makeRecord(PlanAggregateStatus status) =>
        PlanAggregateRecord(
          goal: '规划云南五日游并落库各插件',
          status: status,
          rows: const [
            PlanLedgerStepView(
              step: FrozenPlanStep(
                  id: 's1', server: 'shiguang', tool: 'create_event', intent: '记行程'),
              calls: 3,
              ok: 3,
              failed: 0,
              skippedByUser: false,
            ),
            PlanLedgerStepView(
              step: FrozenPlanStep(
                  id: 's2', server: 'note', tool: 'create_note', intent: '存攻略'),
              calls: 0,
              ok: 0,
              failed: 0,
              skippedByUser: false,
              closedPending: true,
            ),
          ],
          outOfBand: const {'shiguang|create_event': 1},
          echoByStep: const {
            's1': '[s1] shiguang__create_event ← title=D1',
          },
        );

    testWidgets('部分完成：琥珀语义 + 续跑按钮在位', (tester) async {
      var resumed = false;
      await tester.pumpWidget(host(TaskResultCard(
        record: makeRecord(PlanAggregateStatus.partial),
        onResume: () => resumed = true,
      )));
      expect(find.text('部分完成'), findsOneWidget);
      expect(find.textContaining('计划外补调 1 次'), findsOneWidget);
      expect(find.textContaining('配额上限'), findsOneWidget);
      expect(find.text('[s1]'), findsOneWidget);
      expect(find.textContaining('← title=D1'), findsOneWidget);
      await tester.tap(find.text('续跑（补剩余步骤）'));
      await tester.pump();
      expect(resumed, isTrue);
    });

    testWidgets('完成态：不渲染续跑按钮（无剩余可补）', (tester) async {
      await tester.pumpWidget(host(TaskResultCard(
        record: makeRecord(PlanAggregateStatus.completed),
        onResume: () {},
      )));
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('续跑（补剩余步骤）'), findsNothing);
    });

    testWidgets('历史恢复态：onResume null → 无按钮（锁定回看）', (tester) async {
      await tester.pumpWidget(host(TaskResultCard(
        record: makeRecord(PlanAggregateStatus.failed),
      )));
      expect(find.text('失败'), findsOneWidget);
      expect(find.text('续跑（补剩余步骤）'), findsNothing);
    });
  });

  group('轨道编解码（归档保真）', () {
    test('plan_result round-trip：台账/配额外补调/实参摘要保真，onResume 锁定',
        () async {
      final entry = TrackPlanResult(
        record: PlanAggregateRecord(
          goal: 'g',
          status: PlanAggregateStatus.partial,
          rows: const [
            PlanLedgerStepView(
              step: FrozenPlanStep(
                  id: 's1', server: 'a', tool: 'w', intent: 'i', note: '按穷游标准'),
              calls: 2,
              ok: 2,
              failed: 0,
              skippedByUser: false,
            ),
          ],
          outOfBand: const {'a|w': 1},
          echoByStep: const {
            's1': '[s1] a__w ← x=1 ｜ 叮嘱：按穷游标准',
          },
        ),
      );
      final encoded = TrackEntryCodec.encode([entry]);
      final decoded = TrackEntryCodec.decode(encoded);
      final restored = decoded.single as TrackPlanResult;
      expect(restored.record.goal, 'g');
      expect(restored.record.status, PlanAggregateStatus.partial);
      expect(restored.record.rows.single.step.note, '按穷游标准');
      expect(restored.record.rows.single.ok, 2);
      expect(restored.record.rows.single.closedPending, isFalse);
      expect(restored.record.outOfBand['a|w'], 1);
      expect(restored.record.echoByStep['s1'], contains('叮嘱'));
      expect(restored.onResume, isNull, reason: '历史恢复态锁定（不可续跑）');
    });

    test('plan_confirm 已决策 → 审计通告行恢复（计划原文随 encode）', () {
      final entry = TrackPlanConfirm(card: _card())
        ..decision = const PlanProposalDecision(approved: true, approvals: [
          PlanStepApproval(stepId: 's1'),
          PlanStepApproval(stepId: 's2'),
        ])
        ..decidedAt = DateTime.parse('2026-10-24T12:30:00')
        ..lockedSummary = '✓ 已批准 2 项 · 剔除 1 项 · 12:30';
      final encoded = TrackEntryCodec.encode([entry]);
      expect((encoded.single as Map)['goal'], contains('云南五日游'));
      expect(((encoded.single as Map)['rows'] as List).length, 5);
      final decoded = TrackEntryCodec.decode(encoded);
      expect(decoded.single, isA<TrackNote>());
      expect((decoded.single as TrackNote).text, contains('已批准 2 项'));
    });
  });

  group('ChatPlanDelegate', () {
    test('待决挂起：插轨道条目 + completer 随裁决完成', () async {
      final added = <TrackEntry>[];
      final delegate = ChatPlanDelegate(_FakeSink(added));
      final future = delegate.confirmPlan(_card());
      final entry = added.single as TrackPlanConfirm;
      expect(entry.completer.isCompleted, isFalse);
      entry.decision = const PlanProposalDecision(approved: true, approvals: [
        PlanStepApproval(stepId: 's1'),
      ]);
      entry.completer.complete(entry.decision!);
      final decision = await future;
      expect(decision.approved, isTrue);
      expect(decision.approvals.single.stepId, 's1');
    });
  });
}

class _FakeSink implements ChatTrackSink {
  _FakeSink(this.added);

  final List<TrackEntry> added;

  @override
  void addTrack(TrackEntry entry) => added.add(entry);

  @override
  void setPill(String label, CapsuleTone tone) {}
}
