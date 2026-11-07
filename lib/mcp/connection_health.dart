/// MCP 周期心跳（T4-2，F1.4）：仅对远端 HTTP server 生效。
///
/// **作用域隔离（D16 约束）**：本地 Binder 插件依赖 Android 内核
/// `DeathRecipient` 事件感知（进程被杀/闪退是毫秒级事件驱动），**绝不轮询**——
/// 对 Binder 连接调 [start] 直接 no-op（DEGRADE 留痕），避免频繁唤醒休眠子
/// App 进程退化成「电量刺客」。判定依据 = [pollable]（S1c 能力化：`transport is PollableTransport`）。
///
/// 状态机（单调、非任务态，纯连接质量信号）：
/// `unknown` → 首次探活成功 `online`；单次失败 `degraded`；**连续 `maxConsecutiveFailures`
/// 次失败** `offline`；恢复成功即回 `online`（失败计数清零）。UI 据此点灯，不阻塞业务。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/errors/mcp_error.dart';
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
    this.isAlive,
  }) {
    _live.add(this); // D1 生命周期注册表入册（[stop] 退册）
  }

  final McpClient client;

  /// 周期心跳间隔（D16：15s）。
  final Duration interval;

  /// 单次探活超时（D16：5s）——超时计入失败，避免挂死判定。
  final Duration timeout;

  /// 连续失败达到该值即判 offline（D16：2 次 ≈ 30s）。
  final int maxConsecutiveFailures;

  /// 可注入的探活实现（默认 [McpClient.ping]）。测试注入以断言调度与状态机而不触网。
  Future<void> Function()? ping;

  /// 忙时免判探针（心跳修复 A）：返回 true = 连接上有近期进度推进的在途流式
  /// 请求（server 忙而非死）——探活超时不计入 offline 判据，避免并行负载下
  /// 心跳误判离线级联 D18 取消在途。null = 未接线（维持旧行为）。
  final bool Function()? isAlive;

  /// 仅远端 HTTP 连接可轮询（D16：Binder 靠 DeathRecipient 事件感知，严禁轮询）
  /// ——S1c 能力化：按 [PollableTransport] 接口探测，禁 is 具体类。
  static bool pollable(McpClient client) => client.transport is PollableTransport;

  ConnectionState _state = ConnectionState.unknown;
  ConnectionState get state => _state;

  final StreamController<ConnectionState> _controller =
      StreamController<ConnectionState>.broadcast(sync: true);

  /// 状态变更广播（UI 节点灯订阅）。首帧前的 unknown 不重发。
  Stream<ConnectionState> get changes => _controller.stream;

  Timer? _timer;
  var _failures = 0;

  /// 周期心跳在跑标志（[start] 置位 / [stop] 清零）——区分「后台暂停」与
  /// 「从未启动/已停止」：[resume] 只复活前者，不越权重启已 stop 的连接。
  var _periodicOn = false;

  /// 存活心跳注册表（D1 生命周期韧性）：构造入册、[stop] 退册——
  /// [pauseAll]/[resumeAll] 由 App 生命周期沿调用（连接持有方分散在
  /// gateway/chat 两处装配，逐持有方接线过重，注册表收敛）。
  static final Set<ConnectionHealth> _live = {};

  /// App 退后台：摘掉全部周期心跳定时器（D16 电量纪律——Android paused 下
  /// Timer 不保证冻结，显式暂停替代侥幸）。状态机与 [start] 资格保留，
  /// 恢复前台 [resumeAll] 原样续跑。
  static void pauseAll() {
    for (final h in List.of(_live)) {
      h.pause();
    }
  }

  /// App 回前台：立即探活（不等下个周期——后台冻结后首探测延迟可达一个
  /// 完整 interval，SSE 假死感知窗口压到 0）+ 重启周期心跳。
  static void resumeAll() {
    for (final h in List.of(_live)) {
      h.resume();
    }
  }

  void _emit(ConnectionState next) {
    if (next == _state) return;
    _state = next;
    _controller.add(next);
  }

  /// 启动周期心跳（幂等）。非 [pollable] 连接 no-op——不建任何定时器。
  void start() {
    if (!pollable(client)) {
      debugPrint(
        '[DEGRADE] connection-health: skip polling on non-pollable transport '
        '(${client.transport.runtimeType}); rely on DeathRecipient',
      );
      return;
    }
    if (_timer != null) return;
    _tick(); // 立即首探，不等首个周期
    _timer = Timer.periodic(interval, (_) => _tick());
    _periodicOn = true;
  }

  Future<void> _tick() async {
    final probe = ping ?? client.ping;
    try {
      await probe().timeout(timeout);
      _failures = 0;
      _emit(ConnectionState.online);
    } on TimeoutException {
      _countFailure(busyExempt: true);
    } on McpNetworkException catch (e) {
      // 传输层把自身超时包成 transport timeout 文案的 McpNetworkException——
      // 与连接级失败（拒绝/复位）分级（修复 B）。
      _countFailure(busyExempt: e.message.contains('timeout'));
    } on Object {
      _countFailure(busyExempt: false);
    }
  }

  /// 探活失败分级（修复 A+B）：连接级错误恒计数；超时仅在「无近期进度推进的
  /// 在途请求」时计数——忙 = server 活着，跳过本次，不判离线；空闲超时仍计数
  /// （真不可达，保留 offline 判定能力）。
  void _countFailure({required bool busyExempt}) {
    if (busyExempt && (isAlive?.call() ?? false)) return;
    _failures++;
    _emit(_failures >= maxConsecutiveFailures
        ? ConnectionState.offline
        : ConnectionState.degraded);
  }

  /// 停止心跳并释放定时器（无 pending timer 泄漏）。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _failures = 0;
    _periodicOn = false;
    _live.remove(this); // D1 注册表退册（连接已释放，禁再被生命周期沿触达）
  }

  /// App 退后台（D1）：仅摘定时器——状态机、失败计数与 [start] 资格保留，
  /// [resume] 原样续跑。非轮询连接 / 未启动心跳 = no-op。
  void pause() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
  }

  /// App 回前台（D1）：立即探活（SSE 假死感知窗口压到 0，不等下个周期）
  /// + 重启周期心跳。仅复活「曾被 [start] 启动且当前处于暂停」的心跳——
  /// 已 [stop] 释放的连接不越权重启。
  void resume() {
    if (!_periodicOn || _timer != null) return;
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }
}
