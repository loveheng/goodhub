/// 指数退避算法单测（connection 韧性底座）：增长曲线、封顶、抖动区间、
/// 重试额度与最坏累计等待。
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/network/backoff.dart';

void main() {
  group('增长曲线与封顶', () {
    test('无抖动时按 initial × multiplier^n 增长', () {
      const b = ExponentialBackoff(
        initial: Duration(seconds: 1),
        multiplier: 2,
        jitter: 0,
      );
      expect(b.delayFor(0), const Duration(seconds: 1));
      expect(b.delayFor(1), const Duration(seconds: 2));
      expect(b.delayFor(2), const Duration(seconds: 4));
      expect(b.delayFor(3), const Duration(seconds: 8));
    });

    test('超过 max 即封顶（不无限增长）', () {
      const b = ExponentialBackoff(
        initial: Duration(seconds: 1),
        max: Duration(seconds: 5),
        jitter: 0,
      );
      expect(b.delayFor(0), const Duration(seconds: 1));
      expect(b.delayFor(2), const Duration(seconds: 4));
      expect(b.delayFor(3), const Duration(seconds: 5));
      expect(b.delayFor(10), const Duration(seconds: 5));
    });

    test('负数 attempt 视为 0（防御外部算错）', () {
      const b = ExponentialBackoff(jitter: 0);
      expect(b.delayFor(-1), b.delayFor(0));
    });
  });

  group('抖动', () {
    test('抖动落在 [1-j, 1+j] 区间且随随机源确定性复现', () {
      // Random(seed) 固定序列 → 可断言区间而不断言具体值
      final b = ExponentialBackoff(
        initial: Duration(seconds: 10),
        jitter: 0.2,
        max: Duration(seconds: 60),
        random: Random(42),
      );
      for (var i = 0; i < 20; i++) {
        final d = b.delayFor(0);
        expect(d.inMilliseconds, greaterThanOrEqualTo(8000));
        expect(d.inMilliseconds, lessThanOrEqualTo(12000));
      }
    });

    test('抖动关闭时结果稳定（单测钉曲线的前提）', () {
      const b = ExponentialBackoff(jitter: 0);
      expect(b.delayFor(1), b.delayFor(1));
    });
  });

  group('重试额度', () {
    test('maxAttempts 内可重试，耗尽即停', () {
      const b = ExponentialBackoff(maxAttempts: 3);
      expect(b.shouldRetry(0), isTrue);
      expect(b.shouldRetry(2), isTrue);
      expect(b.shouldRetry(3), isFalse);
    });

    test('maxAttempts=null = 无限重试（常驻连接）', () {
      const b = ExponentialBackoff(maxAttempts: null);
      expect(b.shouldRetry(9999), isTrue);
    });

    test('最坏累计等待可观测（5 次、封顶 30s 的场景）', () {
      const b = ExponentialBackoff(
        initial: Duration(seconds: 1),
        max: Duration(seconds: 30),
        maxAttempts: 5,
        jitter: 0,
      );
      // 1 + 2 + 4 + 8 + 16 = 31s
      expect(b.totalWorstCase, const Duration(seconds: 31));
    });
  });
}
