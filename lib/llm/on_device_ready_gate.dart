import 'dart:async';

import 'on_device_engine.dart';

/// 就绪闸（on-device S2 正式接线）：bind 时序竞态的正式收口。
///
/// 竞态本质：`bind()` 返回 ≠ 已连接——`onServiceConnected` 是异步的，其内
/// `initEngine` 同步完成后主进程才发 `onEngineReady` 事件。旧口径以固定
/// sleep 掩盖（S2-1 冒烟期的 2s 等待），本闸以**就绪事件**为唯一收口点：
///
/// - [noteReady]：onEngineReady 到达 → 完成（携带初始 EngineStatus 序数）；
/// - [noteGone]：进程死亡/致命事件 → 作废（下一次 [waitReady] 须等新事件，
///   禁止以过期就绪态放行）；
/// - [waitReady]：已就绪即时返回；未就绪挂起至 [timeout]——超时返回 null
///   （调用方按不可用快速失败/DEGRADE，禁死等）。
///
/// 纯逻辑件（无平台依赖），单测覆盖竞态序列。
class EngineReadyGate {
  Completer<EngineStatus>? _ready;

  /// 是否已就绪（已完成且未作废）。
  bool get isReady => _ready?.isCompleted ?? false;

  /// onEngineReady 事件到达（幂等：已完成后忽略重复事件）。
  void noteReady(int statusOrdinal) {
    final c = _ready ??= Completer<EngineStatus>();
    if (!c.isCompleted) {
      c.complete(engineStatusFromOrdinal(statusOrdinal));
    }
  }

  /// 进程死亡 / 致命事件：就绪态作废（换新 pending 闸）。
  void noteGone() {
    _ready = Completer<EngineStatus>();
  }

  /// 等待就绪。已就绪 → 记录态；未就绪 → 挂起至 [timeout]，超时返回 null。
  Future<EngineStatus?> waitReady({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final c = _ready ??= Completer<EngineStatus>();
    if (c.isCompleted) return c.future;
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }
}
