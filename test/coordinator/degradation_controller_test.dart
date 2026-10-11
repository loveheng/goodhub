import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/degradation_controller.dart';

void main() {
  late DegradationController c;
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 10, 11, 12);
    c = DegradationController(now: () => now);
  });

  group('连续 5xx/429 判据', () {
    test('单次 5xx 不降级，连续 2 次降级', () {
      c.reportServerError(500);
      expect(c.health, CloudHealth.healthy);
      c.reportServerError(500);
      expect(c.health, CloudHealth.degraded);
    });

    test('429 计入；混算连续（5xx 后接 429 同样计满）', () {
      c.reportServerError(502);
      c.reportServerError(429);
      expect(c.health, CloudHealth.degraded);
    });

    test('401/403 等客户端错误不计入', () {
      c.reportServerError(401);
      c.reportServerError(403);
      c.reportServerError(400);
      expect(c.health, CloudHealth.healthy);
      expect(c.consecutiveServerErrors, 0);
    });

    test('成功复位计数（1 错 + 成功 + 1 错不降级）', () {
      c.reportServerError(500);
      c.reportSuccess();
      c.reportServerError(500);
      expect(c.health, CloudHealth.healthy);
      expect(c.consecutiveServerErrors, 1);
    });
  });

  group('传输超时判据', () {
    test('单次即降级', () {
      c.reportTransportTimeout();
      expect(c.health, CloudHealth.degraded);
    });
  });

  group('冷却与探活', () {
    test('降级后冷却期内不走云端；期满放行探活', () {
      c.reportTransportTimeout();
      now = now.add(const Duration(seconds: 10));
      expect(c.shouldUseCloud, isFalse);
      now = now.add(const Duration(seconds: 30));
      expect(c.shouldUseCloud, isTrue);
    });

    test('冷却期满探活成功 → 回归 healthy 并复位', () {
      c.reportTransportTimeout();
      now = now.add(const Duration(seconds: 31));
      expect(c.shouldUseCloud, isTrue);
      c.reportSuccess();
      expect(c.health, CloudHealth.healthy);
      expect(c.shouldUseCloud, isTrue);
    });

    test('健康态恒走云端', () {
      expect(c.shouldUseCloud, isTrue);
    });
  });
}
