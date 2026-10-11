/// M3 sampling 消费面单测：D3 滑动窗口配额 + createMessage → 引擎单发映射。
/// ai-app-split.md §3.11（配额=20 次/60min 内存滑动窗口、maxTokens 宿主 clamp）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/sampling.dart';

/// 确定性引擎：聚合输入断言用（记录最后请求）+ 固定回复。
class _FakeEngine implements CloudLlmEngine {
  _FakeEngine(this.reply);

  final String reply;
  CloudChatRequest? lastRequest;

  @override
  String get name => 'fake-engine';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request) async* {
    lastRequest = request;
    yield CloudTextDelta(reply);
    yield const CloudDone(finishReason: CloudFinishReason.stop);
  }
}

void main() {
  group('SamplingQuota（D3）', () {
    test('窗口内 20 次全放行，第 21 次拒绝并给 retry hint', () {
      final q = SamplingQuota(maxPerWindow: 2, window: const Duration(minutes: 60));
      final t0 = DateTime(2026, 10, 11, 12);
      expect(q.tryConsume('goodshare', t0), isNull);
      expect(q.tryConsume('goodshare', t0.add(const Duration(minutes: 1))), isNull);
      final denial = q.tryConsume('goodshare', t0.add(const Duration(minutes: 2)));
      expect(denial, isNotNull, reason: '窗口满 → 拒绝');
      expect(denial!.inMinutes, 58, reason: 'retry 按窗口内最老一击计算');
    });

    test('滑动窗口：最老一击滚出窗口即恢复额度', () {
      final q = SamplingQuota(maxPerWindow: 1, window: const Duration(minutes: 60));
      final t0 = DateTime(2026, 10, 11, 12);
      expect(q.tryConsume('goodshare', t0), isNull);
      expect(q.tryConsume('goodshare', t0.add(const Duration(seconds: 30))), isNotNull);
      expect(q.tryConsume('goodshare', t0.add(const Duration(minutes: 61))), isNull,
          reason: '首击已滚出 60min 窗口');
    });

    test('per-server 隔离：不同 serverKey 互不挤占', () {
      final q = SamplingQuota(maxPerWindow: 1);
      final now = DateTime(2026, 10, 11, 12);
      expect(q.tryConsume('goodshare', now), isNull);
      expect(q.tryConsume('other-server', now), isNull);
    });
  });

  group('samplingRequestHandler', () {
    test('createMessage → 引擎单发（system+messages 映射）→ result 形状', () async {
      final engine = _FakeEngine('["标签A"]');
      final handler = samplingRequestHandler(
        engine: engine,
        quota: SamplingQuota(),
        serverKey: 'goodshare',
      );
      final result = await handler('sampling/createMessage', {
        'systemPrompt': '你是标签提取器。',
        'maxTokens': 256,
        'messages': [
          {
            'role': 'user',
            'content': {'type': 'text', 'text': '提取标签'},
          },
        ],
      });
      expect(result, isNotNull);
      expect(result!['role'], 'assistant');
      expect(result['model'], 'fake-engine');
      expect((result['content'] as Map)['text'], '["标签A"]');
      final req = engine.lastRequest!;
      expect(req.maxTokens, 256);
      expect(req.messages.first, isA<SystemMessage>());
      expect(req.messages.last, isA<UserMessage>());
    });

    test('maxTokens 超硬顶 → 宿主 clamp 到 kSamplingMaxTokensCap（D3）', () async {
      final engine = _FakeEngine('x');
      final handler = samplingRequestHandler(
          engine: engine, quota: SamplingQuota(), serverKey: 'goodshare');
      await handler('sampling/createMessage', {
        'maxTokens': 999999,
        'messages': [
          {'role': 'user', 'content': {'type': 'text', 'text': 'hi'}},
        ],
      });
      expect(engine.lastRequest!.maxTokens, kSamplingMaxTokensCap);
    });

    test('配额超限 → McpRpcException -32000 带 retry hint（结构化拒绝）', () async {
      final handler = samplingRequestHandler(
        engine: _FakeEngine('x'),
        quota: SamplingQuota(maxPerWindow: 1),
        serverKey: 'goodshare',
      );
      final params = {
        'messages': [
          {'role': 'user', 'content': {'type': 'text', 'text': 'hi'}},
        ],
      };
      await handler('sampling/createMessage', params);
      await expectLater(
        handler('sampling/createMessage', params),
        throwsA(isA<McpRpcException>().having(
            (e) => e.code, 'code', -32000).having(
            (e) => e.data, 'data', isNotNull)),
      );
    });

    test('未知反向请求 -32601；缺 messages -32602', () async {
      final handler = samplingRequestHandler(
          engine: _FakeEngine('x'), quota: SamplingQuota(), serverKey: 'goodshare');
      await expectLater(
          handler('resources/subscribe', null), throwsA(isA<McpRpcException>()));
      await expectLater(
          handler('sampling/createMessage', {'messages': []}),
          throwsA(isA<McpRpcException>()));
    });
  });
}
