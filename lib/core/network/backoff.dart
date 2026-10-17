/// 指数退避算法（连接韧性 F1.12 的底座，纯计算、零 IO）。
///
/// 落点依据（coding-standards §1.2 边界纪律）：`core/network` 只放**纯传输
/// 底座**（HTTP client、退避算法等通用件）；「什么时候重连、重连后要不要
/// 重新激活工具」是总线策略，住在 `lib/mcp/`（T4-2/T4-3）——本文件只回答
/// 「第 n 次重试该等多久」。
///
/// 抖动（jitter）是必需的：多连接同时重连会在同一时刻撞在一起（惊群），
/// 抖动把重试时刻打散。测试可注入 [random] 保证确定性。
library;

import 'dart:math';

class ExponentialBackoff {
  const ExponentialBackoff({
    this.initial = const Duration(seconds: 1),
    this.multiplier = 2,
    this.max = const Duration(seconds: 30),
    this.maxAttempts = 5,
    this.jitter = 0.2,
    this.random,
  });

  /// 首次重试等待（attempt=0 时返回）。
  final Duration initial;

  /// 增长倍数（指数底）。
  final num multiplier;

  /// 等待上限（防无限增长）。
  final Duration max;

  /// 最大重试次数；`null` = 无限重试（常驻连接场景）。
  final int? maxAttempts;

  /// 抖动比例（0~1）：实际等待 = base × (1 ± jitter)。0 = 关闭抖动（测试）。
  final double jitter;

  /// 可注入的随机源（测试确定性）；null = 用默认 `Random()`。
  final Random? random;

  /// 第 [attempt] 次重试的等待时长（attempt 从 0 开始）。
  ///
  /// 纯函数（jitter=0 时）：可单测钉死增长曲线与封顶。
  Duration delayFor(int attempt) {
    final n = attempt < 0 ? 0 : attempt;
    final baseMs = initial.inMilliseconds * pow(multiplier, n);
    final capped = baseMs > max.inMilliseconds ? max.inMilliseconds : baseMs;
    if (jitter <= 0) return Duration(milliseconds: capped.round());

    final r = random ?? Random();
    final factor = 1 - jitter + r.nextDouble() * jitter * 2;
    final jittered = (capped * factor).round();
    return Duration(milliseconds: jittered < 0 ? 0 : jittered);
  }

  /// 第 [attempt] 次重试是否还在额度内（`maxAttempts=null` 恒 true）。
  bool shouldRetry(int attempt) =>
      maxAttempts == null || attempt < maxAttempts!;

  /// 累计等待上限（观测用：全部重试耗完的最坏等待）。
  Duration get totalWorstCase {
    final n = maxAttempts ?? 8;
    var sum = 0;
    for (var i = 0; i < n; i++) {
      sum += delayFor(i).inMilliseconds;
    }
    return Duration(milliseconds: sum);
  }
}
