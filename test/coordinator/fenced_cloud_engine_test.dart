/// N7 围栏云引擎装饰器单测（M2-T5b）：D1 全量出站遮蔽、D2 跨 send 同值
/// 同号、D5 流式还原（正文/工具入参/Done 前冲刷）、D4 失败三路径
/// （无人值守 fail-closed / 拒绝 / 明文一次）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/fenced_cloud_engine.dart';
import 'package:goodhub/coordinator/pii_fence.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

/// 捕获出站请求并按脚本回放的假云引擎（与 agent_loop 测试假件同构）。
class _CapturingEngine implements CloudLlmEngine {
  _CapturingEngine(this.script);

  final List<CloudStreamEvent> script;
  final requests = <CloudChatRequest>[];

  @override
  String get name => 'capturing';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) async* {
    requests.add(request);
    for (final e in script) {
      yield e;
    }
  }
}

class _ApproveDelegate implements PiiFenceDelegate {
  _ApproveDelegate(this.decision);

  final bool decision;
  var calls = 0;

  @override
  Future<bool> onMaskBlocked(PiiMaskBlockInfo info) async {
    calls++;
    return decision;
  }
}

Future<List<CloudStreamEvent>> _collect(Stream<CloudStreamEvent> s) =>
    s.toList();

String _text(List<CloudStreamEvent> events) => events
    .whereType<CloudTextDelta>()
    .map((e) => e.text)
    .join();

String _thinking(List<CloudStreamEvent> events) => events
    .whereType<CloudThinkingDelta>()
    .map((e) => e.text)
    .join();

void main() {
  const phone = '13812345678';
  const email = 'a@b.com';

  group('出站遮蔽 · D1/D2', () {
    test('全量消息遮蔽：系统跳过/用户/工具结果/助手入参历史 同值同号', () async {
      final inner = _CapturingEngine(
          [const CloudDone(finishReason: CloudFinishReason.stop)]);
      final engine = FencedCloudEngine(inner: inner);
      await _collect(engine.send(const CloudChatRequest(messages: [
        SystemMessage('系统提示无敏感'),
        UserMessage('联系 $phone'),
        ToolResultMessage(toolCallId: 't1', content: '结果 $phone'),
        AssistantMessage(content: '回复 $phone', toolCalls: [
          AssembledToolCall(
              id: 't1', name: 'x', argumentsJson: '{"q":"$phone"}'),
        ]),
      ])));

      final sent = inner.requests.single;
      expect((sent.messages[0] as SystemMessage).content, '系统提示无敏感');
      expect((sent.messages[1] as UserMessage).content, '联系 [手机号1]');
      expect((sent.messages[2] as ToolResultMessage).content, '结果 [手机号1]');
      final assistant = sent.messages[3] as AssistantMessage;
      expect(assistant.content, '回复 [手机号1]');
      expect(assistant.toolCalls.single.argumentsJson, '{"q":"[手机号1]"}');
    });

    test('tools/temperature/maxTokens 原样透传', () async {
      final inner = _CapturingEngine(
          [const CloudDone(finishReason: CloudFinishReason.stop)]);
      final engine = FencedCloudEngine(inner: inner);
      const schema = CloudToolSchema(
          name: 't', description: 'd', parametersSchema: {'type': 'object'});
      await _collect(engine.send(const CloudChatRequest(
        messages: [UserMessage('hi $phone')],
        tools: [schema],
        temperature: 0.3,
        maxTokens: 128,
      )));

      final sent = inner.requests.single;
      expect(identical(sent.tools.single, schema), isTrue);
      expect(sent.temperature, 0.3);
      expect(sent.maxTokens, 128);
    });

    test('跨 send 同值同号（D2：会话粒度映射稳定）', () async {
      final inner = _CapturingEngine([
        const CloudDone(finishReason: CloudFinishReason.stop),
        const CloudDone(finishReason: CloudFinishReason.stop),
      ]);
      final engine = FencedCloudEngine(inner: inner);
      await _collect(engine.send(const CloudChatRequest(
          messages: [UserMessage('一号 $phone')])));
      await _collect(engine.send(const CloudChatRequest(
          messages: [UserMessage('二号 $phone')])));

      expect((inner.requests[0].messages.single as UserMessage).content,
          '一号 [手机号1]');
      expect((inner.requests[1].messages.single as UserMessage).content,
          '二号 [手机号1]');
    });

    test('engine.name 带 fenced 前缀（轨道引擎名可观测）', () {
      final engine = FencedCloudEngine(inner: _CapturingEngine(const []));
      expect(engine.name, 'fenced(capturing)');
    });
  });

  group('入站还原 · D5', () {
    test('正文 delta 占位符跨片切分后整体还原', () async {
      final inner = _CapturingEngine(const [
        CloudTextDelta('手机号是[手机'),
        CloudTextDelta('号1]，请查收'),
        CloudDone(finishReason: CloudFinishReason.stop),
      ]);
      final engine = FencedCloudEngine(inner: inner);
      final events = await _collect(engine.send(CloudChatRequest(
          messages: [UserMessage('查 $phone')])));
      expect(_text(events), '手机号是$phone，请查收');
    });

    test('工具入参按 index 独立还原（并行调用不串缓冲）', () async {
      final inner = _CapturingEngine(const [
        CloudToolCallDelta(
            index: 0, id: 'a', name: 't', argumentsDelta: '{"q":"[手机'),
        CloudToolCallDelta(index: 1, id: 'b', name: 'u', argumentsDelta: '{"w":"[邮箱1]"}'),
        CloudToolCallDelta(index: 0, argumentsDelta: '号1]"}'),
        CloudDone(finishReason: CloudFinishReason.toolCalls),
      ]);
      final engine = FencedCloudEngine(inner: inner);
      final events = await _collect(engine.send(CloudChatRequest(
          messages: [UserMessage('查 $phone 和 $email')])));

      final args = <int, StringBuffer>{};
      for (final e in events.whereType<CloudToolCallDelta>()) {
        (args[e.index] ??= StringBuffer()).write(e.argumentsDelta);
      }
      expect(args[0].toString(), '{"q":"$phone"}');
      expect(args[1].toString(), '{"w":"$email"}');
    });

    test('Done 前冲刷：未完括号组按字面量收尾（无 PII 泄露）', () async {
      final inner = _CapturingEngine(const [
        CloudTextDelta('结尾[手机号1'),
        CloudDone(finishReason: CloudFinishReason.stop),
      ]);
      final engine = FencedCloudEngine(inner: inner);
      final events = await _collect(engine.send(CloudChatRequest(
          messages: [UserMessage('查 $phone')])));

      expect(_text(events), '结尾[手机号1',
          reason: '流末截断的占位符永远等不到 ]，按字面量外发；不含原值');
      expect(events.whereType<CloudDone>().length, 1, reason: '每流恰一 Done');
    });
  });

  group('失败拦截 · D4', () {
    Future<String> boom(String _) async =>
        throw const PiiMaskException('遮蔽超时（3s）');

    test('无 delegate = fail-closed 拦截，请求绝不外发', () async {
      final inner = _CapturingEngine(const []);
      final engine = FencedCloudEngine(inner: inner, maskOverride: boom);
      await expectLater(
        engine.send(const CloudChatRequest(
            messages: [UserMessage('含 PII $phone')])),
        emitsError(isA<PiiSendBlockedException>()),
      );
      expect(inner.requests, isEmpty);
    });

    test('delegate 拒绝 = 拦截且内层不被调用', () async {
      final inner = _CapturingEngine(const []);
      final delegate = _ApproveDelegate(false);
      final engine = FencedCloudEngine(
          inner: inner, delegate: delegate, maskOverride: boom);
      await expectLater(
        engine.send(const CloudChatRequest(
            messages: [UserMessage('含 PII $phone')])),
        emitsError(isA<PiiSendBlockedException>()),
      );
      expect(delegate.calls, 1);
      expect(inner.requests, isEmpty);
    });

    test('delegate 明文确认 = 原请求发送一次（不记忆，下次失败再确认）', () async {
      final inner = _CapturingEngine(
          [const CloudDone(finishReason: CloudFinishReason.stop)]);
      final delegate = _ApproveDelegate(true);
      final engine = FencedCloudEngine(
          inner: inner, delegate: delegate, maskOverride: boom);
      await _collect(engine.send(const CloudChatRequest(
          messages: [UserMessage('含 PII $phone')])));

      expect(delegate.calls, 1);
      expect((inner.requests.single.messages.single as UserMessage).content,
          '含 PII $phone',
          reason: '用户显式确认后仅本次明文放行');
    });
  });

  group('思考流透传（2026-10-21 M1，展示 only）', () {
    test('CloudThinkingDelta 原样放行（无遮蔽时零行为变化）', () async {
      final inner = _CapturingEngine(const [
        CloudThinkingDelta('想'),
        CloudTextDelta('答'),
        CloudDone(finishReason: CloudFinishReason.stop),
      ]);
      final engine = FencedCloudEngine(inner: inner);
      final events = await _collect(engine.send(
          const CloudChatRequest(messages: [UserMessage('u')])));
      expect(_thinking(events), '想');
      expect(_text(events), '答');
    });

    test('思考流独立 restorer：占位符还原不与正文流串缓冲', () async {
      // 出站请求含 PII → 被遮蔽；模型思考复述占位符 → 思考流独立还原。
      final inner = _CapturingEngine(const [
        CloudThinkingDelta('用户电话是[手机'),
        CloudThinkingDelta('号1]，先记住'),
        CloudTextDelta('好的'),
        CloudDone(finishReason: CloudFinishReason.stop),
      ]);
      final engine = FencedCloudEngine(inner: inner);
      final events = await _collect(engine.send(
          const CloudChatRequest(messages: [UserMessage('含 PII $phone')])));
      expect(_thinking(events), '用户电话是$phone，先记住',
          reason: '思考流占位符跨片还原（独立缓冲，不串正文流）');
      expect(_text(events), '好的');
    });

    test('思考流在 Done 前冲刷（flush 产物先于 Done 抵达）', () async {
      // 未完占位符（[手机 缺号1]）按字面量收尾——D5 同口径：无 PII 泄露，
      // flush 把扣留缓冲放行后再放 Done（事件顺序契约）。
      final inner = _CapturingEngine(const [
        CloudThinkingDelta('结尾思考[手机'),
        CloudDone(finishReason: CloudFinishReason.stop),
      ]);
      final engine = FencedCloudEngine(inner: inner);
      final events = await _collect(engine.send(
          const CloudChatRequest(messages: [UserMessage('含 PII $phone')])));
      expect(events.whereType<CloudDone>(), hasLength(1));
      final doneIdx = events.indexWhere((e) => e is CloudDone);
      final lastThinking =
          events.lastIndexWhere((e) => e is CloudThinkingDelta);
      expect(lastThinking, lessThan(doneIdx),
          reason: '思考 flush 产物先于 Done（事件顺序契约）');
      expect(_thinking(events), '结尾思考[手机',
          reason: '未完占位符按字面量收尾，绝不泄漏还原值');
    });
  });
}
