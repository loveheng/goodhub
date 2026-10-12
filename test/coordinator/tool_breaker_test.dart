import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

class ScriptedEngine implements CloudLlmEngine {
  final List<Stream<CloudStreamEvent> Function()> script = [];
  final List<CloudChatRequest> calls = [];

  @override
  String get name => 'scripted';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request) {
    calls.add(request);
    return script[calls.length - 1]();
  }
}

/// 按工具名脚本化成败：successTools 内的返回成功，其余返回 isError。
class ScriptedExecutor implements ToolExecutor {
  final Set<String> successTools;
  final executed = <String>[];

  ScriptedExecutor({this.successTools = const {}});

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    executed.add(call.name);
    return successTools.contains(call.name)
        ? ToolExecutionResult(content: 'ok:${call.name}')
        : const ToolExecutionResult(content: 'boom', isError: true);
  }
}

/// user_rejected 形状（isError=false，同 PermissionGateway 回填，C1 豁免验证）。
class RejectedExecutor implements ToolExecutor {
  final executed = <String>[];

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    executed.add(call.name);
    return const ToolExecutionResult(
      content: '{"status":"user_rejected","reason":"x"}',
    );
  }
}

class ScriptedBlockDelegate implements BlockDelegate {
  final List<BreakerResolution> breakerScript = [];
  final List<bool> stepWallScript = [];
  final breakerReports = <BreakerReport>[];
  final stepWallReports = <StepWallReport>[];

  @override
  Future<BreakerResolution> onBreakerTripped(BreakerReport report) async {
    breakerReports.add(report);
    return breakerScript.removeAt(0);
  }

  @override
  Future<bool> onStepWallReached(StepWallReport report) async {
    stepWallReports.add(report);
    return stepWallScript.removeAt(0);
  }
}

Stream<CloudStreamEvent> toolCallStream(String id, String name, String args) async* {
  yield CloudToolCallDelta(index: 0, id: id, name: name);
  yield CloudToolCallDelta(index: 0, argumentsDelta: args);
  yield const CloudDone(finishReason: CloudFinishReason.toolCalls);
}

Stream<CloudStreamEvent> textStream(String s) async* {
  yield CloudTextDelta(s);
  yield const CloudDone(finishReason: CloudFinishReason.stop);
}

void main() {
  late ScriptedEngine engine;

  setUp(() {
    engine = ScriptedEngine();
  });

  AgentLoop loopWith(ToolExecutor executor, {BlockDelegate? delegate, int maxTurns = 10}) =>
      AgentLoop(engine: engine, executor: executor, blockDelegate: delegate, maxTurns: maxTurns);

  test('无 delegate：同工具连续 2 次报错 → 强中止 InferenceException', () async {
    final executor = ScriptedExecutor();
    engine.script.addAll([
      () => toolCallStream('c1', 'flaky', '{}'),
      () => toolCallStream('c2', 'flaky', '{}'),
    ]);
    await expectLater(
      loopWith(executor).run(systemPrompt: 's', userPrompt: 'u').toList(),
      throwsA(
        isA<InferenceException>().having(
          (e) => e.message,
          'message',
          contains('两步熔断'),
        ),
      ),
    );
    expect(executor.executed, ['flaky', 'flaky']);
    expect(engine.calls, hasLength(2));
  });

  test('交叉其他工具成功不重置：A 败 B 成 A 败 → 熔断（C1）', () async {
    final executor = ScriptedExecutor(successTools: {'b'});
    engine.script.addAll([
      () => toolCallStream('c1', 'a', '{}'),
      () => toolCallStream('c2', 'b', '{}'),
      () => toolCallStream('c3', 'a', '{}'),
    ]);
    await expectLater(
      loopWith(executor).run(systemPrompt: 's', userPrompt: 'u').toList(),
      throwsA(isA<InferenceException>()),
    );
    expect(executor.executed, ['a', 'b', 'a']);
  });

  test('该工具成功重置：败→成→败→败 才熔断（C1）', () async {
    final flipping = _FlippingExecutor([false, true, false, false]);
    engine.script.addAll([
      () => toolCallStream('c1', 'a', '{}'),
      () => toolCallStream('c2', 'a', '{}'),
      () => toolCallStream('c3', 'a', '{}'),
      () => toolCallStream('c4', 'a', '{}'),
    ]);
    await expectLater(
      loopWith(flipping).run(systemPrompt: 's', userPrompt: 'u').toList(),
      throwsA(isA<InferenceException>()),
    );
    expect(flipping.executed, hasLength(4));
  });

  test('用户拒绝（isError=false）不计熔断：连续拒绝后正常收尾', () async {
    final executor = RejectedExecutor();
    engine.script.addAll([
      () => toolCallStream('c1', 'update_item', '{}'),
      () => toolCallStream('c2', 'update_item', '{}'),
      () => textStream('好吧'),
    ]);
    final events = await loopWith(executor)
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();
    expect(executor.executed, hasLength(2));
    expect(events.whereType<LoopFinished>().single.text, '好吧');
  });

  test('delegate 单步重试：计数重置后再失败只计 1，循环继续', () async {
    final executor = ScriptedExecutor();
    final delegate = ScriptedBlockDelegate();
    engine.script.addAll([
      () => toolCallStream('c1', 'flaky', '{}'),
      () => toolCallStream('c2', 'flaky', '{}'),
      () => textStream('收尾'),
    ]);
    delegate.breakerScript.add(const RetryOnce());
    final events = await loopWith(executor, delegate: delegate)
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();
    expect(delegate.breakerReports.single.toolName, 'flaky');
    expect(delegate.breakerReports.single.consecutiveFailures, 2);
    expect(executor.executed, hasLength(3)); // 败、败、重发
    expect(events.whereType<LoopFinished>().single.turns, 3);
  });

  test('delegate 跳过：isError 回填续跑（计数不重置）', () async {
    final executor = ScriptedExecutor();
    final delegate = ScriptedBlockDelegate();
    engine.script.addAll([
      () => toolCallStream('c1', 'flaky', '{}'),
      () => toolCallStream('c2', 'flaky', '{}'),
      () => textStream('绕行'),
    ]);
    delegate.breakerScript.add(const SkipOnce());
    final events = await loopWith(executor, delegate: delegate)
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();
    expect(executor.executed, hasLength(2));
    final finished = events.whereType<LoopToolCallFinished>().last;
    expect(finished.result.isError, isTrue);
    expect(events.whereType<LoopFinished>().single.text, '绕行');
  });

  test('delegate 人工接管：用户结果以 isError=false 回填', () async {
    final executor = ScriptedExecutor();
    final delegate = ScriptedBlockDelegate();
    engine.script.addAll([
      () => toolCallStream('c1', 'flaky', '{}'),
      () => toolCallStream('c2', 'flaky', '{}'),
      () => textStream('收到人工结果'),
    ]);
    delegate.breakerScript.add(const ManualResult('人工查到的结果'));
    await loopWith(executor, delegate: delegate)
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();
    final results = engine.calls[2].messages.whereType<ToolResultMessage>().toList();
    expect(results.last.isError, isFalse);
    expect(results.last.content, '人工查到的结果');
  });

  test('重试后再败两次 → 二次出卡（重置后重新累积）', () async {
    final executor = ScriptedExecutor();
    final delegate = ScriptedBlockDelegate();
    engine.script.addAll([
      () => toolCallStream('c1', 'flaky', '{}'),
      () => toolCallStream('c2', 'flaky', '{}'),
      () => toolCallStream('c3', 'flaky', '{}'),
      () => textStream('结束'),
    ]);
    delegate.breakerScript
      ..add(const RetryOnce())
      ..add(const SkipOnce());
    await loopWith(executor, delegate: delegate)
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();
    expect(delegate.breakerReports, hasLength(2));
    expect(executor.executed, hasLength(4)); // 败、败、重发败、再败
  });

  test('步数墙：delegate 放宽 +10 续跑（上下文保留）', () async {
    final executor = ScriptedExecutor(successTools: {'f'});
    final delegate = ScriptedBlockDelegate();
    engine.script.addAll([
      () => toolCallStream('c1', 'f', '{}'),
      () => toolCallStream('c2', 'f', '{}'),
      () => toolCallStream('c3', 'f', '{}'),
      () => textStream('终于'),
    ]);
    delegate.stepWallScript.add(true);
    final events = await loopWith(executor, delegate: delegate, maxTurns: 2)
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();
    expect(delegate.stepWallReports.single.turnsUsed, 2);
    expect(delegate.stepWallReports.single.limit, 2);
    final done = events.whereType<LoopFinished>().single;
    expect(done.turns, 4);
    expect(done.text, '终于');
  });

  test('步数墙：delegate 拒绝放宽 → 终止', () async {
    final executor = ScriptedExecutor(successTools: {'f'});
    final delegate = ScriptedBlockDelegate();
    engine.script.addAll([
      () => toolCallStream('c1', 'f', '{}'),
      () => toolCallStream('c2', 'f', '{}'),
    ]);
    delegate.stepWallScript.add(false);
    await expectLater(
      loopWith(executor, delegate: delegate, maxTurns: 2)
          .run(systemPrompt: 's', userPrompt: 'u')
          .toList(),
      throwsA(
        isA<InferenceException>().having(
          (e) => e.message,
          'message',
          contains('步数墙终止'),
        ),
      ),
    );
  });
}

class _FlippingExecutor implements ToolExecutor {
  _FlippingExecutor(this._plan);

  final List<bool> _plan;
  var _i = 0;
  final executed = <String>[];

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    executed.add(call.name);
    final ok = _plan[_i++];
    return ok
        ? ToolExecutionResult(content: 'ok')
        : const ToolExecutionResult(content: 'boom', isError: true);
  }
}
