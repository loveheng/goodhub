import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_circuit_breaker.dart';

/// 两级阶梯熔断单测（on-device S1-6；NPU 稿 §6.5 v2.4/v2.6/v2.7）。
void main() {
  late DateTime t;
  late EngineCircuitBreaker breaker;
  String? persistedLock;
  String? persistedL1Triggers;
  bool cleared = false;

  setUp(() {
    t = DateTime(2026, 10, 28, 12);
    persistedLock = null;
    persistedL1Triggers = null;
    cleared = false;
    breaker = EngineCircuitBreaker(
      now: () => t,
      readLock: () => Future<String?>.value(persistedLock),
      writeLock: (iso) async => persistedLock = iso,
      clearLock: () async => cleared = true,
      readL1Triggers: () => Future<String?>.value(persistedL1Triggers),
      writeL1Triggers: (list) async => persistedL1Triggers = list.join('|'),
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
        readL1Triggers: () => Future<String?>.value(persistedL1Triggers),
        writeL1Triggers: (list) async => persistedL1Triggers = list.join('|'),
      );
      expect(await fresh.isBroken, isFalse);
    });

    test('P2-9：稀疏 L1 跨重启同日累计 → L2（旧内存计数永不达 L2 的主画像）',
        () async {
      // 第一次进程生命周期：当天上午触发一次 L1 后进程被杀。
      await breaker.report(countable: true);
      t = t.add(const Duration(minutes: 1));
      await breaker.report(countable: true); // L1 触发 #1，时间戳持久化
      expect(persistedL1Triggers, isNotNull);
      expect(persistedLock, isNull, reason: '仅 1 次 L1 不得触发 L2');

      // 第二次进程生命周期（冷启动，间隔 >5min 但同日）：恢复持久化列表。
      t = t.add(const Duration(hours: 1));
      final fresh = EngineCircuitBreaker(
        now: () => t,
        readLock: () => Future<String?>.value(persistedLock),
        writeLock: (iso) async => persistedLock = iso,
        clearLock: () async => cleared = true,
        readL1Triggers: () => Future<String?>.value(persistedL1Triggers),
        writeL1Triggers: (list) async => persistedL1Triggers = list.join('|'),
      );
      await fresh.report(countable: true);
      t = t.add(const Duration(minutes: 1));
      await fresh.report(countable: true); // L1 触发 #2 → 同日累计达 2 → L2
      expect(persistedLock, isNotNull, reason: '跨重启同日 2 次 L1 须触发 L2');
      expect(await fresh.isBroken, isTrue);
    });

    test('P2-9：跨自然日的 L1 触发不累计（日界剪枝）', () async {
      // 昨天（前一日 23:xx）触发 L1 一次并持久化。
      t = DateTime(2026, 10, 27, 23, 50);
      await breaker.report(countable: true);
      t = t.add(const Duration(minutes: 1));
      await breaker.report(countable: true); // L1 #1（前一日）
      final yesterdayStamp = persistedL1Triggers;
      expect(yesterdayStamp, isNotNull);

      // 次日新进程：恢复后剪枝前一日时间戳，当天 2 次 crash 仅触发 L1。
      t = DateTime(2026, 10, 28, 12);
      final fresh = EngineCircuitBreaker(
        now: () => t,
        readLock: () => Future<String?>.value(persistedLock),
        writeLock: (iso) async => persistedLock = iso,
        clearLock: () async => cleared = true,
        readL1Triggers: () => Future<String?>.value(persistedL1Triggers),
        writeL1Triggers: (list) async => persistedL1Triggers = list.join('|'),
      );
      await fresh.report(countable: true);
      t = t.add(const Duration(minutes: 1));
      await fresh.report(countable: true); // 当天仅 1 次 L1 → 不达 L2
      expect(await fresh.isBroken, isTrue, reason: 'L1 内存熔断照旧生效');
      expect(persistedLock, isNull, reason: '跨日旧触发须被剪枝，不推进 L2');
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

  group('事件留痕 lastEventReason（IRIDIS 对照：reason 随下次动作打日志）', () {
    test('无上报历史 = null', () {
      expect(breaker.lastEventReason, isNull);
    });

    test('report 留痕携带 countable 与死因', () async {
      await breaker.report(countable: false, reason: 'onProcessDied(SIGKILL)');
      expect(breaker.lastEventReason, contains('countable=false'));
      expect(breaker.lastEventReason, contains('onProcessDied(SIGKILL)'));
    });

    test('L1 触发覆盖为 trip 留痕', () async {
      await breaker.report(countable: true, reason: 'onEngineDied');
      t = t.add(const Duration(minutes: 1));
      await breaker.report(countable: true, reason: 'onEngineDied');
      expect(breaker.lastEventReason, startsWith('L1 trip'));
      expect(breaker.lastEventReason, contains('onEngineDied'));
    });

    test('L2 触发覆盖为 24h 锁留痕', () async {
      // L2 判据 = 当日 2 次 L1 触发；每次 L1 需窗口内 2 次 crash → 共 4 轮。
      for (var i = 0; i < 4; i++) {
        await breaker.report(countable: true);
        t = t.add(const Duration(minutes: 1));
      }
      expect(breaker.lastEventReason, startsWith('L2 trip'));
    });
  });

  group('L2 解锁接 driverFingerprint（timeout-signaling W1-1）', () {
    late String? persistedLockFp;
    late String? currentFp;
    bool fpCleared = false;
    late EngineCircuitBreaker fpBreaker;

    setUp(() {
      persistedLock = null;
      persistedLockFp = null;
      currentFp = 'fp-A';
      fpCleared = false;
      fpBreaker = EngineCircuitBreaker(
        now: () => t,
        readLock: () => Future<String?>.value(persistedLock),
        writeLock: (iso) async => persistedLock = iso,
        clearLock: () async => cleared = true,
        readL1Triggers: () => Future<String?>.value(persistedL1Triggers),
        writeL1Triggers: (list) async => persistedL1Triggers = list.join('|'),
        readLockFingerprint: () => Future<String?>.value(persistedLockFp),
        writeLockFingerprint: (fp) async => persistedLockFp = fp,
        clearLockFingerprint: () async => fpCleared = true,
        currentFingerprint: () => Future<String?>.value(currentFp),
      );
    });

    /// 触发 L2：当日 2 次 L1（每次 L1 = 窗口内 2 次 crash）。
    Future<void> tripL2() async {
      for (var i = 0; i < 4; i++) {
        await fpBreaker.report(countable: true);
        t = t.add(const Duration(minutes: 1));
      }
    }

    test('L2 触发时同写当前驱动指纹', () async {
      await tripL2();
      expect(persistedLock, isNotNull);
      expect(persistedLockFp, 'fp-A', reason: '锁定时须记录触发时指纹');
    });

    test('锁期内指纹变更 → 提前解锁并清锁清指纹', () async {
      await tripL2();
      expect(persistedLockFp, 'fp-A');
      // 模拟系统 OTA：驱动指纹漂移；冷启动新实例（L1 内存态清零，
      // 指纹解锁后不应被残留的 L1 内存标志掩盖判定）。
      currentFp = 'fp-B';
      final fresh = EngineCircuitBreaker(
        now: () => t,
        readLock: () => Future<String?>.value(persistedLock),
        writeLock: (iso) async => persistedLock = iso,
        clearLock: () async => cleared = true,
        readLockFingerprint: () => Future<String?>.value(persistedLockFp),
        clearLockFingerprint: () async => fpCleared = true,
        currentFingerprint: () => Future<String?>.value(currentFp),
      );
      expect(await fresh.isBroken, isFalse,
          reason: '驱动指纹变更应提前解锁');
      expect(cleared, isTrue, reason: '解锁须清除持久化锁');
      expect(fpCleared, isTrue, reason: '解锁须清除锁定指纹');
    });

    test('锁期内指纹一致 → 维持锁定', () async {
      await tripL2();
      expect(await fpBreaker.isBroken, isTrue);
      expect(cleared, isFalse);
    });

    test('锁定时未记录指纹（拿不到）→ 解锁仅靠时间过期', () async {
      await tripL2();
      persistedLockFp = null; // 触发时指纹缺失（旧版本锁/通道故障）
      expect(await fpBreaker.isBroken, isTrue, reason: '无指纹可比对不误解锁');
    });

    test('当前指纹拿不到（通道故障）→ 维持锁定不误开', () async {
      await tripL2();
      currentFp = null;
      expect(await fpBreaker.isBroken, isTrue);
      expect(cleared, isFalse);
    });
  });
}
