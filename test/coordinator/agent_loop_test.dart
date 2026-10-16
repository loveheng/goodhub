import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/context_governor.dart';
import 'package:goodhub/coordinator/ref_store.dart';
import 'package:goodhub/coordinator/workspace_stream_filter.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

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
          RegExp(r'\$ref:goodshare:[0-9a-f]{16}').firstMatch(backfill)!.group(0)!;
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

    test('systemTail（P1-3b 断点 A）：静态前缀挂 ephemeral，记忆块置尾无断点', () async {
      engine.script.add(() => textStream('答'));
      await loop
          .run(systemPrompt: '静态+skills', userPrompt: 'u', systemTail: '记忆区')
          .toList();
      final messages = engine.calls.single.messages;
      expect(messages, hasLength(3));
      final head = messages[0] as SystemMessage;
      expect(head.content, '静态+skills');
      expect(head.cacheControl, CacheControl.ephemeral,
          reason: '断点 A 挂静态前缀末（§7.5）');
      final tail = messages[1] as SystemMessage;
      expect(tail.content, '记忆区');
      expect(tail.cacheControl, isNull, reason: '动态记忆不建独立断点（D-K）');
      expect((messages[2] as UserMessage).content, 'u');
    });

    test('无 systemTail 时旧形态：单 System 块无断点（零行为变化）', () async {
      engine.script.add(() => textStream('答'));
      await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      final messages = engine.calls.single.messages;
      expect(messages, hasLength(2));
      final sys = messages.first as SystemMessage;
      expect(sys.cacheControl, isNull);
    });

    test('workspaceFilter（P2-3/G2）：正文 delta 实时分流，终文/历史剥离结构化段', () async {
      final extracted = <List<WorkspaceFactUpdate>>[];
      final filter = WorkspaceStreamFilter(onExtracted: extracted.add);
      engine.script.add(() => textStream(
          '答A。${WorkspaceStreamFilter.startTag}'
          '{"facts":[{"key":"k","value":"v","scope":"user","action":"upsert"}]}'
          '${WorkspaceStreamFilter.endTag}'));
      final events = await loop
          .run(systemPrompt: 's', userPrompt: 'u', workspaceFilter: filter)
          .toList();
      final deltas = events
          .whereType<LoopTextDelta>()
          .map((e) => e.text)
          .join();
      expect(deltas, '答A。', reason: 'UI 只收剥离后纯文本');
      final done = events.whereType<LoopFinished>().single;
      expect(done.text, '答A。', reason: '终文剥离结构化段');
      expect(extracted.single.single.key, 'k', reason: '闭环原子提交触发');
    });

    test('workspaceFilter tool-call 轮硬压：calls.isNotEmpty 调 cancelCommit', () async {
      final extracted = <List<WorkspaceFactUpdate>>[];
      final filter = WorkspaceStreamFilter(onExtracted: extracted.add);
      engine.script
        ..add(() => textStream(
            '${WorkspaceStreamFilter.startTag}{"facts"')) // 残缺段 + tool-call 轮
        ..add(() => toolCallStream('call_1', 'f', '{}'))
        ..add(() => textStream('done'));
      await loop
          .run(systemPrompt: 's', userPrompt: 'u', workspaceFilter: filter)
          .toList();
      // tool-call 轮结算已 cancelCommit；随后即便闭合到达也不提交（禁令在位，
      // 且下轮 feed 的新文本正常）。
      expect(extracted, isEmpty, reason: 'tool-call 轮严禁提交记忆（§3.3）');
    });

    test('workspaceFilter 为 null 时零行为变化（旧路径直通）', () async {
      engine.script.add(() => textStream('raw<tag>text'));
      final events = await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      final deltas = events
          .whereType<LoopTextDelta>()
          .map((e) => e.text)
          .join();
      expect(deltas, 'raw<tag>text');
      expect(events.whereType<LoopFinished>().single.text, 'raw<tag>text');
    });

    test('P2-4（§9.3）输入端消毒：userPrompt 与 history UserMessage 的 < 转义', () async {
      final prior = [const UserMessage('旧轮 <workspace_update_v1> 复述')];
      engine.script.add(() => textStream('答'));
      await loop
          .run(
            systemPrompt: 's',
            userPrompt: '新输入 <tag>',
            history: prior,
            workspaceFilter: WorkspaceStreamFilter(), // 转义与分流正交
          )
          .toList();
      final messages = engine.calls.single.messages;
      expect((messages.last as UserMessage).content, '新输入 &lt;tag>');
      expect(
        (messages[1] as UserMessage).content,
        '旧轮 &lt;workspace_update_v1> 复述',
        reason: '历史用户消息同样消毒——转义幂等（&lt; 不含 <）',
      );
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

    test('Abort 打断工具环（P3-1 并发编排）：在途调用全部结算配对，无未配对尾巴', () async {
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
      // 并发编排（D-J）：两调用同时派发、全部结算——100% tool_call_id 配对
      // 回填（协议可回放），abort 只影响后续轮次，不再产生未配对尾巴。
      expect(done.transcript, hasLength(4));
      expect(done.transcript[0], isA<UserMessage>());
      expect(done.transcript[1], isA<AssistantMessage>());
      expect(done.transcript[2], isA<ToolResultMessage>());
      expect(done.transcript[3], isA<ToolResultMessage>());
    });

    test('P3-3 硬截断（D-I）：超 2000 tokens 多行输出 → Head 50/Tail 20 折叠',
        () async {
      engine.script
        ..add(() => toolCallStream('c1', 'big_list', '{}'))
        ..add(() => textStream('done'));
      // 100 行、每行 100 字符 = 10000 tokens，远超 kToolResultHardCapTokens=2000。
      executor.nextContent = [for (var i = 0; i < 100; i++) 'r$i'.padRight(100, 'x')].join('\n');
      final events = await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      // 治理后文本落 canonical 历史（LoopToolCallFinished 事件携带原始 result）。
      final backfill = events
          .whereType<LoopFinished>()
          .single
          .transcript
          .whereType<ToolResultMessage>()
          .single;
      expect(backfill.content, contains('Output truncated'));
      // 回填恒不超上界（estimateTokens = 字符级）。
      expect(backfill.content.length,
          lessThanOrEqualTo(AgentLoop.kToolResultHardCapTokens + 200),
          reason: '折叠注记可超一点，但幅度受控');
    });

    test('P3-3 硬截断（D-I）：少行超长单行 → 字符级保底仍不超上界', () async {
      engine.script
        ..add(() => toolCallStream('c1', 'dump', '{}'))
        ..add(() => textStream('done'));
      executor.nextContent = 'x' * 5000; // 单行 5000 tokens，无折叠行可取
      final events = await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      final backfill = events
          .whereType<LoopFinished>()
          .single
          .transcript
          .whereType<ToolResultMessage>()
          .single;
      expect(backfill.content, contains('Output truncated'));
      expect(backfill.content.length,
          lessThanOrEqualTo(AgentLoop.kToolResultHardCapTokens + 200));
    });

    test('P3-3 硬截断（D-I）：阈值内输出原样直通不误伤', () async {
      engine.script
        ..add(() => toolCallStream('c1', 'f', '{}'))
        ..add(() => textStream('done'));
      executor.nextContent = 'r1';
      final events = await loop.run(systemPrompt: 's', userPrompt: 'u').toList();
      final backfill = events
          .whereType<LoopFinished>()
          .single
          .transcript
          .whereType<ToolResultMessage>()
          .single;
      expect(backfill.content, 'r1');
      expect(backfill.content, isNot(contains('Output truncated')));
    });

    test('P3-2 合成桩（D-H/§9.1）：已让位私有域历史发送边界脱敏，canonical 不动', () async {
      // 历史：私有域 p1 的调用（已让位 → mask）+ 公共调用（不 mask）。
      final prior = [
        const UserMessage('u0'),
        AssistantMessage(
          content: null,
          toolCalls: [
            AssembledToolCall(id: 'c1', name: 'p1__secret', argumentsJson: '{"token":"x"}'),
            AssembledToolCall(id: 'c2', name: 's1__public', argumentsJson: '{"q":1}'),
          ],
        ),
        const ToolResultMessage(toolCallId: 'c1', content: '机密结果'),
        const ToolResultMessage(toolCallId: 'c2', content: '公开结果'),
      ];
      engine.script.add(() => textStream('done'));
      await loop
          .run(
            systemPrompt: 's',
            userPrompt: 'u1',
            history: prior,
            maskTool: (name) => name.startsWith('p1__'),
          )
          .toList();
      final sent = engine.calls.single.messages;
      // 发送边界：c1 桩化（保留 id，函数名/入参替换），c1 结果换标准注记。
      final assistant = sent.whereType<AssistantMessage>().single;
      expect(assistant.toolCalls[0].id, 'c1');
      expect(assistant.toolCalls[0].name, AgentLoop.kSyntheticMaskedTool);
      expect(assistant.toolCalls[0].argumentsJson, '{}');
      expect(assistant.toolCalls[1].name, 's1__public', reason: '公共调用不脱敏');
      final r1 = sent.whereType<ToolResultMessage>().firstWhere((m) => m.toolCallId == 'c1');
      expect(r1.content, AgentLoop.kSyntheticMaskedNotice);
      expect(r1.isError, isFalse);
      final r2 = sent.whereType<ToolResultMessage>().firstWhere((m) => m.toolCallId == 'c2');
      expect(r2.content, '公开结果');
      // canonical 不动的保真由调用方持有 history 验证（本用例覆盖发送侧形状）。
    });

    test('P3-2 合成桩（D-H）：maskTool=null 直通零行为变化', () async {
      final prior = [
        AssistantMessage(
          content: null,
          toolCalls: [AssembledToolCall(id: 'c1', name: 'p1__secret', argumentsJson: '{"a":1}')],
        ),
        const ToolResultMessage(toolCallId: 'c1', content: 'r'),
      ];
      engine.script.add(() => textStream('done'));
      await loop.run(systemPrompt: 's', userPrompt: 'u', history: prior).toList();
      final sent = engine.calls.single.messages;
      expect((sent[1] as AssistantMessage).toolCalls.single.name, 'p1__secret');
      expect((sent[1] as AssistantMessage).toolCalls.single.argumentsJson, '{"a":1}');
      expect(sent.whereType<ToolResultMessage>().single.content, 'r');
    });
  });

  group('阶梯截断归档摘要（context-stepped-pruning §2.2）', () {
    /// System + n 轮完整对（与 context_governor_test 同构）。
    List<CloudChatMessage> rounds(int n) => [
          for (var i = 1; i <= n; i++) ...[
            UserMessage('u$i'),
            AssistantMessage(
              content: 'a$i',
              toolCalls: [AssembledToolCall(id: 'c$i', name: 'f', argumentsJson: '{}')],
            ),
            ToolResultMessage(toolCallId: 'c$i', content: 'r$i'),
          ],
        ];

    test('触高水位（13 轮历史）：归档摘要插装 System 后，保留区 7 轮完整对', () async {
      final corpora = <String>[];
      final steppedLoop = AgentLoop(
        engine: engine,
        executor: executor,
        summarizer: (corpus) async {
          corpora.add(corpus);
          return '摘要A';
        },
      );
      engine.script.add(() => textStream('done'));
      await steppedLoop
          .run(
            systemPrompt: 's',
            userPrompt: 'unew',
            history: rounds(13),
          )
          .toList();

      expect(corpora, hasLength(1), reason: '触线一次归档一次');
      expect(corpora.single, contains('a1'), reason: '被裁轮次原文入摘要语料');
      expect(corpora.single, isNot(contains('a13')), reason: '保留轮不进语料');

      final sent = engine.calls.single.messages;
      expect(sent.first, isA<SystemMessage>());
      // 摘要块：前导（System+u1）之后、第一个保留轮（u7,a7）之前的 UserMessage。
      final noteIdx = sent.indexWhere(
        (m) => m is UserMessage && m.content.contains('归档摘要'),
      );
      expect(noteIdx, greaterThan(0), reason: '摘要块在位');
      final note = sent[noteIdx] as UserMessage;
      expect(note.content, contains('摘要A'));
      final firstRoundIdx =
          sent.indexWhere((m) => m is AssistantMessage);
      expect(noteIdx, firstRoundIdx - 1, reason: '摘要块紧贴保留区首 Assistant 之前');
      // 保留区：R7~R13 完整对（含各自 User 提问），R2~R6 已出窗归档。
      final keptAssistantIds = sent
          .whereType<AssistantMessage>()
          .map((m) => m.toolCalls.single.id)
          .toList();
      expect(keptAssistantIds, ['c7', 'c8', 'c9', 'c10', 'c11', 'c12', 'c13']);
      final userContents =
          sent.whereType<UserMessage>().map((m) => m.content).toList();
      expect(userContents, contains('u1'),
          reason: '前导 User 随 System 恒保留（朴素滑动同口径）');
      expect(userContents, contains('u7'),
          reason: '保留轮自己的提问必须随轮走（steppedWindow 回退纪律）');
      expect(userContents, isNot(contains('u2')), reason: '被裁轮次提问不入发送区');
      expect(corpora.single, isNot(contains('u7')),
          reason: '保留轮提问不混入归档语料');
    });

    test('轮数未触高水位：纯追加，不调摘要器、无摘要块', () async {
      var summarized = 0;
      final steppedLoop = AgentLoop(
        engine: engine,
        executor: executor,
        summarizer: (_) async {
          summarized++;
          return '不应出现';
        },
      );
      engine.script.add(() => textStream('done'));
      await steppedLoop
          .run(systemPrompt: 's', userPrompt: 'unew', history: rounds(6))
          .toList();
      expect(summarized, 0, reason: '低水位内纯追加（缓存 100% 命中）');
      expect(
        engine.calls.single.messages.whereType<UserMessage>().map((m) => m.content),
        isNot(contains(contains('归档摘要'))),
      );
    });

    test('摘要器失败：弃归档降级朴素滑动（E1 口径，禁中断）', () async {
      final steppedLoop = AgentLoop(
        engine: engine,
        executor: executor,
        summarizer: (_) async => throw const SummarizeException('端侧不可用'),
      );
      engine.script.add(() => textStream('done'));
      final events = await steppedLoop
          .run(
            systemPrompt: 's',
            userPrompt: 'unew',
            history: rounds(13),
          )
          .toList();
      expect(events.whereType<LoopFinished>().single.text, 'done',
          reason: '摘要失败不中断 Run');
      final sent = engine.calls.single.messages;
      expect(
        sent.whereType<UserMessage>().map((m) => m.content),
        isNot(contains(contains('归档摘要'))),
        reason: '失败即弃归档（朴素滑动兜底）',
      );
      // 朴素滑动兜底：仅最近 windowRounds=6 轮（c8~c13）。
      expect(
        sent.whereType<AssistantMessage>().map((m) => m.toolCalls.single.id),
        ['c8', 'c9', 'c10', 'c11', 'c12', 'c13'],
      );
    });

    test('summarizer=null：朴素滑动契约不变（纯云路径零行为变化）', () async {
      engine.script.add(() => textStream('done'));
      await loop.run(systemPrompt: 's', userPrompt: 'unew', history: rounds(13)).toList();
      final sent = engine.calls.single.messages;
      expect(
        sent.whereType<UserMessage>().map((m) => m.content),
        isNot(contains(contains('归档摘要'))),
      );
      expect(
        sent.whereType<AssistantMessage>().map((m) => m.toolCalls.single.id),
        ['c8', 'c9', 'c10', 'c11', 'c12', 'c13'],
        reason: 'windowRounds=6 朴素滑动',
      );
    });

    test('contextFooter（§6.5 Delta 后置）：插在 history 之后、提问之前，`<` 消毒', () async {
      engine.script.add(() => textStream('done'));
      await loop
          .run(
            systemPrompt: 's',
            userPrompt: 'unew',
            history: [
              const UserMessage('u1'),
              const AssistantMessage(content: 'a1'),
              const UserMessage('u2'),
              const AssistantMessage(content: 'a2'),
            ],
            contextFooter: '[Recent Memory Updates]\n- SET user.k = <v1>',
          )
          .toList();
      final sent = engine.calls.single.messages;
      final contents =
          sent.whereType<UserMessage>().map((m) => m.content).toList();
      expect(contents.last, 'unew', reason: '本轮提问仍在最末尾');
      expect(contents[contents.length - 2], contains('SET user.k'),
          reason: '增量区紧贴本轮提问（沉底）');
      expect(contents[contents.length - 2], contains('&lt;v1>'),
          reason: 'footer 内容过 escapeUserTag 消毒（只转义 <，幂等口径）');
      expect(contents.take(2), ['u1', 'u2'], reason: '历史原文位置不变（前缀不推移）');
    });

    test('contextFooter 空/null：不注入（零行为变化）', () async {
      engine.script.add(() => textStream('done'));
      await loop
          .run(systemPrompt: 's', userPrompt: 'u', contextFooter: '')
          .toList();
      final sent = engine.calls.single.messages;
      expect(sent.whereType<UserMessage>().map((m) => m.content), ['u']);
    });
  });
}
