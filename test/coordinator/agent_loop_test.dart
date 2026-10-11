import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/context_governor.dart';
import 'package:goodhub/coordinator/ref_store.dart';
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

class RecordingExecutor implements ToolExecutor {
  final executed = <AssembledToolCall>[];
  Object? throwOnNext;

  /// 可设执行产出（T6 摘要化用例需要超阈值原文；缺省维持 'r1'）。
  String nextContent = 'r1';

  /// 执行钩子（M3-T2 进度桥接/abort 时序用例：模拟 face.onProgress 在执行
  /// 期间回调 loop.emitToolProgress）。
  void Function(AssembledToolCall call)? onExecute;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    executed.add(call);
    onExecute?.call(call);
    final t = throwOnNext;
    if (t != null) {
      throwOnNext = null;
      throw t;
    }
    return ToolExecutionResult(content: nextContent);
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
  late RecordingExecutor executor;
  late AgentLoop loop;

  setUp(() {
    engine = ScriptedEngine();
    executor = RecordingExecutor();
    loop = AgentLoop(engine: engine, executor: executor);
  });

  test('纯文本单轮：delta 透传 + LoopFinished', () async {
    engine.script.add(() => textStream('你好'));
    final events = await loop
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();
    expect(
      events.whereType<LoopTextDelta>().map((e) => e.text).join(),
      '你好',
    );
    final done = events.whereType<LoopFinished>().single;
    expect(done.text, '你好');
    expect(done.turns, 1);
    expect(done.finishReason, CloudFinishReason.stop);
    expect(executor.executed, isEmpty);
  });

  test('工具轮：执行环调用 + 结果回填上下文后收尾', () async {
    engine.script
      ..add(() => toolCallStream('call_1', 'f', '{"x":1}'))
      ..add(() => textStream('ok'));
    final events = await loop
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();

    final started = events.whereType<LoopToolCallStarted>().single;
    expect(started.call.id, 'call_1');
    expect(executor.executed.single.name, 'f');
    expect(events.whereType<LoopToolCallFinished>().single.result.content, 'r1');

    // 第二轮请求必须携带 assistant(tool_calls) + tool 结果消息
    final second = engine.calls[1];
    final msgs = second.messages;
    final assistant = msgs.whereType<AssistantMessage>().single;
    expect(assistant.toolCalls.single.id, 'call_1');
    final toolResult = msgs.whereType<ToolResultMessage>().single;
    expect(toolResult.content, 'r1');
    expect(toolResult.isError, isFalse);

    final done = events.whereType<LoopFinished>().single;
    expect(done.text, 'ok');
    expect(done.turns, 2);
  });

  test('工具执行抛错 → isError 结果回填，循环继续', () async {
    executor.throwOnNext = Exception('炸了');
    engine.script
      ..add(() => toolCallStream('call_1', 'f', '{}'))
      ..add(() => textStream('done'));
    final events = await loop
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList();
    final finished = events.whereType<LoopToolCallFinished>().single;
    expect(finished.result.isError, isTrue);
    expect(finished.result.content, contains('炸了'));
    final toolResult =
        engine.calls[1].messages.whereType<ToolResultMessage>().single;
    expect(toolResult.isError, isTrue);
    expect(events.whereType<LoopFinished>().single.text, 'done');
  });

  test('步数墙：maxTurns 轮耗尽仍要求工具 → InferenceException', () async {
    final loop1 = AgentLoop(engine: engine, executor: executor, maxTurns: 2);
    engine.script.addAll([
      () => toolCallStream('c1', 'f', '{}'),
      () => toolCallStream('c2', 'f', '{}'),
      () => toolCallStream('c3', 'f', '{}'),
    ]);
    await expectLater(
      loop1.run(systemPrompt: 's', userPrompt: 'u').toList(),
      throwsA(isA<InferenceException>()),
    );
    expect(engine.calls, hasLength(2));
  });

  test('工具 Schema 透传到每次引擎请求', () async {
    const tools = [
      CloudToolSchema(name: 'f', description: 'd', parametersSchema: {'type': 'object'}),
    ];
    engine.script.add(() => textStream('x'));
    await loop.run(systemPrompt: 's', userPrompt: 'u', tools: tools).toList();
    expect(engine.calls.single.tools, tools);
  });

  test('T6 滑动窗口：发送边界只带最近 N 轮完整对，本地历史不裁', () async {
    final loop1 = AgentLoop(engine: engine, executor: executor, windowRounds: 1);
    engine.script.addAll([
      () => toolCallStream('c1', 'f', '{}'),
      () => toolCallStream('c2', 'f', '{}'),
      () => toolCallStream('c3', 'f', '{}'),
      () => textStream('done'),
    ]);
    final done = await loop1
        .run(systemPrompt: 's', userPrompt: 'u')
        .toList()
        .then((events) => events.whereType<LoopFinished>().single);

    expect(done.turns, 4);
    // 第 1 次发送：仅 System+User（尚无轮）
    expect(engine.calls[0].messages, hasLength(2));
    // 第 2 次：1 轮在窗内（System+User+c1 对）
    expect(engine.calls[1].messages, hasLength(4));
    // 第 3 次：窗口 N=1 → 仅最近一轮 c2，裁剪点=Assistant 边界不拆对
    final third = engine.calls[2].messages;
    expect(third, hasLength(4));
    expect(third.first, isA<SystemMessage>());
    expect(third[1], isA<UserMessage>());
    expect(third[2], isA<AssistantMessage>());
    expect(
      third.whereType<AssistantMessage>().map((m) => m.toolCalls.single.id),
      ['c2'],
    );
    // 第 4 次：仅剩 c3
    expect(
      engine.calls[3].messages
          .whereType<AssistantMessage>()
          .map((m) => m.toolCalls.single.id),
      ['c3'],
    );
  });

  test('T6 摘要化：>阈值结果回填端侧摘要，事件仍带原文', () async {
    final original = 'x' * 1001;
    executor.nextContent = original;
    final summarizeCalls = <String>[];
    final loop1 = AgentLoop(
      engine: engine,
      executor: executor,
      summarizer: (o) async {
        summarizeCalls.add(o);
        return '要点';
      },
    );
    engine.script
      ..add(() => toolCallStream('c1', 'f', '{}'))
      ..add(() => textStream('ok'));
    final events = await loop1.run(systemPrompt: 's', userPrompt: 'u').toList();

    expect(summarizeCalls, [original]);
    final backfilled =
        engine.calls[1].messages.whereType<ToolResultMessage>().single;
    expect(backfilled.content, startsWith('要点'));
    expect(backfilled.content, contains('[宿主注：原工具结果约 1001 tokens'));
    // 治理只影响发送上下文：UI/遥测事件仍携带原文
    expect(
      events.whereType<LoopToolCallFinished>().single.result.content,
      original,
    );
  });

  test('T6 阈值边界：恰等于阈值不摘要化', () async {
    executor.nextContent = 'x' * 1000;
    var called = false;
    final loop1 = AgentLoop(
      engine: engine,
      executor: executor,
      summarizer: (o) async {
        called = true;
        return '要点';
      },
    );
    engine.script
      ..add(() => toolCallStream('c1', 'f', '{}'))
      ..add(() => textStream('ok'));
    await loop1.run(systemPrompt: 's', userPrompt: 'u').toList();
    expect(called, isFalse);
    expect(
      engine.calls[1].messages.whereType<ToolResultMessage>().single.content,
      'x' * 1000,
    );
  });

  test('T6 摘要化失败（E1 兜底）：保留原文回填，循环不中断', () async {
    executor.nextContent = 'x' * 1001;
    final loop1 = AgentLoop(
      engine: engine,
      executor: executor,
      summarizer: (o) async => throw const SummarizeException('端侧摘要产出为空'),
    );
    engine.script
      ..add(() => toolCallStream('c1', 'f', '{}'))
      ..add(() => textStream('ok'));
    final events = await loop1.run(systemPrompt: 's', userPrompt: 'u').toList();
    expect(
      engine.calls[1].messages.whereType<ToolResultMessage>().single.content,
      'x' * 1001,
    );
    expect(events.whereType<LoopFinished>().single.text, 'ok');
  });

  group('M3-T2：LoopToolProgress 与 abort', () {
    test('进度桥接：emitToolProgress 挂当前活跃调用，事件序 Started → Progress* → Finished', () async {
      engine.script
        ..add(() => toolCallStream('c1', 'slow_tool', '{}'))
        ..add(() => textStream('完成'));
      executor.onExecute = (call) {
        loop.emitToolProgress('slow_tool', 0, 1, '开始');
        loop.emitToolProgress('slow_tool', 1, 1, '请求宿主推理中');
        loop.emitToolProgress('other_tool', 9, 9, null); // 名不匹配的迟到帧
      };
      final events =
          await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      final progresses = events.whereType<LoopToolProgress>().toList();
      expect(progresses.length, 2, reason: '工具名不匹配的帧被丢弃');
      expect(progresses.first.call.id, 'c1');
      expect(progresses.first.call.name, 'slow_tool');
      expect(progresses.last.message, '请求宿主推理中');
      final types = events.map((e) => e.runtimeType).toList();
      expect(types.indexOf(LoopToolCallStarted),
          lessThan(types.indexOf(LoopToolProgress)));
      expect(types.lastIndexOf(LoopToolProgress),
          lessThan(types.indexOf(LoopToolCallFinished)));
    });

    test('run() 期外 emitToolProgress 为 no-op（不抛不入流）', () async {
      loop.emitToolProgress('x', 1, 2, null); // run 未启动
      engine.script.add(() => textStream('ok'));
      final events =
          await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      expect(events.whereType<LoopToolProgress>(), isEmpty);
    });

    test('abort 于工具边界：在途调用结果照常回填，后续调用与轮次不再执行', () async {
      engine.script
        ..add(() => toolCallStream('c1', 'f', '{}'))
        ..add(() => toolCallStream('c2', 'f', '{}'));
      executor.onExecute = (call) {
        if (call.id == 'c1') loop.abort();
      };
      final events =
          await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      expect(executor.executed.map((c) => c.id), ['c1'], reason: 'c2 不再执行');
      expect(events.whereType<LoopToolCallFinished>().single.call.id, 'c1',
          reason: '在途调用真实结果不丢');
      final done = events.whereType<LoopFinished>().single;
      expect(done.turns, 1);
      expect(done.finishReason, CloudFinishReason.stop);
    });

    test('abort 于引擎流中途：断流结算，中止后的 delta 不透传', () async {
      engine.script.add(() => () async* {
            yield const CloudTextDelta('部分');
            loop.abort();
            yield const CloudTextDelta('不该出现的尾巴');
            yield const CloudDone(finishReason: CloudFinishReason.stop);
          }());
      final events =
          await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      expect(events.whereType<LoopTextDelta>().map((e) => e.text).join(), '部分');
      expect(events.whereType<LoopFinished>().single.text, '部分',
          reason: '已收 delta 结算');
    });
  });

  group('M3-T3：\$ref put 端（摘要化成功路径落池升级句柄）', () {
    late Directory tempDir;
    late RefStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ref_t3');
      store = RefStore(cacheDir: tempDir, gcInterval: null);
    });

    tearDown(() async {
      store.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('摘要化成功 → 宿主注升级句柄，池内原文可读回（put→read 闭环）', () async {
      final original = 'x' * 1001;
      executor.nextContent = original;
      final loop1 = AgentLoop(
        engine: engine,
        executor: executor,
        summarizer: (o) async => '要点摘要',
        refStore: store,
      );
      engine.script
        ..add(() => toolCallStream('c1', 'f', '{}'))
        ..add(() => textStream('ok'));
      await loop1.run(systemPrompt: 's', userPrompt: 'u').toList();
      final backfill =
          engine.calls[1].messages.whereType<ToolResultMessage>().single.content;
      expect(backfill, contains('[宿主注：原工具结果约 1001 tokens'));
      expect(backfill, contains('传引用'), reason: '句柄注记带用法引导（ref-pipeline 同口径）');
      final handle =
          RegExp(r'\\$ref:goodshare:[0-9a-f]{16}').firstMatch(backfill)!.group(0)!;
      expect(store.length, 1);
      expect(await store.read(handle), original, reason: 'HydratingExecutor 读端注水依据');
    });

    test('E1 摘要化失败：原文直传不落池（无句柄注记）', () async {
      executor.nextContent = 'x' * 1001;
      final loop1 = AgentLoop(
        engine: engine,
        executor: executor,
        summarizer: (o) async => throw const SummarizeException('端侧摘要产出为空'),
        refStore: store,
      );
      engine.script
        ..add(() => toolCallStream('c1', 'f', '{}'))
        ..add(() => textStream('ok'));
      await loop1.run(systemPrompt: 's', userPrompt: 'u').toList();
      final backfill =
          engine.calls[1].messages.whereType<ToolResultMessage>().single.content;
      expect(backfill, 'x' * 1001, reason: 'E1 兜底：原文直传');
      expect(store.length, 0, reason: '原文已直传，无需池化');
    });

    test('阈值下不落池不摘要化', () async {
      executor.nextContent = 'x' * 1000;
      final loop1 = AgentLoop(
        engine: engine,
        executor: executor,
        summarizer: (o) async => '要点摘要',
        refStore: store,
      );
      engine.script
        ..add(() => toolCallStream('c1', 'f', '{}'))
        ..add(() => textStream('ok'));
      await loop1.run(systemPrompt: 's', userPrompt: 'u').toList();
      final backfill =
          engine.calls[1].messages.whereType<ToolResultMessage>().single.content;
      expect(backfill, 'x' * 1000);
      expect(store.length, 0);
    });

    test('refStore 缺省：摘要化成功但维持 M2 引用标记形态（无句柄）', () async {
      executor.nextContent = 'x' * 1001;
      final loop1 = AgentLoop(
        engine: engine,
        executor: executor,
        summarizer: (o) async => '要点摘要',
      );
      engine.script
        ..add(() => toolCallStream('c1', 'f', '{}'))
        ..add(() => textStream('ok'));
      await loop1.run(systemPrompt: 's', userPrompt: 'u').toList();
      final backfill =
          engine.calls[1].messages.whereType<ToolResultMessage>().single.content;
      expect(backfill, contains('[宿主注：原工具结果约 1001 tokens'));
      expect(backfill.contains(r'$ref:goodshare:'), isFalse);
    });
  });

  group('多轮上下文（M4-T3/D11）', () {
    test('transcript 回传：纯文本轮 = [User, Assistant(text)]，不含 System', () async {
      engine.script.add(() => textStream('答A'));
      final events = await loop.run(systemPrompt: 's', userPrompt: '问A').toList();
      final done = events.whereType<LoopFinished>().single;
      expect(done.transcript, hasLength(2));
      expect((done.transcript[0] as UserMessage).content, '问A');
      expect((done.transcript[1] as AssistantMessage).content, '答A');
    });

    test('history 入参：System 每轮重组 + 历史原样前插 + 本轮 User 在尾', () async {
      final prior = [
        const UserMessage('问A'),
        const AssistantMessage(content: '答A'),
      ];
      engine.script.add(() => textStream('答B'));
      await loop.run(systemPrompt: 's2', userPrompt: '问B', history: prior).toList();
      final messages = engine.calls.single.messages;
      expect(messages, hasLength(4));
      expect(messages.first, isA<SystemMessage>());
      expect((messages[1] as UserMessage).content, '问A');
      expect((messages[2] as AssistantMessage).content, '答A');
      expect((messages[3] as UserMessage).content, '问B');
    });

    test('工具轮 transcript：assistant(tool_calls)+tool result 配对入史，终文收尾', () async {
      engine.script
        ..add(() => toolCallStream('call_1', 'f', '{}'))
        ..add(() => textStream('done'));
      final events = await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      final transcript = events.whereType<LoopFinished>().single.transcript;
      expect(transcript, hasLength(4));
      expect(transcript[1], isA<AssistantMessage>());
      expect(transcript[2], isA<ToolResultMessage>());
      expect((transcript[3] as AssistantMessage).content, 'done');
    });

    test('Abort 打断工具环：未配对 assistant(tool_calls) 段整段截断（协议可回放）', () async {
      Stream<CloudStreamEvent> twoCallStream() async* {
        yield CloudToolCallDelta(index: 0, id: 'c1', name: 'f');
        yield const CloudToolCallDelta(index: 0, argumentsDelta: '{}');
        yield CloudToolCallDelta(index: 1, id: 'c2', name: 'g');
        yield const CloudToolCallDelta(index: 1, argumentsDelta: '{}');
        yield const CloudDone(finishReason: CloudFinishReason.toolCalls);
      }

      engine.script.add(twoCallStream);
      executor.onExecute = (_) => loop.abort(); // 首调用执行时即中止
      final events = await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      final done = events.whereType<LoopFinished>().single;
      expect(done.transcript, hasLength(1),
          reason: 'assistant(c1,c2) 仅 c1 配对——未配对尾巴连同该 assistant 整段剔除');
      expect(done.transcript.single, isA<UserMessage>());
    });
  });
}
