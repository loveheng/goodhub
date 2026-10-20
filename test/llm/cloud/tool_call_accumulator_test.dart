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
    expect(() => acc.toolCalls, throwsA(isA<CloudProtocolException>()));
  });

  test('空名 tool_call 丢弃不抛错，同轮有效调用照常结算', () {
    final acc = CloudStreamAccumulator()
      ..add(const CloudToolCallDelta(index: 0, id: 'bad', name: ''))
      ..add(const CloudToolCallDelta(index: 0, argumentsDelta: '{"a":1}'))
      ..add(const CloudToolCallDelta(index: 1, id: 'ok', name: 'f'))
      ..add(const CloudToolCallDelta(index: 1, argumentsDelta: '{}'))
      ..add(const CloudDone(finishReason: CloudFinishReason.toolCalls));

    final calls = acc.toolCalls;
    expect(calls, hasLength(1), reason: '空名畸形调用不计入成品');
    expect(calls.single.id, 'ok');
    expect(calls.single.name, 'f');
    // toAssistantMessage 同口径：历史不同步空名调用（回放无失配 tool 消息）。
    expect(acc.toAssistantMessage().toolCalls.map((c) => c.name), ['f']);
  });

  test('首帧真名 + 后续分片帧重复空名 → 保留真名（GLM 系实测形态）', () {
    // SiliconFlow `zai-org/GLM-5.3-Flash` 实测：首帧带 name=math_utility，
    // 其后每个 arguments 分片仍重复携带 name:"" —— 无条件覆盖会把真名冲成
    // 空串，结算即按畸形调用丢弃（整轮「空名 tool_call」、工具永不执行）。
    final acc = CloudStreamAccumulator()
      ..add(const CloudToolCallDelta(index: 0, id: 'a', name: 'math_utility'))
      ..add(const CloudToolCallDelta(index: 0, name: '', argumentsDelta: '{"ac'))
      ..add(const CloudToolCallDelta(
          index: 0, name: '', argumentsDelta: 'tion":"add"}'))
      ..add(const CloudDone(finishReason: CloudFinishReason.toolCalls));

    final calls = acc.toolCalls;
    expect(calls, hasLength(1), reason: '真名不得被分片帧空串覆盖成畸形调用');
    expect(calls.single.name, 'math_utility');
    expect(calls.single.argumentsJson, '{"action":"add"}');
  });

  test('纯空白名同样丢弃；缺 name 仍按协议违规抛错（不扩大化）', () {
    final blank = CloudStreamAccumulator()
      ..add(const CloudToolCallDelta(index: 0, id: 'bad', name: '   '))
      ..add(const CloudDone(finishReason: CloudFinishReason.toolCalls));
    expect(blank.toolCalls, isEmpty, reason: 'trim 后为空即丢弃');

    final missing = CloudStreamAccumulator()
      ..add(const CloudToolCallDelta(index: 0, id: 'x'))
      ..add(const CloudDone(finishReason: CloudFinishReason.toolCalls));
    expect(() => missing.toolCalls, throwsA(isA<CloudProtocolException>()),
        reason: '缺 name（null）与空名是两回事：前者仍是协议违规');
  });
}
