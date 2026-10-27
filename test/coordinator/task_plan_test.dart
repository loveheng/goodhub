/// task_plan 单测（多插件任务编排 B1）：提议解析 / 校验三分 / 台账归属 /
/// 配额 / step-id 注入剥离 / 会话级状态机。验收口径 = 设计稿「验收口径」单测节。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/task_plan.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

CloudToolSchema _schema(
  String name, {
  Map<String, Object?>? annotations,
  Map<String, Object?>? properties,
}) =>
    CloudToolSchema(
      name: name,
      description: '',
      parametersSchema: properties == null
          ? const {'type': 'object'}
          : {'type': 'object', 'properties': properties},
      annotations: annotations,
    );

/// 与 PermissionGateway.classify 同口径的写判定（测试内镜像，防误配）。
bool _isWriteTool(String name, Map<String, Object?>? annotations) {
  final destructive = annotations?['destructiveHint'];
  if (destructive is bool && destructive) return true;
  final hint = annotations?['readOnlyHint'];
  if (hint is bool) return !hint;
  return false;
}

PlanFaceContext _face({
  Set<String> mounted = const {'shiguang', 'note', 'book', 'acct', 'privA', 'privB'},
  Set<String> private = const {},
  String? slot,
  Map<String, CloudToolSchema> tools = const {},
  String? Function(String)? availability,
}) =>
    PlanFaceContext(
      mountedServerIds: mounted,
      privateServerIds: private,
      activePrivateSlotId: slot,
      toolOf: (server, tool) => tools['$server|$tool'],
      availabilityIssue: availability,
    );

PlanProposal _proposal(String raw) =>
    PlanProposal.fromArgumentsJson(raw)!;

String _args(String goal, List<Map<String, String>> steps) => json.jsonEncode({
      'goal': goal,
      'steps': steps,
    });

Map<String, CloudToolSchema> _defaultTools() => {
      // shiguang: create_event 写 / list_events 读
      'shiguang|create_event': _schema('create_event',
          annotations: {'readOnlyHint': false}),
      'shiguang|list_events': _schema('list_events',
          annotations: {'readOnlyHint': true}),
      'note|create_note': _schema('create_note',
          annotations: {'readOnlyHint': false}),
      'book|add_bookmark': _schema('add_bookmark',
          annotations: {'readOnlyHint': false}),
      'acct|create_budget': _schema('create_budget',
          annotations: {'readOnlyHint': false}),
      'privA|write_a': _schema('write_a', annotations: {'readOnlyHint': false}),
      'privB|write_b': _schema('write_b', annotations: {'readOnlyHint': false}),
      // 未声明 hints 的工具：按网关口径落 L1（读行，不计写步）
      'shiguang|mystery': _schema('mystery'),
    };

void main() {
  group('提议解析', () {
    test('合法入参解析', () {
      final p = _proposal(_args('云南五日游', [
        {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': '记行程'},
        {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': '存攻略'},
      ]));
      expect(p.goal, '云南五日游');
      expect(p.steps.length, 2);
      expect(p.steps[0].id, 's1');
    });

    for (final (label, raw) in [
      ('非 JSON', 'not-json{'),
      ('goal 缺失', '{"steps":[{"id":"s1","server":"a","tool":"t","intent":"i"}]}'),
      ('goal 空', '{"goal":"  ","steps":[{"id":"s1","server":"a","tool":"t","intent":"i"}]}'),
      ('steps 空', '{"goal":"g","steps":[]}'),
      ('步骤缺字段', '{"goal":"g","steps":[{"id":"s1","server":"a","tool":"t"}]}'),
      ('步骤字段类型错', '{"goal":"g","steps":[{"id":1,"server":"a","tool":"t","intent":"i"}]}'),
    ]) {
      test('畸形入参返 null：$label', () {
        expect(PlanProposal.fromArgumentsJson(raw), isNull);
      });
    }
  });

  group('校验三分', () {
    final face = _face(tools: _defaultTools());

    test('合法跨服务计划通过', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('云南', [
          {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': '行程'},
          {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': '攻略'},
          {'id': 's3', 'server': 'shiguang', 'tool': 'list_events', 'intent': '查日程'},
        ])),
        face: face,
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckOk>());
      final ok = r as PlanCheckOk;
      expect(ok.writeSteps.length, 2);
      expect(ok.readRows.length, 1);
      expect(ok.readRows[0].step.tool, 'list_events');
    });

    test('跨双 private 拒绝并说明单槽纪律', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          {'id': 's1', 'server': 'privA', 'tool': 'write_a', 'intent': 'i'},
          {'id': 's2', 'server': 'privB', 'tool': 'write_b', 'intent': 'i'},
        ])),
        face: _face(
            private: const {'privA', 'privB'}, slot: 'privA', tools: _defaultTools()),
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckRejected>());
      expect((r as PlanCheckRejected).reason, contains('单一槽位'));
    });

    test('激活槽位 private 合规', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          {'id': 's1', 'server': 'privA', 'tool': 'write_a', 'intent': 'i'},
          {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
        ])),
        face: _face(
            private: const {'privA', 'privB'}, slot: 'privA', tools: _defaultTools()),
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckOk>());
    });

    test('未挂载服务拒绝', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          {'id': 's1', 'server': 'ghost', 'tool': 't', 'intent': 'i'},
          {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
        ])),
        face: face,
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckRejected>());
      expect((r as PlanCheckRejected).reason, contains('未挂载'));
    });

    test('未知工具拒绝', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          {'id': 's1', 'server': 'shiguang', 'tool': 'no_such_tool', 'intent': 'i'},
          {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
        ])),
        face: face,
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckRejected>());
      expect((r as PlanCheckRejected).reason, contains('无工具'));
    });

    test('写步超限拒绝并引导拆分', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          for (var i = 0; i < 9; i++)
            {
              'id': 's$i',
              'server': i.isEven ? 'shiguang' : 'note',
              'tool': i.isEven ? 'create_event' : 'create_note',
              'intent': 'i$i',
            },
        ])),
        face: face,
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckRejected>());
      expect((r as PlanCheckRejected).reason, contains('拆分'));
    });

    test('单服务写集降级无需计划', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
          {'id': 's2', 'server': 'shiguang', 'tool': 'list_events', 'intent': 'i'},
        ])),
        face: face,
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckUnnecessary>());
    });

    test('无写步骤降级（含未声明 hints 工具按读分类）', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          {'id': 's1', 'server': 'shiguang', 'tool': 'list_events', 'intent': 'i'},
          {'id': 's2', 'server': 'shiguang', 'tool': 'mystery', 'intent': 'i'},
        ])),
        face: face,
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckUnnecessary>());
      expect((r as PlanCheckUnnecessary).reason, contains('无需计划'));
    });

    test('id 重复拒绝', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
          {'id': 's1', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
        ])),
        face: face,
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckRejected>());
    });

    test('预检置灰（服务离线）不拒绝、行级 blockedReason', () {
      final r = validatePlanProposal(
        proposal: _proposal(_args('g', [
          {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
          {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
        ])),
        face: _face(
            tools: _defaultTools(),
            availability: (s) => s == 'shiguang' ? '服务已离线' : null),
        isWriteTool: _isWriteTool,
      );
      expect(r, isA<PlanCheckOk>());
      final ok = r as PlanCheckOk;
      expect(ok.writeSteps[0].blockedReason, '服务已离线');
      expect(ok.writeSteps[1].blockedReason, isNull);
    });
  });

  group('PlanLedger', () {
    PlanLedger makeLedger() => PlanLedger(steps: [
          const FrozenPlanStep(
              id: 's1', server: 'a', tool: 'w1', intent: 'i1'),
          const FrozenPlanStep(
              id: 's2', server: 'a', tool: 'w1', intent: 'i2'),
          const FrozenPlanStep(
              id: 's3', server: 'b', tool: 'w2', intent: 'i3'),
        ]);

    test('按 id 归属（对匹配）', () {
      final l = makeLedger();
      final hit = l.attribute(serverId: 'a', toolName: 'w1', stepId: 's2')!;
      expect(hit.step.id, 's2');
      expect(hit.inferred, isFalse);
    });

    test('id 对不匹配 → 启发式 inferred', () {
      final l = makeLedger();
      final hit = l.attribute(serverId: 'a', toolName: 'w1', stepId: 's3')!;
      expect(hit.step.id, 's1');
      expect(hit.inferred, isTrue);
    });

    test('缺 id → 同对最早未终态步骤 + inferred', () {
      final l = makeLedger();
      expect(l.attribute(serverId: 'a', toolName: 'w1')!.step.id, 's1');
      // s1 已被剔除 → 启发式跳到 s2
      l.markSkipped('s1');
      expect(l.attribute(serverId: 'a', toolName: 'w1')!.step.id, 's2');
    });

    test('同对全部剔除后调用 = 计划外补调', () {
      final l = makeLedger();
      l.markSkipped('s1');
      l.markSkipped('s2');
      expect(l.attribute(serverId: 'a', toolName: 'w1'), isNull);
      l.recordOutOfBand('a', 'w1');
      expect(l.outOfBandCount('a', 'w1'), 1);
    });

    test('派发与成败聚合：ok×k / failed / pending', () {
      final l = makeLedger();
      final s1 = l.attribute(serverId: 'a', toolName: 'w1', stepId: 's1')!.step;
      final s3 = l.attribute(serverId: 'b', toolName: 'w2', stepId: 's3')!.step;
      l.recordDispatch(s1);
      l.recordResult(s1, isError: false);
      l.recordDispatch(s1);
      l.recordResult(s1, isError: false);
      l.recordDispatch(s1);
      l.recordResult(s1, isError: true);
      final v1 = l.view().firstWhere((v) => v.step.id == 's1');
      expect(v1.calls, 3);
      expect(v1.ok, 2);
      expect(v1.failed, 1);
      expect(v1.statusText, 'ok×2');
      expect(l.view().firstWhere((v) => v.step.id == 's2').statusText, 'pending');
      l.recordDispatch(s3);
      l.recordResult(s3, isError: true);
      expect(
          l.view().firstWhere((v) => v.step.id == 's3').statusText, 'failed');
    });

    test('aggregateStatus 三态（只由写步骤判定）', () {
      final l = makeLedger();
      expect(l.aggregateStatus(), PlanAggregateStatus.failed);
      final s1 = l.attribute(serverId: 'a', toolName: 'w1', stepId: 's1')!.step;
      l.recordDispatch(s1);
      l.recordResult(s1, isError: false);
      expect(l.aggregateStatus(), PlanAggregateStatus.partial);
      final s2 = l.attribute(serverId: 'a', toolName: 'w1', stepId: 's2')!.step;
      final s3 = l.attribute(serverId: 'b', toolName: 'w2', stepId: 's3')!.step;
      l.recordDispatch(s2);
      l.recordResult(s2, isError: false);
      l.recordDispatch(s3);
      l.recordResult(s3, isError: false);
      expect(l.aggregateStatus(), PlanAggregateStatus.completed);
    });

    test('markPendingSkipped：无调用归 skipped、部分完成保留', () {
      final l = makeLedger();
      final s1 = l.attribute(serverId: 'a', toolName: 'w1', stepId: 's1')!.step;
      l.recordDispatch(s1);
      l.recordResult(s1, isError: false);
      l.markPendingSkipped();
      final views = {for (final v in l.view()) v.step.id: v};
      expect(views['s1']!.skipped, isFalse);
      expect(views['s2']!.skipped, isTrue);
      expect(views['s3']!.skipped, isTrue);
    });

    test('snapshotText：收口未执行归待继续、用户剔除归 skipped', () {
      final l = makeLedger();
      final s1 = l.attribute(serverId: 'a', toolName: 'w1', stepId: 's1')!.step;
      l.recordDispatch(s1);
      l.recordResult(s1, isError: false);
      l.markSkipped('s2'); // 用户剔除（毒丸：剔除步重纳入须新卡）
      l.markPendingSkipped(); // 收口：s3 无调用 → 收口未执行
      final text = l.snapshotText('云南五日游');
      expect(text, contains('[计划台账快照] 目标：云南五日游'));
      expect(text, contains('s1 ok×1（已写部分勿重复）'));
      expect(text, contains('s2 skipped（已剔除勿重做）'));
      expect(text, contains('待继续：s3'));
    });
  });

  group('PlanQuota', () {
    test('派发即计数、跨续跑累计（同实例）', () {
      final q = PlanQuota();
      expect(q.register('a', 'w'), 1);
      expect(q.register('a', 'w'), 2);
      expect(q.countOf('a', 'w'), 2);
      expect(q.isOverLimit(2), isFalse);
      expect(q.isOverLimit(q.pairLimit + 1), isTrue);
    });

    test('不同对独立计数', () {
      final q = PlanQuota();
      q.register('a', 'w');
      expect(q.countOf('b', 'w'), 0);
      expect(q.countOf('a', 'w2'), 0);
    });
  });

  group('step-id 注入/剥离', () {
    test('冻结集内注入可选属性、集外与非前缀名恒干净', () {
      final schemas = [
        _schema('a__w1', properties: const {
          'title': {'type': 'string'}
        }),
        _schema('a__w2'),
        _schema('get_connected_apps'),
      ];
      final injected = injectPlanStepIdSchema(
        schemas,
        inFrozenSet: (server, tool) => server == 'a' && tool == 'w1',
      );
      expect(
        injected[0].parametersSchema['properties'],
        containsPair(kPlanStepIdKey, containsPair('type', 'string')),
      );
      // 原 schema 不可变（copy-on-write）
      expect(schemas[0].parametersSchema['properties'],
          isNot(contains(kPlanStepIdKey)));
      expect(injected[1].parametersSchema['properties'] ?? const {},
          isNot(contains(kPlanStepIdKey)));
      expect(injected[2].parametersSchema.containsKey('properties'), isFalse);
    });

    test('strip：有键剥离并回传 id、无键原样透传、畸形 JSON 原样', () {
      final stripped = stripPlanStepId(
          '{"title":"t","$kPlanStepIdKey":"s1","extra":1}');
      expect(stripped.stepId, 's1');
      final decoded = json.jsonDecode(stripped.argumentsJson) as Map;
      expect(decoded.containsKey(kPlanStepIdKey), isFalse);
      expect(decoded['title'], 't');

      expect(stripPlanStepId('{"title":"t"}').stepId, isNull);
      expect(stripPlanStepId('{"title":"t"}').argumentsJson, '{"title":"t"}');
      expect(stripPlanStepId('not-json').argumentsJson, 'not-json');
      // 无计划态误填非字符串 id → 剥离但 stepId 为 null
      final weird = stripPlanStepId('{"$kPlanStepIdKey":42}');
      expect(weird.stepId, isNull);
      expect(json.jsonDecode(weird.argumentsJson), isEmpty);
    });
  });

  group('PlanRunState 会话级状态机', () {
    test('adopt → active；endRun 收口：pending 归 skipped + 聚合卡出口', () {
      var aggregated = 0;
      final state = PlanRunState(onAggregate: (_) => aggregated++);
      state.adoptProposal(
        goal: 'g',
        steps: const [
          FrozenPlanStep(id: 's1', server: 'a', tool: 'w', intent: 'i'),
          FrozenPlanStep(id: 's2', server: 'b', tool: 'w', intent: 'i'),
        ],
      );
      expect(state.isActive, isTrue);
      final s1 = state.ledger!.attribute(serverId: 'a', toolName: 'w', stepId: 's1')!.step;
      state.ledger!.recordDispatch(s1);
      state.ledger!.recordResult(s1, isError: false);
      expect(state.endRun(), isTrue);
      expect(aggregated, 1);
      expect(state.phase, PlanRunPhase.completed);
      final rows = {for (final v in state.ledger!.view()) v.step.id: v};
      expect(rows['s1']!.skipped, isFalse);
      expect(rows['s2']!.skipped, isTrue);
      // 幂等
      expect(state.endRun(), isFalse);
      expect(aggregated, 1);
    });

    test('resume：completed → active + 快照文本', () {
      final state = PlanRunState();
      state.adoptProposal(
        goal: 'g',
        steps: const [
          FrozenPlanStep(id: 's1', server: 'a', tool: 'w', intent: 'i'),
        ],
      );
      state.endRun();
      final snapshot = state.resume();
      expect(snapshot, isNotNull);
      expect(snapshot, contains('[计划台账快照]'));
      expect(state.isActive, isTrue);
    });

    test('beginRun：completed 未续跑（新消息）→ 放弃清空', () {
      final state = PlanRunState();
      state.adoptProposal(
        goal: 'g',
        steps: const [
          FrozenPlanStep(id: 's1', server: 'a', tool: 'w', intent: 'i'),
        ],
      );
      state.endRun();
      state.beginRun();
      expect(state.phase, PlanRunPhase.idle);
      expect(state.ledger, isNull);
      expect(state.isActive, isFalse);
    });

    test('abandon：作废不产生围栏语义', () {
      final state = PlanRunState();
      state.adoptProposal(
        goal: 'g',
        steps: const [
          FrozenPlanStep(id: 's1', server: 'a', tool: 'w', intent: 'i'),
        ],
      );
      state.abandon();
      expect(state.isActive, isFalse);
      expect(state.endRun(), isFalse);
    });

    test('配额跨续跑累计（同 PlanRunState 实例）', () {
      final state = PlanRunState();
      state.quota.register('a', 'w');
      state.adoptProposal(
        goal: 'g',
        steps: const [
          FrozenPlanStep(id: 's1', server: 'a', tool: 'w', intent: 'i'),
        ],
      );
      state.endRun();
      state.resume();
      expect(state.quota.countOf('a', 'w'), 1);
    });
  });
}
