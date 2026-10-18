/// 应用级装配：宿主上线即接管 goodshare 任务消费（M4-2）。
///
/// 契约 = goodshare 仓 ai-app-split.md §3.12：§3.2 是**拉模型**（goodshare 不
/// 推、宿主主动 claim）。宿主侧 claim 调用链曾因人类入口归档而消失 → 任务
/// 永久滞留 pending。本件把「拉手」接到「手臂」：
///
/// - **catch-up 是地基**：宿主挂载 goodshare 后主动 claim 到 idle 一次（不依赖
///   跨仓通知；通知只优化延迟，不承担正确性）；
/// - **宿主自主**：只在挂载/启动/手动触发时消费，**不引入常驻后台轮询**；
/// - 失败一律 DEGRADE 留痕、不阻断启动（与 `main.dart` 既有启动动作同纪律）。
///
/// 跨域装配职责归位（仿 `service_directory.dart`）：本件是应用级装配件，
/// 允许 import mcp / coordinator / task；窗口层不参与装配，只注入运行态端口。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../coordinator/hybrid_assembly.dart';
import '../coordinator/hybrid_inference.dart';
import '../llm/cloud/cloud_llm.dart';
import '../mcp/goodshare_task_api.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/mcp_client.dart';
import '../task/task_consume_ledger.dart';
import '../task/task_consume_loop.dart';
import '../task/task_loop_service.dart';

/// goodshare 本地插件包名（跨仓常量，与 ai-app-split.md §3.12.3 唤醒包名同族）。
const kGoodsharePackage = 'com.zzh.goodshare';

/// 宿主任务消费引导：装配 → 触发 catch-up → 生命周期解绑。
class TaskConsumeBootstrap {
  TaskConsumeBootstrap({
    LocalPluginSource? discovery,
    this.ledger,
    this.onEvent,
  }) : _discovery = discovery ?? localPluginDiscovery;

  /// 插件来源（装配期消费面，可注入假件——`LocalPluginSource` 正是为此引入）。
  final LocalPluginSource _discovery;

  /// 对账账本（null = 不记账）。生产由 `main` 装配 `underSupportDir` 实例，
  /// 与设置页对账分区共享同一对象（跨会话持久化，重启不清零）。**可变**：
  /// 支持目录需异步获取，装配早于账本就位。
  TaskConsumeLedger? ledger;

  /// 可观测事件（消费循环事件原样透出，供日志/遥测）。
  final void Function(TaskConsumeEvent event)? onEvent;

  /// 算力让路端口（§3.12.2-2）：由窗口层在运行态建立后注入；**可变**——本件
  /// 装配早于窗口层运行态，故经闭包读最新值（见 [_buildLoop]）。
  bool Function()? isHostBusy;

  /// 通道存活端口（§3.12.2-7）：null = 不校验。
  bool Function()? isChannelAlive;

  TaskConsumeLoop? _loop;
  McpClient? _client;

  /// 当前来源 server 标识（对账按服务划分的键；start 时取 goodshare 包名）。
  String? _serverId;

  /// 在途任务元信息（对账用：`Applied`/`LoopFailed` 事件只带 taskId，明细需
  /// itemId 与 action —— 用户据此确认「我那条笔记处理了没有」）。
  final Map<String, ({String itemId, String action})> _inflight = {};

  /// 当前消费循环（未启动/启动失败 = null）。
  TaskConsumeLoop? get loop => _loop;

  /// 启动：扫描本地插件 → 装配 goodshare 消费链路 → 触发 catch-up。
  ///
  /// 幂等语义：重复调用返回既有 [_loop]，不重复建连接。失败返回 null 并
  /// DEGRADE 留痕（插件未安装 / 未发现 / 引擎装配失败均不阻断启动）。
  Future<TaskConsumeLoop?> start({CloudLlmEngine? engine}) async {
    final existing = _loop;
    if (existing != null) return existing;
    await ledger?.load();
    try {
      final info = await _findGoodshare();
      if (info == null) {
        debugPrint('[task-consume] 未发现 goodshare 本地插件，跳过');
        return null;
      }
      _serverId = info.packageName; // 对账按服务划分的键
      final client = _discovery.createClient(info);
      _client = client;
      final resolvedEngine = engine ?? await assembleDefaultHybridEngine();
      final service = TaskLoopService(
        api: GoodshareTaskApi(client),
        inference: HybridTaskInference(engine: resolvedEngine),
      );
      service.onEvent = _onLoopEvent; // 对账记账（细粒度：claimed/applied/failed）
      final loop = _buildLoop(service);
      _loop = loop;
      loop.trigger(); // catch-up：宿主上线即消化积压
      return loop;
    } on Object catch (e) {
      debugPrint('[DEGRADE] task-consume bootstrap: $e');
      return null;
    }
  }

  /// 手动触发（如设置页「立即处理」、重连后补拉）。
  void trigger() => _loop?.trigger();

  /// 生命周期解绑（§3.12.2-7）：清定时器 + 复位状态机 + 释放 client。
  /// 幂等；解绑后 [trigger] 无副作用。
  void dispose() {
    _loop?.dispose();
    _loop = null;
    _client?.close();
    _client = null;
  }

  /// 对账记账：把闭环事件落到账本（ledger == null 时仅清理在途表）。
  void _onLoopEvent(TaskLoopEvent event) {
    switch (event) {
      case TaskClaimed(:final taskId, :final itemId, :final taskAction):
        _inflight[taskId] = (itemId: itemId, action: taskAction);
      case Applied(:final taskId):
        _record(taskId, ok: true);
      case NotFoundClosed(:final taskId, :final note):
        _record(taskId, ok: false, reason: note);
      case LoopFailed(:final taskId, :final error):
        _record(taskId, ok: false, reason: '$error');
      case ClaimStarted():
      case QueueIdle():
      case HeartbeatSent():
        break; // 非终态事件不记账
    }
  }

  void _record(String? taskId, {required bool ok, String? reason}) {
    final ledger = this.ledger;
    if (taskId == null || ledger == null) return;
    final meta = _inflight.remove(taskId);
    unawaited(ledger.record(TaskLedgerEntry(
      atMs: DateTime.now().millisecondsSinceEpoch,
      taskId: taskId,
      itemId: meta?.itemId ?? '',
      action: meta?.action ?? '',
      ok: ok,
      serverId: _serverId ?? '',
      reason: reason,
    )));
  }

  TaskConsumeLoop _buildLoop(TaskLoopService service) => TaskConsumeLoop(
        service: service,
        // 闭包读最新字段：窗口层后置注入的端口对已建循环同样生效。
        isHostBusy: () => isHostBusy?.call() ?? false,
        isChannelAlive: isChannelAlive == null ? null : () => isChannelAlive!(),
        onEvent: onEvent,
      );

  Future<LocalPluginInfo?> _findGoodshare() async {
    final locals = await _discovery.scan();
    for (final info in locals) {
      if (info.packageName == kGoodsharePackage) return info;
    }
    return null;
  }
}

/// 进程级单例（装配层共享，`main` 启动、窗口层注入运行态端口）。
final TaskConsumeBootstrap taskConsumeBootstrap = TaskConsumeBootstrap();
