/// §S5 卸载助手行为单测：阈值谓词 / 槽位回收 / 僵尸占位 / 池满快速失败 /
/// 便捷封装的轻重分派。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/concurrency/offload.dart';

void main() {
  group('S5 · 阈值谓词（可判定，无预估耗时）', () {
    test('三档边界值', () {
      expect(shouldOffload(OffloadKind.json, 256 * 1024), isTrue);
      expect(shouldOffload(OffloadKind.json, 256 * 1024 - 1), isFalse);
      expect(shouldOffload(OffloadKind.regexText, 64 * 1024), isTrue);
      expect(shouldOffload(OffloadKind.regexText, 64 * 1024 - 1), isFalse);
      expect(shouldOffload(OffloadKind.crypto, 128 * 1024), isTrue);
      expect(shouldOffload(OffloadKind.crypto, 128 * 1024 - 1), isFalse);
    });
  });

  group('S5 · 池语义', () {
    test('正常路径：结果透传，槽位回收（inFlight 归零）', () async {
      final pool = OffloadPool(maxConcurrent: 2);
      final out = await pool.run(() => 42, timeout: const Duration(seconds: 5));
      expect(out, 42);
      expect(pool.inFlight, 0);
    });

    test('超时：TimeoutException 上抛，僵尸任务持续占位直至真结束', () async {
      final pool = OffloadPool(maxConcurrent: 1);
      // 底层跑 400ms；等待方 50ms 超时弃等。
      int slow() {
        var x = 0;
        final deadline = DateTime.now().add(const Duration(milliseconds: 400));
        while (DateTime.now().isBefore(deadline)) {
          x++;
        }
        return x;
      }
      await expectLater(
        pool.run(slow, timeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
      expect(pool.inFlight, 1, reason: '超时弃等不弃占——僵尸任务仍占槽');
      // 池满 1：此刻再提交必被快速拒绝。
      expect(() => pool.run(() => 1, timeout: const Duration(seconds: 1)),
          throwsA(isA<OffloadBusyException>()));
      // 僵尸跑完后槽位释放。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(pool.inFlight, 0);
      expect(await pool.run(() => 7, timeout: const Duration(seconds: 1)), 7);
    });

    test('并发超池：第二个提交快速失败（OffloadBusyException）', () async {
      final pool = OffloadPool(maxConcurrent: 1);
      int slow() {
        var x = 0;
        final deadline = DateTime.now().add(const Duration(milliseconds: 150));
        while (DateTime.now().isBefore(deadline)) {
          x++;
        }
        return x;
      }
      final first = pool.run(slow, timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(() => pool.run(() => 2, timeout: const Duration(seconds: 1)),
          throwsA(isA<OffloadBusyException>()));
      await first;
    });
  });

  group('S5 · offloadIfHeavy 轻重分派', () {
    test('低于阈值：主 isolate 直算，不占池', () async {
      final pool = OffloadPool(maxConcurrent: 1);
      final out = await offloadIfHeavy<int>(
        kind: OffloadKind.crypto,
        inputBytes: 1,
        heavy: () => throw StateError('不应进入 Worker'),
        light: () => 1,
        pool: pool,
      );
      expect(out, 1);
      expect(pool.inFlight, 0);
    });

    test('超阈值：进 Worker 池执行', () async {
      final pool = OffloadPool(maxConcurrent: 2);
      final out = await offloadIfHeavy<int>(
        kind: OffloadKind.crypto,
        inputBytes: OffloadThresholds.cryptoBytes,
        heavy: () => 42,
        light: () => throw StateError('不应走主 isolate'),
        pool: pool,
      );
      expect(out, 42);
    });

    test('池满降级：退主 isolate 直算（DEGRADE 语义），结果仍正确', () async {
      final pool = OffloadPool(maxConcurrent: 1);
      final blocker = pool.run(() {
        var x = 0;
        final deadline = DateTime.now().add(const Duration(milliseconds: 150));
        while (DateTime.now().isBefore(deadline)) {
          x++;
        }
        return x;
      }, timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final out = await offloadIfHeavy<int>(
        kind: OffloadKind.crypto,
        inputBytes: OffloadThresholds.cryptoBytes,
        heavy: () => throw StateError('池满时不应再进 Worker'),
        light: () => -1,
        pool: pool,
      );
      expect(out, -1, reason: '池满退主 isolate——保正确性，掉帧风险留痕');
      await blocker;
    });
  });
}
