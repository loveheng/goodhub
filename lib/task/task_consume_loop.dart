/// 宿主侧任务消费循环（M4 第一步，goodshare 仓 ai-app-split.md §3.12）。
///
/// 背景：§3.2 是**拉模型**——goodshare 入队后不推，宿主主动 claim 才消费。
/// 人类入口（ClaimLoopPage）归档后生产代码零 claim 调用点 → 任务永久滞留
/// pending、UI spinner 空转。本件补上「拉手」，独立可验收（不依赖跨仓通知）。
///
/// 契约纪律（§3.12.2）：
/// - **catch-up 是地基**：挂载/重连后本件被 trigger 一次即 claim 到 idle；
///   通知（goodshare 侧后续叠加）只优化延迟，不承担正确性；
/// - **单飞 + dirty**：[trigger] 期间已有循环在跑 → 只置 dirty，本轮结束后
///   补跑一轮，绝不并发 claim（防重复认领同一任务）；
/// - **达顶继续**：单轮上限跑满 ≠ 队列空，须继续下一轮（只等通知会漏任务）；
/// - **空拉终止**：`runOnce` 返回 false（idle）即停，不做无谓轮询；
/// - **熔断**：连续失败达阈即停本轮，不无限重试烧额度。
///
/// 依赖倒置（arch-hardening ③）：通道存活与前台忙碌均为注入端口，本域不
/// import ui / gateway / mcp 的连接健康实现。
library;

import 'dart:async';

import 'task_loop_service.dart';

/// 消费循环：把「一次通知 / 一次挂载」翻译成「claim 到 idle 的批量消化」。
class TaskConsumeLoop {
  TaskConsumeLoop({
    required this.service,
    this.isChannelAlive,
    this.isHostBusy,
    this.maxPerRound = 5,
    this.maxConsecutiveFailures = 3,
    this.debounce = const Duration(milliseconds: 300),
    this.busyRetryDelay = const Duration(seconds: 3),
    this.onEvent,
  });

  /// 单步闭环（claim → 心跳 → apply）；返回 false = idle。
  final TaskLoopService service;

  /// 通道存活前置（如 `ConnectionHealth.state == online`）；null = 不校验。
  /// 严禁向已断开的 Binder 发 IPC（§3.12.2-7）。
  final bool Function()? isChannelAlive;

  /// 前台忙碌端口（算力让路，§3.12.2-2）：true = 暂缓批处理，延迟重试。
  /// 由窗口层注入运行态——本件不感知 UI。
  final bool Function()? isHostBusy;

  /// 单轮处理上限（防单轮无限推理占用）。
  final int maxPerRound;

  /// 单轮内连续失败熔断阈值。
  final int maxConsecutiveFailures;

  /// 去抖窗口（合并批量入队期间的连续通知）。
  final Duration debounce;

  /// 前台忙碌时的重试间隔。
  final Duration busyRetryDelay;

  /// 可观测事件（日志/遥测；UI 可选消费）。
  final void Function(TaskConsumeEvent event)? onEvent;

  Timer? _debounceTimer;
  Timer? _busyTimer;
  bool _running = false;
  bool _dirty = false;
  bool _disposed = false;

  /// 是否正在消化（观测/测试用）。
  bool get isRunning => _running;

  /// 触发一次消费（通知到达 / 挂载 catch-up / 手动）。
  ///
  /// 去抖后进入；运行中不并发、只置 dirty；通道断/前台忙则暂缓。
  void trigger() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _pump);
  }

  Future<void> _pump() async {
    if (_disposed) return;
    // 单飞：已有循环在跑 → 只标记积压，不并发 claim。
    if (_running) {
      _dirty = true;
      onEvent?.call(const TaskConsumeDeferred());
      return;
    }
    if (isChannelAlive != null && !isChannelAlive!()) {
      onEvent?.call(const TaskConsumeSkipped(reason: 'channel offline'));
      return;
    }
    // 算力让路：前台对话进行中 → 暂缓，稍后重试（dirty 由下轮 trigger 带出）。
    if (isHostBusy?.call() ?? false) {
      _busyTimer?.cancel();
      _busyTimer = Timer(busyRetryDelay, _pump);
      onEvent?.call(const TaskConsumeDeferred());
      return;
    }
    _running = true;
    try {
      var roundFull = false;
      do {
        _dirty = false;
        final round = await _drainRound();
        roundFull = round.full;
        // 跑满上限 ≠ 队列空：继续下一轮，直到本轮未跑满且期间无新通知。
        // F8（review-fix-2026-10）：dispose 后不再续轮——原判断只在 _pump 入口
        // 检查一次，do/while 内无检查，dispose（断连/卸载场景）后仍继续
        // claim 直到连续失败熔断，对已断通道徒增 churn。
      } while (!_disposed && (_dirty || roundFull));
    } finally {
      _running = false;
    }
  }

  /// 单轮：最多 [maxPerRound] 条；idle 即停；连续失败达阈熔断。
  Future<_Round> _drainRound() async {
    var processed = 0;
    var failures = 0;
    while (processed < maxPerRound) {
      // F8：单步间复查存活——通道在轮内断开（dispose/断连）即停，不盲发。
      if (_disposed ||
          isChannelAlive != null && !isChannelAlive!()) {
        return _Round(processed, full: false);
      }
      bool handled;
      try {
        handled = await service.runOnce();
      } on Object catch (e) {
        failures++;
        onEvent?.call(TaskConsumeFailed(error: e));
        if (failures >= maxConsecutiveFailures) {
          onEvent?.call(TaskConsumeTripped(failures: failures));
          return _Round(processed, full: false);
        }
        continue;
      }
      if (!handled) {
        // 空拉终止（idle）：不再无谓轮询。
        onEvent?.call(TaskConsumeIdle(processed: processed));
        return _Round(processed, full: false);
      }
      processed++;
      failures = 0;
    }
    return _Round(processed, full: true); // 达顶，可能仍有积压
  }

  /// 生命周期解绑（§3.12.2-7）：断开/卸载/重扫时调用——清定时器并复位状态机。
  /// 幂等；解绑后再 [trigger] 无副作用。
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _busyTimer?.cancel();
    _busyTimer = null;
    _running = false;
    _dirty = false;
  }
}

/// 单轮结果：处理条数 + 是否跑满上限（跑满 = 可能仍有积压）。
class _Round {
  const _Round(this.processed, {required this.full});

  final int processed;
  final bool full;
}

/// 消费循环可观测事件（观测/遥测用，UI 可选消费）。
sealed class TaskConsumeEvent {
  const TaskConsumeEvent();
}

/// 队列已空（本轮处理 [processed] 条后 idle）。
class TaskConsumeIdle extends TaskConsumeEvent {
  const TaskConsumeIdle({required this.processed});
  final int processed;
}

/// 暂缓（运行中置 dirty / 前台忙碌让路）。
class TaskConsumeDeferred extends TaskConsumeEvent {
  const TaskConsumeDeferred();
}

/// 跳过（通道离线）。
class TaskConsumeSkipped extends TaskConsumeEvent {
  const TaskConsumeSkipped({required this.reason});
  final String reason;
}

/// 单步失败（已由 TaskLoopService 回写 failed 终态，不会反复认领）。
class TaskConsumeFailed extends TaskConsumeEvent {
  const TaskConsumeFailed({required this.error});
  final Object error;
}

/// 熔断（连续失败达阈，停止本轮）。
class TaskConsumeTripped extends TaskConsumeEvent {
  const TaskConsumeTripped({required this.failures});
  final int failures;
}
