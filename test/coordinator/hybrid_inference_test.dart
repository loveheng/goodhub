import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/hybrid_inference.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/goodshare_task_api.dart';

class CapturingEngine implements CloudLlmEngine {
  CloudChatRequest? lastRequest;
  String? next;

  @override
  String get name => 'capture';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request) async* {
    lastRequest = request;
    if (next != null) {
      yield CloudTextDelta(next!);
      yield const CloudDone(finishReason: CloudFinishReason.stop);
    }
  }
}

void main() {
  late CapturingEngine engine;
  late HybridTaskInference inference;

  setUp(() {
    engine = CapturingEngine();
    inference = HybridTaskInference(engine: engine);
  });

  ClaimedTask task(String text) => ClaimedTask(
        taskId: 't1',
        itemId: 'i1',
        taskAction: 'summarize',
        text: text,
        version: 3,
      );

  test('note 推理：action+text 进 prompt，产出 trim 后回传', () async {
    engine.next = '  这是摘要  ';
    final note = await inference.infer(task('一段内容'));
    expect(note, '这是摘要');
    final user = engine.lastRequest!.messages.whereType<UserMessage>().single;
    expect(user.content, contains('summarize'));
    expect(user.content, contains('一段内容'));
    expect(engine.lastRequest!.maxTokens, 512);
    expect(engine.lastRequest!.tools, isEmpty);
  });

  test('超长文本截断：prompt 声明 + note 尾注（禁静默截断）', () async {
    engine.next = 's';
    final long = HybridTaskInference(engine: engine, maxInputChars: 10);
    final note = await long.infer(task('a' * 30));
    final user = engine.lastRequest!.messages.whereType<UserMessage>().single;
    expect(user.content, contains('前 10 字'));
    expect(user.content, contains('a' * 10));
    expect(note, contains('仅处理前 10 字'));
  });

  test('空产出 → InferenceException（禁静默兜底）', () async {
    engine.next = '   ';
    await expectLater(
      inference.infer(task('x')),
      throwsA(isA<InferenceException>()),
    );
  });
}
