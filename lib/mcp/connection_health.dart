/// MCP 周期心跳（T4-2，F1.4）：仅对远端 HTTP server 生效。
///
/// **作用域隔离（D16 约束）**：本地 Binder 插件依赖 Android 内核
/// `DeathRecipient` 事件感知（进程被杀/闪退是毫秒级事件驱动），**绝不轮询**——
/// 对 Binder 连接调 [start] 直接 no-op（DEGRADE 留痕），避免频繁唤醒休眠子
/// App 进程退化成「电量刺客」。判定依据 = [pollable]（`transport is HttpTransport`）。
///
/// 状态机（单调、非任务态，纯连接质量信号）：
/// `unknown` → 首次探活成功 `online`；单次失败 `degraded`；**连续 `maxConsecutiveFailures`
/// 次失败** `offline`；恢复成功即回 `online`（失败计数清零）。UI 据此点灯，不阻塞业务。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'mcp_client.dart';
import 'transport/mcp_transport.dart';

/// 连接健康状态（T4-2）。命名刻意平铺，不混入任务/会话语义。
enum ConnectionState { unknown, online, degraded, offline }

class ConnectionHealth {
  ConnectionHealth(
    this.client, {
    this.interval = const Duration(seconds: 15),
    this.timeout = const Duration(seconds: 5),
    this.maxConsecutiveFailures = 2,
    this.ping,
  });

  final McpClient client;

  /// 周期心跳间隔（D16：15s）。
  final Duration interval;

  /// 单次探活超时（D16：5s）——超时计入失败，避免挂死判定。
  final Duration timeout;

  /// 连续失败达到该值即判 offline（D16：2 次 ≈ 30s）。
  final int maxConsecutiveFailures;

  /// 可注入的探活实现（默认 [McpClient.ping]）。测试注入以断言调度与状态机而不触网。
  Future<void> Function()? ping;

  /// 仅远端 HTTP 连接可轮询（D16：Binder 靠 DeathRecipient 事件感知，严禁轮询）。
  static bool pollable(McpClient client) => client.transport is HttpTransport;

  ConnectionState _state = ConnectionState.unknown;
  ConnectionState get state => _state;

  final StreamController<ConnectionState> _controller =
      StreamController<ConnectionState>.broadcast(sync: true);

  /// 状态变更广播（UI 节点灯订阅）。首帧前的 unknown 不重发。
  Stream<ConnectionState> get changes => _controller.stream;

  Timer? _timer;
  var _failures = 0;

  void _emit(ConnectionState next) {
    if (next == _state) return;
    _state = next;
    _controller.add(next);
  }

  /// 启动周期心跳（幂等）。非 [pollable] 连接 no-op——不建任何定时器。
  void start() {
    if (!pollable(client)) {
      debugPrint(
        '[DEGRADE] connection-health: skip polling on non-HTTP transport '
        '(${client.transport.runtimeType}); rely on DeathRecipient',
      );
      return;
    }
    if (_timer != null) return;
    _tick(); // 立即首探，不等首个周期
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    final probe = ping ?? client.ping;
    try {
      await probe().timeout(timeout);
      _failures = 0;
      _emit(ConnectionState.online);
    } on Object {
      _failures++;
      _emit(_failures >= maxConsecutiveFailures
          ? ConnectionState.offline
          : ConnectionState.degraded);
    }
  }

  /// 停止心跳并释放定时器（无 pending timer 泄漏）。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _failures = 0;
  }
}
