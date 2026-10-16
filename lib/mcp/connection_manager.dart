/// 单 Server 连接韧性管理器（T4-3 / T4-4 / T4-5，F1.4 / F1.12 / F1.14）。
///
/// 组合 T4-1 退避 + T4-2 心跳状态机 + [McpToolFace]，在连接质量信号驱动下执重连
/// 编排：
///  - 健康 `offline → online` 触发 [reconnect]（重 negotiate + 重 listTools + D17
///    差分清洗：新 listTools 与原 JIT 激活集做交集，下线工具剔除并记日志）；
///  - 健康转 `offline` 触发 D18 断连处置（取消在途 + 回告「在途 N 个已取消，不重放」）；
///  - 离线窗口内到达的工具调用视为**积压、整体丢弃、不重放**（T4-4 积压模型：
///    architecture §1「写操作重放有副作用风险」），恢复成功时回告「积压 M 个已丢弃」
///    （[BacklogReport] → TrackNote）。
///
/// **作用域隔离（D16 约束）**：仅 HTTP 连接跑心跳/自动重连；Binder 连接
/// [ConnectionHealth.pollable] 为 false → [start] 不建定时器、不自动重连（本地
/// 插件依赖 Android `DeathRecipient` 事件感知，轮询会唤醒休眠子进程成电量刺客）。
/// Binder 的断连处置仍可由宿主侧 DeathRecipient 监听显式调 [handleHealthState]。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/network/backoff.dart';
import '../core/tool_result.dart';
import 'connection_face.dart';
import 'connection_health.dart';
import 'mcp_client.dart';

/// 重连结果报告（D17 差分清洗产物）。
class ReconnectReport {
  const ReconnectReport({
    required this.success,
    this.droppedTools = const [],
    this.currentTools = const [],
    this.error,
  });

  /// 重连是否成功（协商 + listTools 全程无异常）。
  final bool success;

  /// 重连后从 JIT 激活集被剔除的下线工具（D17 差分清洗）。
  final List<String> droppedTools;

  /// 仍是有效（被最新 listTools 保留）的工具名。
  final List<String> currentTools;

  /// 失败时的错误（success=false 时非空）。
  final Object? error;
}

/// 断连回告（D18）：在途请求已被取消、不重放。
///
/// 调用方（UI/执行环）据此产出 TrackNote「连接中断，在途 N 个已取消，不重放」——
/// 本类只负责连接层语义，回告呈现交给消费者。
class DisconnectReport {
  const DisconnectReport({required this.inFlightCancelled});

  /// 断连瞬间在途、已被取消的请求数。
  final int inFlightCancelled;
}

/// 积压回告（T4-4）：离线窗口内被整体丢弃、未重放的工具调用总数。
///
/// 调用方据此产出 TrackNote「连接中断，积压 M 个请求已丢弃，不重放」——
/// 与 [DisconnectReport]（在途取消）是两类独立回告：在途=已发出被取消，
/// 积压=未发出直接丢弃（architecture §1 积压丢弃模型）。
class BacklogReport {
  const BacklogReport({required this.droppedCount});

  /// 离线窗口内累计丢弃的（未发出）工具调用数。
  final int droppedCount;
}

/// 单 Server 连接韧性管理器（T4-3 / T4-4 / T4-5）。
///
/// 持有 [McpClient] 与注入的 [ConnectionFace]，是会话级连接生命周期的 owner：
/// 一个实例 = 一条 server 连接（与 architecture §15「一个 client 实例 = 一条
/// server 连接」对齐）。face 具体实现（coordinator 侧 McpToolFace）由装配方
/// 注入（face / faceFactory 二选一，双缺快速失败），本层不感知其类型；
/// 重连编排对本仓其余代码透明。
class McpConnection {
  McpConnection({
    required this.client,
    ConnectionFace? face,
    ConnectionFace Function(McpClient client)? faceFactory,
    ExponentialBackoff? backoff,
    ConnectionHealth? health,
    this.serverId = 'goodshare',
  })  : _face = face ??
            (faceFactory != null
                ? faceFactory(client)
                : throw ArgumentError(
                    'McpConnection: face 或 faceFactory 必须注入其一'
                    '（生命周期 Owner 契约，见 connection_face.dart；'
                    '禁止隐式回退到 coordinator 具体类型）')),
        backoff = backoff ?? const ExponentialBackoff(),
        health = health ?? ConnectionHealth(client) {
    // T4-5：server→client 资源变更通知转发到本连接的 D19 回告回调。
    client.onResourceUpdated = (uri) => onResourceUpdated?.call(uri);
  }

  /// 底层传输与协议客户端（同一实例在 [reconnect] 中被重握手）。
  final McpClient client;

  /// 来源/目标 Server 标识（透传给 [ConnectionFace] 实现）。
  final String serverId;

  /// 协议层工具面（注入的最小能力集；具体实现 = coordinator 侧 McpToolFace，
  /// 经 [face] 取用供 [ToolRouter]/[GatewayHandler] 装配——调用方自行 import，
  /// 本层不感知）。
  ConnectionFace get face => _face;
  final ConnectionFace _face;

  /// 指数退避（T4-1 底座）：重连失败后按 attempt 递增退避，避免惊群。
  final ExponentialBackoff backoff;

  /// 心跳状态机（T4-2）：健康信号唯一来源。
  final ConnectionHealth health;

  /// JIT 激活集（D17）：当前被激活（JIT activate）的工具名集合。重连后与最新
  /// listTools 做交集过滤，下线工具自动剔除。由 activate_server_tools 等调用方
  /// 经 [markActivated] 写入。
  final Set<String> _activatedToolNames = {};

  /// 当前 JIT 激活集（只读视图）。
  Set<String> get activatedToolNames => Set.unmodifiable(_activatedToolNames);

  /// 当前已订阅的 resource URI 只读视图（T4-5，server 重启后失效需重放）。
  Set<String> get subscribedUris => client.subscribedUris;

  /// 订阅资源以接收失效推送（T4-5 / D19）：委托 [McpClient.subscribeResource]，
  /// 受 server capabilities 门控；成功后启动 GET SSE 下行监听（幂等）。订阅状态
  /// 随重连重放（server 重启后订阅清空）。
  Future<void> subscribe(String uri) async {
    await client.subscribeResource(uri);
    unawaited(client.startNotificationListener()); // 幂等，已监听则不重开
  }

  /// 取消订阅（委托 [McpClient.unsubscribeResource]）。
  Future<void> unsubscribe(String uri) => client.unsubscribeResource(uri);

  /// 记录 JIT 激活集（覆盖写，调用方负责集合正确性）。
  void markActivated(Set<String> names) {
    _activatedToolNames
      ..clear()
      ..addAll(names);
  }

  /// D17 差分清洗后的激活集变化回调（dropped = 被剔除的下线工具，kept = 保留集）。
  void Function(List<String> dropped, List<String> kept)? onActivationChanged;

  /// D18 断连回告回调（在途 N 个已取消、不重放）。
  void Function(DisconnectReport report)? onDisconnectReport;

  /// T4-4 积压回告回调（离线窗口内丢弃的工具调用总数，不重放）。
  void Function(BacklogReport report)? onBacklogReport;

  /// T4-5 / D19 失效感知回调：订阅资源数据变更（server 手改数据后推送
  /// notifications/resources/updated）。消费者据此产 TrackNote「数据已变更，
  /// 如需最新请重新读取（不自动重读）」——**不自动重读**（易变数据事实源永远在
  /// server，architecture §12 分工；自动重读会踩时效且浪费 token）。
  void Function(String uri)? onResourceUpdated;

  StreamSubscription<ConnectionState>? _sub;
  var _started = false;
  var _wasOffline = false;
  var _reconnectAttempts = 0;
  ConnectionState _state = ConnectionState.unknown;
  var _droppedBacklog = 0;

  /// 启动连接韧性：订阅健康信号 + 起心跳（仅 HTTP 可轮询，见 D16）。幂等。
  void start() {
    if (_started) return;
    _started = true;
    _sub = health.changes.listen(handleHealthState);
    health.start();
    // T4-5 收官（订阅触发，宿主无关）：连接就绪即列出并订阅全部 resource——
    // HTTP 顺带起 GET SSE 监听；Binder 订阅走 Binder 回程、通知经 EventChannel 分发。
    unawaited(_subscribeAllResources());
  }

  /// 停止并释放所有资源（心跳定时器 + 订阅），无泄漏。
  void stop() {
    _sub?.cancel();
    _sub = null;
    health.stop();
    _started = false;
  }

  /// 健康状态处理器（[start] 订阅的回调，亦供外部显式驱动，如 Binder 的
  /// DeathRecipient 监听）。返回重连报告（仅 offline→online 触发重连时有值）。
  Future<ReconnectReport?> handleHealthState(ConnectionState state) async {
    _state = state;
    if (state == ConnectionState.offline) {
      _wasOffline = true;
      _onDisconnected();
      return null;
    }
    if (state == ConnectionState.online) {
      // 首探成功（unknown→online）无需重连；仅「曾离线后恢复」才重连，
      // 避免每次首探都重协商（协商缓存命中本就省握手，重连则是 server 真重启）。
      if (!_wasOffline) return null;
      _wasOffline = false;
      final report = await _reconnectWithBackoff();
      // T4-4：恢复成功后回报离线窗口内整体丢弃的积压（不重放）。
      if (report.success) _reportBacklog();
      return report;
    }
    return null; // degraded / unknown：保持现状，不动作
  }

  /// D18 断连处置：取消在途请求 + 回告在途数量（不重放）。
  void _onDisconnected() {
    final n = _face.inFlightCount;
    _face.cancelActiveRequest(); // 取消可取消的流式在途（M3-T2 回程同路）
    client.stopNotificationListener(); // server 不可达：停推通道（避免无谓重连）
    onDisconnectReport?.call(DisconnectReport(inFlightCancelled: n));
  }

  // ---- T4-4 积压丢弃回告（architecture §1 不重放模型）----

  /// 是否处于离线（断连）窗口——执行环据此将到达的工具调用判为积压丢弃。
  bool get isOffline => _state == ConnectionState.offline;

  /// 离线窗口内累计丢弃的积压工具调用数（恢复回告后清零）。
  int get droppedBacklog => _droppedBacklog;

  /// 离线窗口内到达的工具调用，整体丢弃（不重放）。执行环在 [isOffline] 时调用
  /// 本方法计数，并返回 [backlogDroppedResult] 让 LLM 自纠。
  void noteBacklogDropped({int n = 1}) {
    assert(n > 0);
    _droppedBacklog += n;
  }

  /// canonical 积压丢弃结果（isError，文本供 LLM 自纠，不重放）。
  static const String backlogDroppedMessage =
      '⚠ 连接中断，积压请求已丢弃，不重放（写操作重放有副作用风险）';

  /// 离线窗口工具调用的 canonical 丢弃结果（供执行环直接返回）。
  ToolExecutionResult get backlogDroppedResult =>
      ToolExecutionResult(content: backlogDroppedMessage, isError: true);

  /// 离线窗口工具调用门：离线则整体丢弃（计数 + canonical isError）；在线则透传 [run]。
  ///
  /// T4 收官时由 [ToolRouter]/执行环在每条 tools/call 前经本门路由（替换直接
  /// `face.execute`），实现「积压整体丢弃、不重放」而不改写既有协议层。
  Future<ToolExecutionResult> guardExecute(
    Future<ToolExecutionResult> Function() run,
  ) async {
    if (isOffline) {
      noteBacklogDropped();
      return backlogDroppedResult;
    }
    return run();
  }

  /// 恢复成功后回报离线窗口积压并清零（无积压则不发）。
  void _reportBacklog() {
    if (_droppedBacklog <= 0) return;
    final n = _droppedBacklog;
    _droppedBacklog = 0;
    onBacklogReport?.call(BacklogReport(droppedCount: n));
  }

  /// offline→online 重连：带指数退避调度，重连成功后清零 attempt。
  Future<ReconnectReport> _reconnectWithBackoff() async {
    if (_reconnectAttempts > 0) {
      final wait = backoff.delayFor(_reconnectAttempts - 1);
      if (wait > Duration.zero) await Future.delayed(wait);
    }
    final report = await reconnect();
    if (report.success) {
      _reconnectAttempts = 0;
    } else {
      _reconnectAttempts++;
    }
    return report;
  }

  /// 重连核心（D17）：重 negotiate + 重 listTools + 激活集差分清洗。
  ///
  /// 与最新 listTools 做交集——被废弃/下线的已激活工具自动剔除并记日志。失败
  /// （协商或 listTools 异常）返回 success=false 且不动激活集（下次 offline→online
  /// 或外部重试会再次触发，退避已在 [_reconnectWithBackoff] 兜底）。
  Future<ReconnectReport> reconnect() async {
    try {
      client.resetNegotiation(); // 旧 session 失效，强制重握手（D17 重 negotiate）
      await client.negotiate();
      final newNames = (await _face.listToolNames()).toSet(); // 重 listTools（刷新 face 缓存）
      final dropped = _activatedToolNames
          .where((n) => !newNames.contains(n))
          .toList(growable: false);
      if (dropped.isNotEmpty) {
        _activatedToolNames.removeAll(dropped);
        debugPrint(
          '[DEGRADE] mcp-conn: dropped tools after reconnect (server '
          'restart?): $dropped',
        );
        onActivationChanged
            ?.call(List.of(dropped), List.of(_activatedToolNames));
      }
      await _resyncSubscriptions(); // T4-5：重放订阅（server 重启清空订阅）
      return ReconnectReport(
        success: true,
        droppedTools: dropped,
        currentTools: newNames.toList(growable: false),
      );
    } catch (e) {
      return ReconnectReport(success: false, error: e);
    }
  }

  /// T4-5 收官（订阅触发，宿主无关）：server 声明 `resources.subscribe` 时，经标准
  /// `resources/list` 列出全部 uri 并逐个订阅（不硬编码具体 uri 方案；HTTP 下顺带
  /// 起 GET SSE 监听，Binder 下订阅走 Binder 回程、通知经 EventChannel 分发）。
  /// [force]=true 跳过幂等去重（重连重放场景）。best-effort：失败仅 [DEGRADE] 留痕，
  /// 不阻断连接。
  Future<void> _subscribeAllResources({bool force = false}) async {
    try {
      await client.negotiate(); // 幂等：确保 capabilities 就绪
      if (!client.canSubscribe) return;
      final resources = await client.listResources();
      final uris = [
        for (final r in resources)
          if (r['uri'] is String) r['uri'] as String,
      ];
      for (final uri in uris) {
        try {
          await client.subscribeResource(uri, force: force);
        } catch (e) {
          debugPrint('[DEGRADE] mcp-conn: subscribe $uri failed: $e');
        }
      }
      unawaited(client.startNotificationListener()); // 幂等：HTTP 起 GET SSE；Binder no-op
      debugPrint('[mcp-conn] 已订阅 $serverId 的 ${uris.length} 个资源（失效感知就绪）');
    } catch (e) {
      debugPrint('[DEGRADE] mcp-conn: subscribe-all failed: $e');
    }
  }

  /// 重连后重放订阅（T4-5）：server 重启会清空其订阅表，重放分两步——
  /// 1) 先按本地已记录的 [McpClient.subscribedUris] 重发（[force]=true 跳过幂等去重）：
  ///    这是重放主路径——server 端 `resources/list` 清单未必含客户端手动订阅的 uri，
  ///    且可能缺 `resources` 数组导致整段中断，故不依赖重列；
  /// 2) best-effort 重列 server 资源，补订阅客户端尚未订阅的新增 uri（不覆盖主路径）。
  /// 两步均 best-effort：单条失败仅 [DEGRADE] 留痕，不阻断连接；并重启 GET SSE
  /// 下行监听（断连时已 [stopNotificationListener]）。
  Future<void> _resyncSubscriptions() async {
    try {
      final known = client.subscribedUris;
      for (final uri in known) {
        try {
          await client.subscribeResource(uri, force: true);
        } catch (e) {
          debugPrint('[DEGRADE] mcp-conn: replay subscribe $uri failed: $e');
        }
      }
      try {
        final fresh = await client.listResources();
        for (final r in fresh) {
          final uri = r['uri'];
          if (uri is String && !known.contains(uri)) {
            try {
              await client.subscribeResource(uri, force: true);
            } catch (e) {
              debugPrint('[DEGRADE] mcp-conn: subscribe new $uri failed: $e');
            }
          }
        }
      } catch (e) {
        debugPrint('[DEGRADE] mcp-conn: resync listResources failed: $e');
      }
      unawaited(client.startNotificationListener());
      if (known.isNotEmpty) {
        debugPrint('[mcp-conn] 已重放 $serverId 的 ${known.length} 个订阅（server 重启后）');
      }
    } catch (e) {
      debugPrint('[DEGRADE] mcp-conn: resync subscriptions failed: $e');
    }
  }

  /// D19 失效感知 canonical TrackNote（订阅资源数据变更，不自动重读）。
  static const String resourceStaleMessage =
      '⚠ 数据已变更，如需最新请重新读取（不自动重读）';
}
