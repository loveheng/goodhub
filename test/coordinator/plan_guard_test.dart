/// plan_guard + plan_proposal_tool 单测（多插件任务编排 B1）。
/// 覆盖设计稿验收口径：围栏两段四分支 + 读直通 / step-id 注入归属剥离 /
/// 同批伴随写 deferred（顺序无关）/ 配额派发即计超限引导 / 台账聚合 /
/// 计划外补调 / 拒绝文案三段式 / 提议回填（确认·取消·user_note 透传·
/// 单服务降级·畸形·headless fail-closed）/ grant 作用域。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/plan_guard.dart';
import 'package:goodhub/coordinator/plan_proposal_tool.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/task_plan.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/coordinator/tool_router.dart';
import 'package:goodhub/mcp/mcp_client.dart';

McpClient _dummyClient() {
  final mock = MockClient((_) async => http.Response(
      json.jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': {}}),
      200,
      headers: {'content-type': 'application/json'}));
  return McpClient.http(baseUrl: 'http://fake', httpClient: mock);
}

/// 仅提供 canned schema，不触网（绕过 McpToolFace 真实传输）。
class _StubFace extends McpToolFace {
  _StubFace(this._schemas, {required super.serverId})
      : super(client: _dummyClient());

  final List<CloudToolSchema> _schemas;

  @override
  List<CloudToolSchema> get cachedSchemas => List.unmodifiable(_schemas);
}

bool _isWriteTool(String name, Map<String, Object?>? annotations) {
  final destructive = annotations?['destructiveHint'];
  if (destructive is bool && destructive) return true;
  final hint = annotations?['readOnlyHint'];
  if (hint is bool) return !hint;
  return false;
}

class _RecordingExecutor implements ToolExecutor {
  final List<AssembledToolCall> calls = [];
  ToolExecutionResult Function(AssembledToolCall)? onExecute;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    calls.add(call);
    return onExecute?.call(call) ??
        const ToolExecutionResult(content: '{"ok":true}');
  }
}

class _FakePlanDelegate implements PlanProposalDelegate {
  _FakePlanDelegate(this.decision);

  final PlanProposalDecision decision;
  final List<PlanProposalCard> cards = [];

  @override
  Future<PlanProposalDecision> confirmPlan(PlanProposalCard card) async {
    cards.add(card);
    return decision;
  }
}

final Map<String, Map<String, Object?>?> _catalog = {
  'shiguang__create_event': {'readOnlyHint': false},
  'shiguang__list_events': {'readOnlyHint': true},
  'note__create_note': {'readOnlyHint': false},
  'shiguang__delete_all': {'destructiveHint': true},
  'ghost__write': {'readOnlyHint': false},
};

AssembledToolCall _call(String name, {String args = '{}', String id = 'c1'}) =>
    AssembledToolCall(id: id, name: name, argumentsJson: args);

PlanRunState _state({PlanQuota? quota}) {
  final s = PlanRunState(quota: quota);
  s.adoptProposal(goal: '云南五日游', steps: const [
    FrozenPlanStep(id: 's1', server: 'shiguang', tool: 'create_event', intent: '行程'),
    FrozenPlanStep(id: 's2', server: 'note', tool: 'create_note', intent: '攻略'),
    FrozenPlanStep(id: 's3', server: 'shiguang', tool: 'delete_all', intent: '清空'),
  ]);
  return s;
}

PlanGuard _guard(_RecordingExecutor inner, PlanRunState state,
        {void Function(String)? onEcho}) =>
    PlanGuard(
      inner: inner,
      state: state,
      isWriteTool: _isWriteTool,
      annotationsFor: (name) => _catalog[name],
      onStepEcho: onEcho,
    );

void main() {
  group('PlanGuard 围栏', () {
    test('L1 只读直通（不进台账）', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      final r = await _guard(inner, state)
          .execute(_call('shiguang__list_events', args: '{"day":1}'));
      expect(inner.calls.length, 1);
      expect(r.isError, isFalse);
      expect(state.ledger!.view().every((v) => v.calls == 0), isTrue);
    });

    test('宿主本地工具（无前缀）直通', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      await _guard(inner, state).execute(_call('memory_save'));
      expect(inner.calls.length, 1);
    });

    test('phase-0（总管模式武装）：L2 写拒绝并引导提议，不达 inner', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState()..armed = true;
      final r = await _guard(inner, state).execute(_call('shiguang__create_event'));
      expect(r.isError, isTrue);
      expect(r.content, contains('[PLAN_REQUIRED]'));
      expect(r.content, contains('propose_task_plan'));
      expect(inner.calls, isEmpty);
    });

    test('phase-0 专科模式（未武装）：L2 写直通（既有网关轻确认）', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState();
      await _guard(inner, state).execute(_call('shiguang__create_event'));
      expect(inner.calls.length, 1);
    });

    test('同批伴随写 deferred（propose 先序：标志已登记）', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState()..armed = true;
      final guard = _guard(inner, state);
      state.markProposalPending(); // propose 拦截的同步前缀
      final r = await guard.execute(_call('shiguang__create_event'));
      expect(r.isError, isFalse);
      expect(json.jsonDecode(r.content)['status'], 'deferred_to_plan');
      expect(inner.calls, isEmpty);
    });

    test('同批伴随写 deferred（写先序：单跳让位后命中标志）', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState()..armed = true;
      final guard = _guard(inner, state);
      final future = guard.execute(_call('shiguang__create_event'));
      // 让位窗口内：同批 propose 的同步前缀登记标志（列表构造序）
      state.markProposalPending();
      final r = await future;
      expect(json.jsonDecode(r.content)['status'], 'deferred_to_plan');
      expect(inner.calls, isEmpty);
    });

    test('phase-1 冻结集内非毁坏：放行 + step-id 剥离 + 台账聚合', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      final echoes = <String>[];
      final guard = _guard(inner, state, onEcho: echoes.add);
      final r = await guard.execute(_call('shiguang__create_event',
          args: '{"title":"D1","$kPlanStepIdKey":"s1"}'));
      expect(r.isError, isFalse);
      expect(inner.calls.single.argumentsJson, contains('D1'));
      expect(inner.calls.single.argumentsJson.contains(kPlanStepIdKey), isFalse);
      final s1 = state.ledger!.view().firstWhere((v) => v.step.id == 's1');
      expect(s1.calls, 1);
      expect(s1.ok, 1);
      expect(s1.statusText, 'ok×1');
      expect(state.quota.countOf('shiguang', 'create_event'), 1);
      expect(state.stepEchoes['s1'], contains('[s1]'));
      expect(echoes.single, contains('[s1]'));
    });

    test('phase-1 缺 step-id：启发式归属 + inferred 标记', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      await _guard(inner, state).execute(_call('shiguang__create_event'));
      expect(state.stepEchoes['s1'], contains('（推断归属）'));
    });

    test('phase-1 无效 step-id：启发式兜底不误归属', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      await _guard(inner, state).execute(_call('shiguang__create_event',
          args: '{"$kPlanStepIdKey":"s9"}'));
      expect(state.stepEchoes['s1'], isNotNull);
    });

    test('phase-1 毁坏性 ∈ 集：照常放行至网关（逐条实参级 L2，D1 在网关侧）', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      final r = await _guard(inner, state).execute(_call('shiguang__delete_all'));
      expect(inner.calls.length, 1);
      expect(state.ledger!.view().firstWhere((v) => v.step.id == 's3').calls, 1);
      expect(r.isError, isFalse);
    });

    test('phase-1 ∉ 冻结集：三段式终结拒绝（isError 计熔断）', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      final r = await _guard(inner, state).execute(_call('ghost__write'));
      expect(r.isError, isTrue);
      expect(r.content, contains('[FATAL_PERMISSION_DENIED] ghost__write'));
      expect(r.content, contains('不在已确认计划内'));
      expect(r.content, contains('严禁重试'));
      expect(inner.calls, isEmpty);
    });

    test('phase-1 同对全部剔除：记录计划外补调 + 拒绝', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      state.ledger!.markSkipped('s1');
      state.ledger!.markSkipped('s3'); // 同对 shiguang|create_event / delete_all 不同对——s1 是 create_event 唯一步
      final r = await _guard(inner, state).execute(_call('shiguang__create_event'));
      expect(r.isError, isTrue);
      expect(r.content, contains('用户已在计划卡剔除'));
      expect(state.ledger!.outOfBandCount('shiguang', 'create_event'), 1);
      expect(inner.calls, isEmpty);
    });

    test('配额：派发即计数、成败均计、超限附引导注记', () async {
      final inner = _RecordingExecutor();
      final state = _state(quota: PlanQuota(pairLimit: 2));
      final guard = _guard(inner, state);
      for (var i = 0; i < 2; i++) {
        await guard.execute(_call('shiguang__create_event', id: 'c$i'));
      }
      expect(state.quota.countOf('shiguang', 'create_event'), 2);
      final r = await guard.execute(_call('shiguang__create_event', id: 'c3'));
      expect(r.content, contains('配额上限 2'));
      expect(r.isError, isFalse); // 软上限：执行照常
      inner.onExecute =
          (call) => const ToolExecutionResult(content: 'x', isError: true);
      await guard.execute(_call('shiguang__create_event', id: 'c4'));
      expect(state.quota.countOf('shiguang', 'create_event'), 4); // 失败也计
    });

    test('跨续跑累计：resume 后同实例配额不重置', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      await _guard(inner, state).execute(_call('shiguang__create_event'));
      state.endRun();
      state.resume();
      expect(state.quota.countOf('shiguang', 'create_event'), 1);
      expect(state.isActive, isTrue);
    });
  });

  group('PlanProposalTool', () {
    final router = _fakeRouter();

    PlanProposalTool makeTool(
      _RecordingExecutor inner,
      PlanRunState state, {
      PlanProposalDelegate? delegate,
      String? Function(String)? availability,
    }) =>
        PlanProposalTool(
          inner: inner,
          router: router,
          state: state,
          isWriteTool: _isWriteTool,
          delegate: delegate,
          availabilityIssue: availability,
        );

    test('合法提议 → 确认 → adopt + approved 回填 + user_note 透传', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState();
      final delegate = _FakePlanDelegate(const PlanProposalDecision(
        approved: true,
        approvals: [
          PlanStepApproval(stepId: 's1', note: '按穷游标准'),
          PlanStepApproval(stepId: 's2'),
        ],
      ));
      final tool = makeTool(inner, state, delegate: delegate);
      final r = await tool.execute(_call('propose_task_plan',
          args: json.jsonEncode({
            'goal': '云南五日游',
            'steps': [
              {
                'id': 's1',
                'server': 'shiguang',
                'tool': 'create_event',
                'intent': '记行程'
              },
              {
                'id': 's2',
                'server': 'note',
                'tool': 'create_note',
                'intent': '存攻略'
              },
              {
                'id': 's3',
                'server': 'shiguang',
                'tool': 'list_events',
                'intent': '查日程'
              },
            ],
          })));
      expect(r.isError, isFalse);
      final body = json.jsonDecode(r.content) as Map;
      expect(body['status'], 'approved');
      expect((body['plan'] as List).length, 2);
      expect(body['plan'][0]['user_note'], '按穷游标准');
      expect((body['skipped'] as List), isEmpty);
      expect(state.isActive, isTrue);
      expect(
        state.frozenSteps.map((f) => f.id),
        ['s1', 's2'],
      ); // 读步不入冻结集
      expect(delegate.cards.single.rows.length, 3); // 读行进卡面
      expect(state.proposalPending, isFalse);
    });

    test('取消 → abandon + user_rejected（计划与同批写作废）', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState();
      final tool = makeTool(inner, state,
          delegate: _FakePlanDelegate(const PlanProposalDecision(approved: false)));
      final r = await tool.execute(_call('propose_task_plan',
          args: json.jsonEncode({
            'goal': 'g',
            'steps': [
              {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
              {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
            ],
          })));
      expect(r.isError, isFalse);
      expect(json.jsonDecode(r.content)['status'], 'user_rejected');
      expect(state.isActive, isFalse);
      expect(state.proposalPending, isFalse);
    });

    test('畸形入参 isError 引导', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState();
      final tool = makeTool(inner, state);
      final r = await tool.execute(_call('propose_task_plan', args: 'bad'));
      expect(r.isError, isTrue);
    });

    test('单服务写集自动降级（无需计划，零 UI）', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState();
      final delegate = _FakePlanDelegate(const PlanProposalDecision(approved: true));
      final tool = makeTool(inner, state, delegate: delegate);
      final r = await tool.execute(_call('propose_task_plan',
          args: json.jsonEncode({
            'goal': 'g',
            'steps': [
              {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
              {'id': 's2', 'server': 'shiguang', 'tool': 'list_events', 'intent': 'i'},
            ],
          })));
      expect(r.isError, isFalse);
      expect(r.content, contains('无需计划'));
      expect(delegate.cards, isEmpty);
      expect(state.isActive, isFalse);
    });

    test('headless 无确认界面恒拒绝（fail-closed）', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState();
      final tool = makeTool(inner, state);
      final r = await tool.execute(_call('propose_task_plan',
          args: json.jsonEncode({
            'goal': 'g',
            'steps': [
              {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
              {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
            ],
          })));
      expect(r.isError, isTrue);
      expect(state.isActive, isFalse);
    });

    test('计划执行中重复提议 → 引导不弹卡', () async {
      final inner = _RecordingExecutor();
      final state = _state();
      final delegate = _FakePlanDelegate(const PlanProposalDecision(approved: true));
      final tool = makeTool(inner, state, delegate: delegate);
      final r = await tool.execute(_call('propose_task_plan',
          args: json.jsonEncode({
            'goal': 'g',
            'steps': [
              {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
              {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
            ],
          })));
      expect(r.isError, isFalse);
      expect(r.content, contains('计划执行中'));
      expect(delegate.cards, isEmpty);
    });

    test('二次校验（TOCTOU）：起草后掉线 → 确认时置 failed 不入 grant', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState();
      final delegate = _FakePlanDelegate(const PlanProposalDecision(
        approved: true,
        approvals: [
          PlanStepApproval(stepId: 's1'),
          PlanStepApproval(stepId: 's2'),
        ],
      ));
      var noteOffline = false;
      final tool = makeTool(inner, state, delegate: delegate,
          availability: (id) => noteOffline && id == 'note' ? '服务已离线' : null);
      final r = await tool.execute(_call('propose_task_plan',
          args: json.jsonEncode({
            'goal': 'g',
            'steps': [
              {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
              {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
            ],
          })));
      expect(r.isError, isFalse);
      final body = json.jsonDecode(r.content) as Map;
      expect((body['plan'] as List).length, 2); // 起草期两步都就绪
      // 起草后掉线：确认手势那一刻二次校验
      noteOffline = true;
      state.abandon();
      final r2 = await tool.execute(_call('propose_task_plan',
          args: json.jsonEncode({
            'goal': 'g',
            'steps': [
              {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
              {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
            ],
          })));
      final body2 = json.jsonDecode(r2.content) as Map;
      expect((body2['plan'] as List).map((s) => s['id']), ['s1'],
          reason: '失效步不入 grant');
      expect((body2['failed'] as List).single['id'], 's2');
      expect((body2['failed'] as List).single['reason'], '服务已离线');
      expect(state.frozenSteps.map((f) => f.id), ['s1']);
    });

    test('同批多个提议以首个为准', () async {
      final inner = _RecordingExecutor();
      final state = PlanRunState();
      final delegate = _FakePlanDelegate(const PlanProposalDecision(approved: true));
      final tool = makeTool(inner, state, delegate: delegate);
      state.markProposalPending();
      final r = await tool.execute(_call('propose_task_plan',
          args: json.jsonEncode({
            'goal': 'g',
            'steps': [
              {'id': 's1', 'server': 'shiguang', 'tool': 'create_event', 'intent': 'i'},
              {'id': 's2', 'server': 'note', 'tool': 'create_note', 'intent': 'i'},
            ],
          })));
      expect(r.isError, isFalse);
      expect(r.content, contains('已有计划在确认中'));
      expect(delegate.cards, isEmpty);
    });
  });
}

/// 真实 ToolRouter + stub faces（挂载即默认全激活，对齐 mcp_runtime 装配）。
ToolRouter _fakeRouter() {
  CloudToolSchema schema(String serverId, String tool) => CloudToolSchema(
        name: tool,
        description: '',
        parametersSchema: const {},
        annotations: _catalog['${serverId}__$tool'],
      );
  final faces = {
    'shiguang': _StubFace([
      schema('shiguang', 'create_event'),
      schema('shiguang', 'list_events'),
      schema('shiguang', 'delete_all'),
    ], serverId: 'shiguang'),
    'note': _StubFace([schema('note', 'create_note')], serverId: 'note'),
  };
  final router = ToolRouter(faces: faces);
  router.activatedServers.addAll(router.serverIds);
  return router;
}
