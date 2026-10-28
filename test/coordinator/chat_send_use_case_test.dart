/// §S3 用例件单测：Run 时序下沉后，事件转发 / 预中止 / 收口释放的契约。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/chat_run_orchestrator.dart';
import 'package:goodhub/coordinator/chat_send_use_case.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:goodhub/sandbox/memory_store.dart';

class _CountingTransport implements McpTransport {
  int closeCount = 0;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final method = (jsonDecode(requestBody) as Map)['method'] as String?;
    Object? result;
    if (method == 'initialize') {
      result = {
        'protocolVersion': '2025-06-18',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'fake', 'version': '1.0'},
      };
    } else if (method == 'tools/list') {
      result = {
        'tools': [
          {'name': 'a'},
        ],
      };
    } else {
      result = {};
    }
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: const Stream<String>.empty(),
      );

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('no GET SSE');

  @override
  void close() => closeCount++;
}

class _ScriptedEngine implements CloudLlmEngine {
  final List<Stream<CloudStreamEvent> Function()> script = [];
  final List<CloudChatRequest> calls = [];

  @override
  String get name => 'scripted';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request,
      {void Function()? onActivity}) {
    calls.add(request);
    if (calls.length > script.length) {
      throw StateError('多出的一轮推理');
    }
    return script[calls.length - 1]();
  }
}

Stream<CloudStreamEvent> _text(String s) async* {
  yield CloudTextDelta(s);
  yield const CloudDone(finishReason: CloudFinishReason.stop);
}

/// 记录型渲染端口（断言转发顺序）。
class _RecordingSink implements ChatRunSink {
  final log = <String>[];

  @override
  void onThinking(String text) => log.add('think:$text');
  @override
  void onText(String text) => log.add('text:$text');
  @override
  void onCallStarted(covariant dynamic call) => log.add('started');
  @override
  void onCallProgress(call, num progress, num? total, String? message) =>
      log.add('progress:$progress');
  @override
  void onCallFinished(call, covariant dynamic result) => log.add('finished-call');
  @override
  void onFinished(String text, List<dynamic> transcript) =>
      log.add('done:$text');
}

Future<Directory> _tmp() async {
  final d = await Directory.systemTemp.createTemp('send_use_case_test');
  addTearDown(() => d.delete(recursive: true));
  return d;
}

void main() {
  Future<({McpAssembly assembly, List<McpTransport> transports})> assemble(
      {required CloudLlmEngine engine}) async {
    final transports = <McpTransport>[];
    final tmp = await _tmp();
    final assembly = await const McpRuntime().assemble(
      context: SessionContext(),
      endpoints: const [
        ServerEndpoint(id: 'good', name: 'g', endpoint: 'http://x/good/mcp'),
      ],
      locals: const [],
      apiKeyReader: (id) async => 'key-$id',
      memoryStore: MemoryStore.underSupportDir(tmp.path),
      skills: SkillRegistry()..registerAll(builtinSkills()),
      engine: engine,
      tempDirResolver: _tmp,
      documentsDirResolver: _tmp,
      clientFactory: (endpoint, apiKey) {
        final t = _CountingTransport();
        transports.add(t);
        return McpClient(t);
      },
    );
    return (assembly: assembly, transports: transports);
  }

  test('事件转发顺序 + 收口释放（close 恰好一次）', () async {
    final engine = _ScriptedEngine()..script.add(() => _text('你好'));
    final built = await assemble(engine: engine);
    final sink = _RecordingSink();
    final useCase = ChatSendUseCase(
      sink: sink,
      orchestrator: ChatRunOrchestrator(),
    );
    final tmp = await _tmp();

    await useCase.run(
      assembly: built.assembly,
      session: ConversationSession(),
      memoryStore: MemoryStore.underSupportDir(tmp.path),
      conversationId: 'c1',
      transcript: const [],
      skills: SkillRegistry()..registerAll(builtinSkills()),
      baseSystemPrompt: 'sys',
      userPrompt: 'hi',
      onCapsule: (key, value, action, scope, undo) {},
      onWriteFailure: null,
      onSlotNotice: (_) {},
      onAttribution: (_) {},
    );

    expect(sink.log, ['text:你好', 'done:你好'], reason: '事件按序转发到渲染端口');
    expect(
      built.transports.cast<_CountingTransport>().map((t) => t.closeCount).single,
      1,
      reason: '用例件 finally 收口：装配释放恰好一次',
    );
  });

  test('预中止（F19）：装配后先 abort 再 run → 正常收口，不抛', () async {
    final engine = _ScriptedEngine()..script.add(() => _text('x'));
    final built = await assemble(engine: engine);
    final sink = _RecordingSink();
    final useCase = ChatSendUseCase(
      sink: sink,
      orchestrator: ChatRunOrchestrator(),
    );
    final tmp = await _tmp();

    built.assembly.abort(reason: 'user abort (connecting phase)');
    await useCase.run(
      assembly: built.assembly,
      session: ConversationSession(),
      memoryStore: MemoryStore.underSupportDir(tmp.path),
      conversationId: 'c1',
      transcript: const [],
      skills: SkillRegistry()..registerAll(builtinSkills()),
      baseSystemPrompt: 'sys',
      userPrompt: 'hi',
      onCapsule: (key, value, action, scope, undo) {},
      onWriteFailure: null,
      onSlotNotice: (_) {},
      onAttribution: (_) {},
    );

    expect(sink.log.any((l) => l.startsWith('done:')), isTrue);
    expect(
      built.transports.cast<_CountingTransport>().map((t) => t.closeCount).single,
      1,
    );
  });

  test('cancel 幂等：无在途 Run 时调用不抛', () {
    final useCase = ChatSendUseCase(
      sink: _RecordingSink(),
      orchestrator: ChatRunOrchestrator(),
    );
    expect(() => useCase.cancel(), returnsNormally);
  });
}
