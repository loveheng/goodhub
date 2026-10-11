import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/cloud_llm_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/cloud/tool_call_accumulator.dart';

void main() {
  test('分片参数拼接 + 多调用按 index 升序', () {
    final acc = CloudStreamAccumulator()
      ..add(const CloudTextDelta('正在调用'))
      ..add(const CloudToolCallDelta(index: 1, id: 'b', name: 'g'))
      ..add(const CloudToolCallDelta(index: 1, argumentsDelta: '{"y":'))
      ..add(const CloudToolCallDelta(index: 1, argumentsDelta: '2}'))
      ..add(const CloudToolCallDelta(index: 0, id: 'a', name: 'f'))
      ..add(const CloudToolCallDelta(index: 0, argumentsDelta: '{"x":1}'))
      ..add(const CloudDone(finishReason: CloudFinishReason.toolCalls));

    expect(acc.text, '正在调用');
    final calls = acc.toolCalls;
    expect(calls, hasLength(2));
    expect(calls[0].id, 'a');
    expect(calls[0].argumentsJson, '{"x":1}');
    expect(calls[1].id, 'b');
    expect(calls[1].argumentsJson, '{"y":2}');
    expect(acc.finishReason, CloudFinishReason.toolCalls);
  });

  test('drain 顺序消费整个流', () async {
    final acc = await CloudStreamAccumulator.drain(Stream.fromIterable([
      const CloudTextDelta('a'),
      const CloudTextDelta('b'),
      const CloudDone(finishReason: CloudFinishReason.stop, usage: CloudUsage(promptTokens: 3, completionTokens: 2)),
    ]));
    expect(acc.text, 'ab');
    expect(acc.finishReason, CloudFinishReason.stop);
    expect(acc.usage?.promptTokens, 3);
  });

  test('toAssistantMessage：空正文为 null、toolCalls 成品', () {
    final acc = CloudStreamAccumulator()
      ..add(const CloudToolCallDelta(index: 0, id: 'a', name: 'f'))
      ..add(const CloudToolCallDelta(index: 0, argumentsDelta: '{}'))
      ..add(const CloudDone(finishReason: CloudFinishReason.toolCalls));
    final msg = acc.toAssistantMessage();
    expect(msg.content, isNull);
    expect(msg.toolCalls.single.name, 'f');
  });

  test('流结束仍缺 id/name → CloudProtocolException（结算点暴露，禁兜底）', () {
    final acc = CloudStreamAccumulator()
      ..add(const CloudToolCallDelta(index: 0, argumentsDelta: '{}'));
    expect(acc.toolCalls, throwsA(isA<CloudProtocolException>()));
  });
}
