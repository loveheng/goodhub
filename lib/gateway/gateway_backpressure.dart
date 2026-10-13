/// 网关入站背压（§9.6，thirdconnect.md）：单 server 并发硬上限
/// [kMaxConcurrentPerServer]，超上限请求在网关层排队等待——严禁 PC 突发并发
/// （Cursor 并行工具调用）无脑穿透压向 Binder 线程池（~16 线程）致 Dart
/// Isolate 消息堆积 → ANR/系统强杀。
library;

import 'dart:async';
import 'dart:collection';

/// 单 server 并发硬上限（§9.6 拍板：max_concurrent = 4）。
const kMaxConcurrentPerServer = 4;

/// per-server 计数信号量注册表（serverId → 信号量；惰性建）。
class PerServerBackpressure {
  PerServerBackpressure({this.maxConcurrent = kMaxConcurrentPerServer});

  final int maxConcurrent;

  final Map<String, _CountingSemaphore> _sems = {};

  /// 在 [serverId] 的并发预算内执行 [task]；超限排队（FIFO），槽位随完成
  /// 移交给队首等待者（计数不回落，交接零间隙）。
  Future<T> run<T>(String serverId, Future<T> Function() task) {
    final sem =
        _sems.putIfAbsent(serverId, () => _CountingSemaphore(maxConcurrent));
    return sem.run(task);
  }

  /// 当前 serverId 在途+排队数（观测面，测试用）。
  int pendingCount(String serverId) => _sems[serverId]?.pending ?? 0;
}

class _CountingSemaphore {
  _CountingSemaphore(this.max);

  final int max;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  var _inFlight = 0;

  int get pending => _inFlight + _waiters.length;

  Future<T> run<T>(Future<T> Function() task) async {
    if (_inFlight >= max) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _inFlight++;
    }
    try {
      return await task();
    } finally {
      // 槽位移交：有等待者直接放行（计数不变），否则归还。
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _inFlight--;
      }
    }
  }
}
