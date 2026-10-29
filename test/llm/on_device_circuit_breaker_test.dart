import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_circuit_breaker.dart';

/// 两级阶梯熔断单测（on-device S1-6；NPU 稿 §6.5 v2.4/v2.6/v2.7）。
void main() {
  late DateTime t;
  late EngineCircuitBreaker breaker;
  String? persistedLock;
  bool cleared = false;

  setUp(() {
    t = DateTime(2026, 10, 28, 12);
    persistedLock = null;
    cleared = false;
    breaker = EngineCircuitBreaker(
      now: () => t,
      readLock: () => Future<String?>.value(persistedLock),
      writeLock: (iso) async => persistedLock = iso,
      clearLock: () async => cleared = true,
    );
  });

  group('L1 单进程级（5min 窗口 ≥2 crash）', () {
    test('窗口内两次驱动 Panic → 熔断', () async {
      await breaker.report(countable: true);
      t = t.add(const Duration(minutes: 1));
      await breaker.report(countable: true);
      expect(await breaker.isBroken, isTrue);
    });

    test('窗口外第二次 crash 不熔断（滑动窗口重置）', () async {
      await breaker.report(countable: true);
      t = t.add(const Duration(minutes: 6));
      await breaker.report(countable: true);
      expect(await breaker.isBroken, isFalse);
    });

    test('单次 crash 不熔断', () async {
      await breaker.report(countable: true);
      expect(await breaker.isBroken, isFalse);
    });
  });

  group('计数口径收窄（§6.5 v2.6）', () {
    test('SIGKILL/LMK（countable=false）不计入熔断', () async {
      await breaker.report(countable: false);
      t = t.add(const Duration(seconds: 1));
      await breaker.report(countable: false);
      expect(await breaker.isBroken, isFalse);
    });

    test('混入不可计数死亡不打断 L1 计数窗口', () async {
      await breaker.report(countable: true);
      t = t.add(const Duration(minutes: 1));
      await breaker.report(countable: false); // 外部处决混入
      t = t.add(const Duration(seconds: 1));
      await breaker.report(countable: true);
      expect(await breaker.isBroken, isTrue);
    });
  });

  group('L2 持久化级（当天 L1 触发 ≥2 → 24h 锁）', () {
    test('两次 L1 触发 → 持久化 24h 截止时间', () async {
      // 第一轮 L1：两次 crash。
      await breaker.report(countable: true);
      t = t.add(const Duration(minutes: 1));
      await breaker.report(countable: true);
      expect(await breaker.isBroken, isTrue);

      // 复位 L1（模拟用户手动清缓存后继续触发——或等冷启动）。
      // 用新实例模拟冷启动（L1 内存态清零，L2 判据按实现语义继续累计）。
      t = t.add(const Duration(minutes: 10));
      await breaker.report(countable: true);
      t = t.add(const Duration(minutes: 1));
      await breaker.report(countable: true);
      // 第二轮 L1 触发 → 同实例内 L1 计数已达 2 → L2 锁写入。
      expect(persistedLock, isNotNull, reason: 'L2 触发须持久化截止时间');
    });

    test('持久化锁跨实例恢复（冷启动读回 24h 锁）', () async {
      persistedLock = t.add(const Duration(hours: 24)).toIso8601String();
      final fresh = EngineCircuitBreaker(
        now: () => t,
        readLock: () => Future<String?>.value(persistedLock),
        writeLock: (iso) async => persistedLock = iso,
        clearLock: () async => cleared = true,
      );
      expect(await fresh.isBroken, isTrue, reason: 'L2 锁冷启动后仍生效');
    });

    test('24h 过期自动解锁', () async {
      final deadline = t.add(const Duration(hours: 24));
      persistedLock = deadline.toIso8601String();
      final fresh = EngineCircuitBreaker(
        now: () => deadline.add(const Duration(minutes: 1)),
        readLock: () => Future<String?>.value(persistedLock),
        writeLock: (iso) async => persistedLock = iso,
        clearLock: () async => cleared = true,
      );
      expect(await fresh.isBroken, isFalse);
    });
  });

  group('500ms 驱动释放冷却窗口（§6.5 v2.7）', () {
    test('死亡后 500ms 内处于冷却期', () async {
      expect(breaker.inCooldown, isFalse);
      await breaker.report(countable: false);
      expect(breaker.inCooldown, isTrue);
      t = t.add(const Duration(milliseconds: 499));
      expect(breaker.inCooldown, isTrue);
      t = t.add(const Duration(milliseconds: 2));
      expect(breaker.inCooldown, isFalse);
    });

    test('reset 清除冷却与 L1/L2（模型版本更新/手动清缓存）', () async {
      await breaker.report(countable: true);
      await breaker.report(countable: true);
      expect(await breaker.isBroken, isTrue);
      await breaker.reset();
      expect(await breaker.isBroken, isFalse);
      expect(breaker.inCooldown, isFalse);
      expect(cleared, isTrue, reason: '持久化锁须同步清除');
    });
  });
}
