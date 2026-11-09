/// 应用级装配：宿主上线即接管**远程任务来源**的任务消费（M4-2；
/// ai-capability-export 通用化 2026-11-09：goodshare 独有支持退役——
/// 来源由 [TaskSourceRegistry] 契约探测自动装配，任何实现
/// 远程任务队列契约的插件即成为消费来源，goodshare 为首个实现）。
///
/// 契约 = goodshare 仓 ai-app-split.md §3.12：§3.2 是**拉模型**（来源不
/// 推、宿主主动 claim）。宿主侧 claim 调用链曾因人类入口归档而消失 → 任务
/// 永久滞留 pending。本件把「拉手」接到「手臂」：
///
/// - **catch-up 是地基**：宿主挂载来源后主动 claim 到 idle 一次（不依赖
///   跨仓通知；通知只优化延迟，不承担正确性）；
/// - **宿主自主**：只在挂载/启动/手动触发时消费，**不引入常驻后台轮询**；
/// - 失败一律 DEGRADE 留痕、不阻断启动（与 `main.dart` 既有启动动作同纪律）。
///
/// **通用形态（每来源独立循环）**：所有受信任本地插件都挂通用反向面
/// （`ai/complete` 算力借用 + K17 死亡联动 + 任务池——算力消费与任务契约
/// 正交）；契约探测命中者额外建消费循环（单飞纪律 per 来源；算力共享由
/// 引擎单槽裁决）。框架层零包名特判。
///
/// 跨域装配职责归位（仿 `service_directory.dart`）：本件是应用级装配件，
/// 允许 import mcp / coordinator / task；窗口层不参与装配，只注入运行态端口。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../coordinator/supply_task_pool.dart';
import '../coordinator/caller_death_interrupt.dart';
import '../coordinator/hybrid_assembly.dart';
import '../coordinator/hybrid_inference.dart';
import '../coordinator/reverse_wiring.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/on_device_capability.dart';
import '../llm/on_device_engine.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/mcp_client.dart';
import '../mcp/trusted_plugins.dart';
import '../mcp/transport/binder_transport.dart';
import '../task/task_consume_ledger.dart';
import '../task/task_consume_loop.dart';
import '../task/task_loop_service.dart';
import '../task/task_source_registry.dart';

/// 宿主任务消费引导：装配 → 触发 catch-up → 生命周期解绑。
class TaskConsumeBootstrap {
  TaskConsumeBootstrap({
    LocalPluginSource? discovery,
    this.trustGate,
    this.ledger,
    this.onEvent,
    TaskSourceRegistry? sourceRegistry,
  })  : _discovery = discovery ?? localPluginDiscovery,
        _sourceRegistry = sourceRegistry ?? const TaskSourceRegistry();

  /// 插件来源（装配期消费面，可注入假件——`LocalPluginSource` 正是为此引入）。
  final LocalPluginSource _discovery;

  /// 信任闸（W1-S04：任务路径与聊天页/网关装配同受信任白名单约束，判定
  /// 经 S03 单一入口 [localPluginTrustSatisfied]）。null = 生产默认读
  /// `TrustedPlugins` 单例；单测注入假件避免 SharedPreferences 依赖。
  final PluginTrustGate? trustGate;

  /// 来源注册表（契约探测；可注入假件测多来源/无来源形态）。
  final TaskSourceRegistry _sourceRegistry;

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

  /// 来源句柄集（每来源一个：client + 反向面 + 可选消费循环）。
  List<_SourceHandle>? _handles;

  /// 在途任务元信息（对账用：`Applied`/`LoopFailed` 事件只带 taskId，明细需
  /// itemId 与 action —— 用户据此确认「我那条笔记处理了没有」）。
  final Map<String, ({String itemId, String action})> _inflight = {};

  /// 首个消费循环（兼容单来源时代观测面；全无来源 = null）。
  TaskConsumeLoop? get loop {
    final handles = _handles;
    if (handles == null) return null;
    for (final h in handles) {
      if (h.loop != null) return h.loop;
    }
    return null;
  }

  /// 启动：扫描本地插件 → 逐来源（信任判定 → 反向面挂载 → 契约探测 →
  /// 消费循环）→ 触发 catch-up。
  ///
  /// 幂等语义：重复调用返回首个消费循环（无消费来源 = null），不重复建
  /// 连接。失败来源 DEGRADE 留痕、不阻断其余来源（插件未安装/未信任/探测
  /// 失败均不阻断启动）。
  Future<TaskConsumeLoop?> start({CloudLlmEngine? engine}) async {
    if (_handles != null) return loop;
    await ledger?.load();
    final handles = <_SourceHandle>[];
    TaskConsumeLoop? firstLoop;
    try {
      final locals = await _discovery.scan();
      final resolvedEngine = await assembleDefaultHybridEngine();
      ensureCallerDeathInterruptWired();
      BinderTransport.onCallerDeath = (callerKey) =>
          unawaited(callerDeathInterruptSingleton?.notifyDeath(callerKey));
      for (final info in locals) {
        try {
          final handle = await _attachSource(info, engine: resolvedEngine);
          handles.add(handle);
          if (handle.loop != null && firstLoop == null) firstLoop = handle.loop;
        } on Object catch (e) {
          debugPrint('[DEGRADE] task-consume source ${info.packageName}: $e');
        }
      }
      _handles = handles;
      // catch-up：宿主上线即消化积压（各来源独立触发）。
      for (final h in handles) {
        h.loop?.trigger();
      }
    } on Object catch (e) {
      debugPrint('[DEGRADE] task-consume bootstrap: $e');
      // 部分成功仍保留已建句柄（来源级降级，不整体回滚）。
      if (handles.isNotEmpty) _handles = handles;
      return loop;
    }
    debugPrint('[task-consume] sources=${handles.length} '
        'consuming=${handles.where((h) => h.loop != null).length}');
    return firstLoop;
  }

  /// 单来源装配：信任判定 → client → 反向面（通用算力面）→ 契约探测 →
  /// 消费循环（命中契约才建）。
  Future<_SourceHandle> _attachSource(
    LocalPluginInfo info, {
    required CloudLlmEngine engine,
  }) async {
    // W1-S04：任务路径与聊天页/网关装配同受信任白名单约束，判定经 S03
    // 单一入口（未信任 = 拒挂载，DEGRADE 留痕）。
    final gate = trustGate ?? await TrustedPlugins.instance;
    if (!localPluginTrustSatisfied(info, gate)) {
      throw StateError('未信任的本地插件 ${info.packageName}（请先在聊天页/设置信任）');
    }
    final client = _discovery.createClient(info);
    _SourceHandle? handle;
    try {
      // 通用反向面（收编后形态）：ai/complete + ai/cancel + 拉取面——所有
      // 受信任插件可借宿主算力（与任务契约正交）；callerKey = 包名（K17）。
      wireOnDeviceReverse(
        client: client,
        onDeviceCapability:
            AidlOnDeviceCapabilityService(sharedOnDeviceEngine),
        callerKey: info.packageName,
        // 收编（0.5.0）：ai/complete 冷态联合态任务池——本 isolate 的受理链
        // 实例经此处装配（缺挂 = deferred 恒回落同步 fast-fail，2026-11-09
        // 真机回归实证）。
        taskPool: SupplyTaskPool.instance,
      );
      // 契约探测（negotiate + tools/list + 锚匹配整体内聚 registry）：
      // 命中远程任务队列契约 → 建消费循环；未命中 = 普通插件。
      final source = await _sourceRegistry.resolve(info, client);
      TaskConsumeLoop? loop;
      if (source != null) {
        final service = TaskLoopService(
          api: source,
          inference: HybridTaskInference(engine: engine),
        );
        service.onEvent = (event) => _onLoopEvent(event, source.serverId);
        loop = _buildLoop(service);
      }
      handle = _SourceHandle(
        info: info,
        client: client,
        serverId: info.packageName,
        loop: loop,
      );
    } on Object {
      client.close();
      rethrow;
    }
    return handle;
  }

  /// 手动触发（如设置页「立即处理」、重连后补拉）：遍历全部消费循环。
  void trigger() {
    for (final h in _handles ?? const <_SourceHandle>[]) {
      h.loop?.trigger();
    }
  }

  /// 生命周期解绑（§3.12.2-7）：清定时器 + 复位状态机 + 释放 client。
  /// 幂等；解绑后 [trigger] 无副作用。
  void dispose() {
    for (final h in _handles ?? const <_SourceHandle>[]) {
      h.loop?.dispose();
      h.client.close();
    }
    _handles = null;
  }

  /// 对账记账：把闭环事件落到账本（ledger == null 时仅清理在途表）。
  /// [serverId] = 事件所属来源（per-handle 闭包捕获，对账按服务分组）。
  void _onLoopEvent(TaskLoopEvent event, String serverId) {
    switch (event) {
      case TaskClaimed(:final taskId, :final itemId, :final taskAction):
        _inflight[taskId] = (itemId: itemId, action: taskAction);
      case Applied(:final taskId):
        _record(taskId, serverId, ok: true);
      case NotFoundClosed(:final taskId, :final note):
        _record(taskId, serverId, ok: false, reason: note);
      case LoopFailed(:final taskId, :final error):
        _record(taskId, serverId, ok: false, reason: '$error');
      case ClaimStarted():
      case QueueIdle():
      case HeartbeatSent():
        break; // 非终态事件不记账
    }
  }

  void _record(String? taskId, String serverId,
      {required bool ok, String? reason}) {
    final ledger = this.ledger;
    if (taskId == null || ledger == null) return;
    final meta = _inflight.remove(taskId);
    unawaited(ledger.record(TaskLedgerEntry(
      atMs: DateTime.now().millisecondsSinceEpoch,
      taskId: taskId,
      itemId: meta?.itemId ?? '',
      action: meta?.action ?? '',
      ok: ok,
      serverId: serverId,
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
}

/// 来源句柄：一个受信任本地插件的完整装配（client + 通用反向面 + 可选消费
/// 循环）。[loop] = null 表示该插件未实现任务队列契约（仅算力借用方）。
class _SourceHandle {
  _SourceHandle({
    required this.info,
    required this.client,
    required this.serverId,
    required this.loop,
  });

  final LocalPluginInfo info;
  final McpClient client;
  final String serverId;
  final TaskConsumeLoop? loop;
}

/// 进程级单例（装配层共享，`main` 启动、窗口层注入运行态端口）。
final TaskConsumeBootstrap taskConsumeBootstrap = TaskConsumeBootstrap();
