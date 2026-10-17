/// M3 sampling 消费面单测：D3 滑动窗口配额 + createMessage → 引擎单发映射。
/// ai-app-split.md §3.11（配额=20 次/60min 内存滑动窗口、maxTokens 宿主 clamp；
/// 2026-10-17 pool 分池：默认池 20 / instant 池 60，白名单制）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/core/chat_message_data.dart';
import 'package:goodhub/mcp/sampling.dart';

/// 确定性引擎：聚合输入断言用（记录最后请求）+ 固定回复。
class _FakeEngine implements SamplingEngine {
  _FakeEngine(this.reply);

  final String reply;
  List<ChatMessageData>? lastMessages;
  int? lastMaxTokens;

  @override
  String get name => 'fake-engine';

  @override
  Stream<String> sendText({
    required List<ChatMessageData> messages,
    required int maxTokens,
  }) async* {
    lastMessages = messages;
    lastMaxTokens = maxTokens;
    yield reply;
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

  group('SamplingQuota（pool 分池，2026-10-17）', () {
    test('默认构造 caps 含 instant 60（契约口径）', () {
      expect(SamplingQuota().caps['instant'], 60);
      expect(SamplingQuota().maxPerWindow, 20, reason: '默认池维持 20 不变');
    });

    test('pool 分池：instant 档独立计数，与默认池互不挤占', () {
      final q = SamplingQuota(maxPerWindow: 2, caps: const {'instant': 3});
      final t0 = DateTime(2026, 10, 11, 12);
      for (var i = 0; i < 3; i++) {
        expect(q.tryConsume('srv', t0, pool: 'instant'), isNull);
      }
      expect(q.tryConsume('srv', t0, pool: 'instant'), isNotNull, reason: 'instant 池满');
      expect(q.tryConsume('srv', t0), isNull, reason: '默认池独立未动');
      expect(q.tryConsume('srv', t0), isNull);
      expect(q.tryConsume('srv', t0), isNotNull, reason: '默认池满');
    });

    test('pool 白名单：未登记 pool 名/空串归默认池（防伪造池名绕过限额）', () {
      final q = SamplingQuota(maxPerWindow: 1);
      final t0 = DateTime(2026, 10, 11, 12);
      expect(q.tryConsume('srv', t0), isNull);
      expect(q.tryConsume('srv', t0, pool: 'fake-a'), isNotNull);
      expect(q.tryConsume('srv', t0, pool: 'fake-b'), isNotNull);
      expect(q.tryConsume('srv', t0, pool: ''), isNotNull);
      expect(q.tryConsume('srv', t0, pool: null), isNotNull);
    });

    test('分池 per-server 隔离：instant 额度按 serverKey 独立', () {
      final q = SamplingQuota(maxPerWindow: 20, caps: const {'instant': 1});
      final t0 = DateTime(2026, 10, 11, 12);
      expect(q.tryConsume('a', t0, pool: 'instant'), isNull);
      expect(q.tryConsume('b', t0, pool: 'instant'), isNull, reason: '不同 server 各 1 次');
      expect(q.tryConsume('a', t0, pool: 'instant'), isNotNull);
    });

    test('snapshotHits/restoreHits 跨 pool key 兼容（落盘恢复）', () {
      final q = SamplingQuota(maxPerWindow: 2, caps: const {'instant': 3});
      final t0 = DateTime(2026, 10, 11, 12);
      q.tryConsume('srv', t0);
      q.tryConsume('srv', t0, pool: 'instant');
      q.tryConsume('srv', t0, pool: 'instant');
      final snap = q.snapshotHits(t0);
      expect(snap.keys, containsAll(['srv', 'srv:instant']));
      final q2 = SamplingQuota(maxPerWindow: 2, caps: const {'instant': 3});
      q2.restoreHits(snap);
      expect(q2.tryConsume('srv', t0), isNull, reason: '默认池恢复后余 1');
      expect(q2.tryConsume('srv', t0), isNotNull);
      expect(q2.tryConsume('srv', t0, pool: 'instant'), isNull, reason: 'instant 恢复后余 1');
      expect(q2.tryConsume('srv', t0, pool: 'instant'), isNotNull);
      expect(q2.tryConsume('srv', t0, pool: 'instant'), isNotNull);
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
      final msgs = engine.lastMessages!;
      expect(engine.lastMaxTokens, 256);
      expect(msgs.first, isA<SystemChatMessage>());
      expect(msgs.last, isA<UserChatMessage>());
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
      expect(engine.lastMaxTokens, kSamplingMaxTokensCap);
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

    test('pool 分池（handler 透传）：默认池满后 pool=instant 仍放行', () async {
      final handler = samplingRequestHandler(
        engine: _FakeEngine('x'),
        quota: SamplingQuota(maxPerWindow: 1, caps: const {'instant': 2}),
        serverKey: 'goodshare',
      );
      final base = <String, Object?>{
        'messages': [
          {'role': 'user', 'content': {'type': 'text', 'text': 'hi'}},
        ],
      };
      await handler('sampling/createMessage', base); // 默认池 1/1 满
      await expectLater(
        handler('sampling/createMessage', base),
        throwsA(isA<McpRpcException>().having((e) => e.code, 'code', -32000)),
        reason: '默认池满 → 拒',
      );
      await handler('sampling/createMessage', {...base, 'pool': 'instant'});
      await handler('sampling/createMessage', {...base, 'pool': 'instant'});
      await expectLater(
        handler('sampling/createMessage', {...base, 'pool': 'instant'}),
        throwsA(isA<McpRpcException>().having((e) => e.code, 'code', -32000)),
        reason: 'instant 池 2/2 满 → 拒',
      );
    });

    test('pool 非 String / 未登记名 → 归默认池（handler 侧）', () async {
      final handler = samplingRequestHandler(
        engine: _FakeEngine('x'),
        quota: SamplingQuota(maxPerWindow: 1),
        serverKey: 'goodshare',
      );
      final base = <String, Object?>{
        'messages': [
          {'role': 'user', 'content': {'type': 'text', 'text': 'hi'}},
        ],
      };
      await handler('sampling/createMessage', base); // 默认池 1/1 满
      await expectLater(
        handler('sampling/createMessage', {...base, 'pool': 123}),
        throwsA(isA<McpRpcException>().having((e) => e.code, 'code', -32000)),
        reason: 'pool 非 String → 默认池已满',
      );
      await expectLater(
        handler('sampling/createMessage', {...base, 'pool': 'fake'}),
        throwsA(isA<McpRpcException>().having((e) => e.code, 'code', -32000)),
        reason: '未登记 pool 名 → 默认池已满',
      );
    });
  });
}
