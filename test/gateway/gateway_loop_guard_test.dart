/// 网关环路防护（A2 止血，SA-Q5 双保险）单测：平级并发不误杀 / 嵌套回环
/// 拦截 / 深度熔断 / finally 释放 / 引用计数 / TTL 惰性驱逐。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/gateway/gateway_loop_guard.dart';

void main() {
  group('入站判定', () {
    test('平级并发：同一 Trace-ID、hop=0 的多请求互不误杀（Agent Turn 复用头）',
        () {
      final g = GatewayLoopGuard();
      expect(g.checkInbound(traceId: 'T', hopCount: 0), isNull);
      g.acquire('T');
      expect(g.checkInbound(traceId: 'T', hopCount: 0), isNull);
      g.acquire('T');
      expect(g.checkInbound(traceId: 'T', hopCount: 0), isNull);
      expect(g.inFlightCount, 1); // 引用计数合并在途
    });

    test('嵌套回环：hop>0 且 traceId 在途 → 拦截', () {
      final g = GatewayLoopGuard();
      g.acquire('T');
      final blocked = g.checkInbound(traceId: 'T', hopCount: 1);
      expect(blocked, isNotNull);
      expect(blocked, contains('嵌套回环'));
    });

    test('深度熔断：hop=3 超过上限 2（即便 traceId 被下游重置）', () {
      final g = GatewayLoopGuard();
      expect(g.checkInbound(traceId: 'A', hopCount: 2), isNull);
      final blocked = g.checkInbound(traceId: 'B', hopCount: 3);
      expect(blocked, isNotNull);
      expect(blocked, contains('超过上限'));
    });
  });

  group('在途集合生命周期', () {
    test('finally 释放后不再拦截（正常收尾路径）', () {
      final g = GatewayLoopGuard();
      g.acquire('T');
      g.release('T');
      expect(g.inFlightCount, 0);
      expect(g.checkInbound(traceId: 'T', hopCount: 1), isNull);
    });

    test('引用计数：两个并发同 traceId，只释放一次仍判在途', () {
      final g = GatewayLoopGuard();
      g.acquire('T');
      g.acquire('T');
      g.release('T');
      expect(g.inFlightCount, 1);
      expect(g.checkInbound(traceId: 'T', hopCount: 1), isNotNull);
    });

    test('TTL 惰性驱逐：假时钟推进后记录在途失效（防假死永久封锁）', () {
      var now = DateTime(2026, 10, 15);
      final g = GatewayLoopGuard(clock: () => now);
      g.acquire('T');
      now = now.add(const Duration(seconds: 301));
      expect(g.checkInbound(traceId: 'T', hopCount: 1), isNull);
      expect(g.inFlightCount, 0);
    });

    test('TTL 未到期不驱逐（45s 确认窗内的长任务仍受保护）', () {
      var now = DateTime(2026, 10, 15);
      final g = GatewayLoopGuard(clock: () => now);
      g.acquire('T');
      now = now.add(const Duration(seconds: 60));
      expect(g.checkInbound(traceId: 'T', hopCount: 1), isNotNull);
    });

    test('未登记的 traceId 即便 hop>0 也放行（第三方直连不误伤）', () {
      final g = GatewayLoopGuard();
      expect(g.checkInbound(traceId: 'unknown', hopCount: 1), isNull);
    });
  });

  group('traceId 自派', () {
    test('newTraceId 单调唯一', () {
      var now = DateTime(2026, 10, 15);
      final g = GatewayLoopGuard(clock: () => now);
      final a = g.newTraceId();
      final b = g.newTraceId();
      expect(a, isNot(b));
      expect(a, startsWith('gw-'));
    });
  });
}
