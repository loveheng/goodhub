/// S0 保护网（施工稿 `docs/design/arch-consolidation.md` §S0）：Run 时序 golden 快照。
///
/// 四切片 = Happy / Abort / Reject / Watchdog——`chat_page._sendGuarded` 的膨胀来自
/// 中断与异常，而非 Happy Path；本件是 S3 下沉 `ChatSendUseCase` 的**回滚判据**：
/// 重构后事件序列须逐字等价。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

/// 按轮次回放脚本的假引擎；**多跑一轮即抛**（越界调用 = 时序断言失败）。
class ScriptedEngine implements CloudLlmEngine {
  final List<Stream<CloudStreamEvent> Function()> script = [];
  final List<CloudChatRequest> calls = [];

  @override
  String get name => 'scripted';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) {
    calls.add(request);
    if (calls.length > script.length) {
      throw StateError('多出的一轮推理（第 ${calls.length} 轮）——时序与脚本不符');
    }
    return script[calls.length - 1]();
  }
}

/// 按调用序回放结果的假执行器；[beforeReturn] 用于在执行返回前注入取消等时序钩子。
class ScriptedExecutor implements ToolExecutor {
  ScriptedExecutor(this.results, {this.beforeReturn});

  final List<ToolExecutionResult> results;
  Future<void> Function(int index)? beforeReturn;

  final List<AssembledToolCall> executed = [];
  int _i = 0;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    executed.add(call);
    final i = _i++;
    await beforeReturn?.call(i);
    return i < results.length ? results[i] : results.last;
  }
}

/// 记录熔断/步数墙排查卡调用（Reject 切片要断言它**未被**触发）。
class RecordingBlockDelegate implements BlockDelegate {
  final List<BreakerReport> reports = [];
  final List<BreakerResolution> resolutions = [];

  @override
  Future<BreakerResolution> onBreakerTripped(BreakerReport report) async {
    reports.add(report);
    return resolutions.isEmpty ? const SkipOnce() : resolutions.removeAt(0);
  }

  @override
  Future<bool> onStepWallReached(StepWallReport report) async => false;
}

Stream<CloudStreamEvent> _toolCall(String id, String name, [String args = '{}']) async* {
  yield CloudToolCallDelta(index: 0, id: id, name: name);
  yield CloudToolCallDelta(index: 0, argumentsDelta: args);
  yield const CloudDone(finishReason: CloudFinishReason.toolCalls);
}

Stream<CloudStreamEvent> _text(String s) async* {
  yield CloudTextDelta(s);
  yield const CloudDone(finishReason: CloudFinishReason.stop);
}

/// 事件序列归一化为可比对快照（**顺序敏感**）。
List<String> _render(List<AgentLoopEvent> events) => [
      for (final e in events)
        switch (e) {
          LoopTextDelta(:final text) => 'text:$text',
          LoopThinkingDelta() => 'think',
          LoopToolCallStarted(:final call) => 'started:${call.name}',
          LoopToolProgress() => 'progress',
          LoopToolCallFinished(:final call, :final result) =>
            'finished:${call.name}|${result.content}|err=${result.isError}',
          LoopFinished(:final text, :final turns, :final finishReason) =>
            'done:turns=$turns,reason=${finishReason.name},text=$text',
        },
    ];

Future<List<AgentLoopEvent>> _collect(Stream<AgentLoopEvent> stream) async {
  final events = <AgentLoopEvent>[];
  await stream.forEach(events.add);
  return events;
}

void main() {
  group('S0 Golden · Happy', () {
    test('工具轮 → 自然结算：事件序列与轮数快照', () async {
      final engine = ScriptedEngine();
      final executor = ScriptedExecutor(const [ToolExecutionResult(content: 'r1')]);
      engine.script
        ..add(() => _toolCall('call_1', 'good__a'))
        ..add(() => _text('完成'));

      final loop = AgentLoop(engine: engine, executor: executor);
      final snapshot = _render(await _collect(loop.run(systemPrompt: 's', userPrompt: 'u')));

      expect(snapshot, [
        'started:good__a',
        'finished:good__a|r1|err=false',
        'text:完成',
        'done:turns=2,reason=stop,text=完成',
      ]);
      expect(engine.calls.length, 2);
    });
  });

  group('S0 Golden · Abort', () {
    test('工具执行中途取消 → 边界收口，不再起新推理轮', () async {
      final engine = ScriptedEngine();
      final executor = ScriptedExecutor(const [ToolExecutionResult(content: 'r1')]);
      late AgentLoop loop;
      executor.beforeReturn = (i) async {
        if (i == 0) loop.abort();
      };
      // 只有一轮脚本：若取消未生效会触发「多出的一轮」StateError。
      engine.script.add(() => _toolCall('call_1', 'good__a'));

      loop = AgentLoop(engine: engine, executor: executor);
      final snapshot = _render(await _collect(loop.run(systemPrompt: 's', userPrompt: 'u')));

      expect(executor.executed.length, 1, reason: '在途调用不被打断，后续调用不再发起');
      expect(engine.calls.length, 1);
      expect(snapshot.last, 'done:turns=1,reason=stop,text=',
          reason: '中断收口：turns=1 且正文为空（已收 delta 不回滚抖动）');
    });
  });

  group('S0 Golden · Reject', () {
    test('用户拒绝按结构化结果回填，不计入两步熔断', () async {
      final engine = ScriptedEngine();
      final executor = ScriptedExecutor(const [
        ToolExecutionResult(content: '{"status":"user_rejected","reason":"用户拒绝"}'),
      ]);
      final delegate = RecordingBlockDelegate();
      engine.script
        ..add(() => _toolCall('call_1', 'good__a'))
        ..add(() => _text('收到拒绝，不再调用'));

      final loop = AgentLoop(
        engine: engine,
        executor: executor,
        blockDelegate: delegate,
      );
      final snapshot = _render(await _collect(loop.run(systemPrompt: 's', userPrompt: 'u')));

      expect(delegate.reports, isEmpty, reason: 'user_rejected（isError=false）不进熔断计数');
      expect(
        snapshot,
        contains('finished:good__a|{"status":"user_rejected","reason":"用户拒绝"}|err=false'),
      );
      expect(snapshot.last, 'done:turns=2,reason=stop,text=收到拒绝，不再调用');
    });
  });

  group('S0 Golden · Watchdog', () {
    test('同工具连续报错触发熔断排查卡，人工接管结果回填后继续', () async {
      final engine = ScriptedEngine();
      final executor = ScriptedExecutor(const [
        ToolExecutionResult(content: 'boom-1', isError: true),
        ToolExecutionResult(content: 'boom-2', isError: true),
      ]);
      final delegate = RecordingBlockDelegate()
        ..resolutions.add(const ManualResult('人工接管结果'));
      engine.script
        ..add(() => _toolCall('call_1', 'good__a'))
        ..add(() => _toolCall('call_2', 'good__a'))
        ..add(() => _text('已接管'));

      final loop = AgentLoop(
        engine: engine,
        executor: executor,
        blockDelegate: delegate,
        breakerThreshold: 2,
      );
      final snapshot = _render(await _collect(loop.run(systemPrompt: 's', userPrompt: 'u')));

      expect(delegate.reports.length, 1);
      expect(delegate.reports.single.toolName, 'good__a');
      expect(delegate.reports.single.consecutiveFailures, greaterThanOrEqualTo(2));
      expect(snapshot, contains('finished:good__a|人工接管结果|err=false'));
      expect(snapshot.last, 'done:turns=3,reason=stop,text=已接管');
    });
  });
}
