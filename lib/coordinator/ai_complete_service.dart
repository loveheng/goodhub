/// 对外 AI 能力原语统一受理链（ai-capability-export M-B）。
///
/// 契约：`ai/complete` + `ai/cancel`（线级常量 = goodhub-mcp-sdk `:contract`
/// 0.4.0 `McpContract.AI_*`；契约正文 = 契约仓 api.md §8；接缝裁决 =
/// goodshare ai-app-split.md §3.13；设计稿 = `docs/design/ai-capability-export.md`）。
///
/// 职责（设计稿 §6.1 净新增 ①②④ 的宿主侧承载）：
/// - **ai/complete 受理链单源**：参数校验 → 文本预算（128KB 线）→ K22 配额 →
///   D1 路由（设备主裁决，禁调用方强制）→ HardwareGuard（端侧腿）→ 隔离执行；
/// - **_async 多帧承载**：`{"_async": true}` ack → `_meta.phase` progress 帧 →
///   同 id 终帧（全走 answerReverse 同 id 多次透传，见 binder_transport 会话钩子）；
/// - **ai/cancel 幂等**：按 `cancel_id` 摘除在途；已完成/不存在静默确认；
/// - **K17 死亡清理 + QoS 抢占**：在途请求挂 K17 注册表（调用方死亡协作式
///   打断 + 作废）；宿主自用进入（[preemptAllForHostUse]）对在途外部任务发
///   协作式打断并回 `PREEMPTED_BY_HOST` + `retry_after_ms`；
/// - **受理期保活（三钥匙）**：冷装载窗口持平台保活，任务终态 / cancel /
///   调用方死亡任一触发即释放（[SupplyKeepalive] 引用计数 + 平台侧超时兜底）；
/// - **sampling 适配壳核心（D2 收敛）**：[completeCore] 供 mcp 层
///   `samplingRequestHandler` 注入——sampling/ai/complete 共享同一受理链，
///   路由/限流/审计只写一遍（禁双推理路径）。
///
/// 红线对齐：
/// - **K20 隔离**：两腿皆临时会话——prompt/产出不入 transcript/workspace/记忆；
/// - **K11 协作式打断**：打断未生效不得假设算力已腾出；禁重启引擎腾算力；
/// - **K17 死亡联动**：调用方死亡 → 打断 + 作废（产出即弃、不回程、不计频次）；
/// - **K22 配额事务**：并发 acquire/release 恒配对（try/finally）；频次产出才计；
/// - **禁静默降级**：端侧不可用不自动切云（D1 路由权归设备主）；云腿未承载
///   `responseFormat` 时显式拒服务（S17b 红线：结构化场景禁无约束降级档）。
///
/// 失败语义：结构化十二码表（[AiWire] 常量，`error.code = -32000` +
/// `error.data.status`；`retry_after_ms` 仅提示非承诺）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/chat_message_data.dart';
import '../core/errors/mcp_error.dart';
import '../llm/device_tier.dart';
import '../llm/on_device_capability.dart';
import '../llm/on_device_engine_binding.dart' show OnDeviceEngineBinding;
import '../mcp/sampling.dart' show SamplingEngine;
import '../mcp/transport/binder_transport.dart';
import 'ai_complete_wire.dart' show AiAuditSink, AiCompleteConfig, AiCompleteFailure, AiRouteLeg, AiRouteResolver, AiWire, aiContentViolationDefault, kAiDefaultRetryAfterMs, kAiInputMaxBytes;
import 'ai_keepalive.dart';
import 'supply_task_pool.dart' show SupplyTaskPool, deferredReceiptJson;
import 'app_capability_profile.dart';
import 'caller_death_interrupt.dart';
import 'supply_quota.dart';

// 线级件薄转出口（既有消费面 import 路径零变化；正文住 ai_complete_wire.dart）。
export 'ai_complete_wire.dart'
    show
        AiWire,
        AiCompleteFailure,
        AiCompleteConfig,
        AiRouteLeg,
        AiRouteResolver,
        AiAuditSink,
        aiContentViolationDefault,
        kAiInputMaxBytes,
        kAiDefaultRetryAfterMs,
        kPrefAiExportRouteLeg,
        readAiExportRouteLeg,
        setAiExportRouteLeg;
export 'ai_keepalive.dart' show SupplyKeepalive;
export 'app_capability_profile.dart'
    show
        AiTrustTier,
        AppCapabilityProfile,
        AppCapabilityRegistry,
        CallerForegroundProbe,
        kAiViolationFreezeThreshold,
        kPrefAiFrozenCallers;

/// 在途条目（ai/cancel / K17 死亡 / QoS 抢占的寻址单元）。
class _InFlight {
  _InFlight(this.requestId, this.callerKey, this.emit);

  /// 原始请求 id（帧回写用；Binder 反向请求 id 可为 int/String）。
  final Object requestId;
  final String callerKey;
  final void Function(Map<String, Object?> frame) emit;

  /// 原语取消钩子（订阅建立后注入；null = 尚未订阅）。
  Future<void> Function()? cancel;

  /// 终态已定（终帧已发 / 已作废）——竞态防御位。
  bool ended = false;

  /// QoS 抢占（终帧已在抢占时刻发出，迟到的产出丢弃）。
  bool preempted = false;
}

/// 受理链执行产出（[completeCore] 消费）。
class CoreCompletion {
  const CoreCompletion({required this.text, required this.model});

  final String text;
  final String model;
}

/// 对外 AI 能力统一受理链。
///
/// 装配：`configure()` 由宿主装配点（McpRuntime / Gateway 经 reverse_wiring）
/// 注入两腿与治理件；未 configure 时 [instance] 以空腿惰性存在（所有请求
/// `HOST_OFFLINE`——未装配即未达，禁伪造能力）。
class AiCompleteService {
  AiCompleteService({
    OnDeviceCapabilityService? onDevice,
    SamplingEngine? cloudEngine,
    SupplyQuota? quota,
    Future<DeviceProbe?> Function()? probe,
    AiRouteResolver? routeResolver,
    SupplyKeepalive? keepalive,
    AppCapabilityRegistry? capabilityRegistry,
    AiAuditSink? auditSink,
    CallerForegroundProbe? foregroundProbe,
    SupplyTaskPool? taskPool,
  }) : keepalive = keepalive ?? SupplyKeepalive() {
    _onDevice = onDevice;
    _cloudEngine = cloudEngine;
    _quota = quota;
    _probe = probe;
    _routeResolver = routeResolver;
    _capabilityRegistry = capabilityRegistry;
    _auditSink = auditSink;
    _foregroundProbe = foregroundProbe;
    _taskPool = taskPool;
  }

  static AiCompleteService? _instance;

  /// 进程级单例（反向请求接线经 [configure] 注入能力；同进程唯一——在途表
  /// 与保活计数跨面共享，双实例即取消/抢占寻址分裂）。
  static AiCompleteService get instance => _instance ??= AiCompleteService();

  /// 装配点注入（幂等覆盖：两装配点传等价件；在途表随实例更换清空——装配
  /// 只发生在启动期，运行中重配属异常路径，在途请求由 K17/超时自行收敛）。
  static void configure({
    OnDeviceCapabilityService? onDevice,
    SamplingEngine? cloudEngine,
    SupplyQuota? quota,
    Future<DeviceProbe?> Function()? probe,
    AiRouteResolver? routeResolver,
    SupplyKeepalive? keepalive,
    AppCapabilityRegistry? capabilityRegistry,
    AiAuditSink? auditSink,
    CallerForegroundProbe? foregroundProbe,
    SupplyTaskPool? taskPool,
  }) {
    _instance = AiCompleteService(
      onDevice: onDevice,
      cloudEngine: cloudEngine,
      quota: quota,
      probe: probe,
      routeResolver: routeResolver,
      keepalive: keepalive ?? _defaultKeepalive(),
      capabilityRegistry: capabilityRegistry,
      auditSink: auditSink,
      foregroundProbe: foregroundProbe,
      taskPool: taskPool,
    );
  }

  /// 多装配点合并注入（**只填空腿，不清已装**——网关/聊天两装配点携带件
  /// 不对称，后装点覆盖会拆掉先装腿）：首次补齐即建实例，后续逐腿合并。
  static void ensureConfigured({
    OnDeviceCapabilityService? onDevice,
    SamplingEngine? cloudEngine,
    SupplyQuota? quota,
    Future<DeviceProbe?> Function()? probe,
    AiRouteResolver? routeResolver,
    SupplyKeepalive? keepalive,
    AppCapabilityRegistry? capabilityRegistry,
    AiAuditSink? auditSink,
    CallerForegroundProbe? foregroundProbe,
    SupplyTaskPool? taskPool,
  }) {
    final cur = _instance;
    if (cur == null) {
      configure(
          onDevice: onDevice,
          cloudEngine: cloudEngine,
          quota: quota,
          probe: probe,
          routeResolver: routeResolver,
          keepalive: keepalive,
          capabilityRegistry: capabilityRegistry,
          auditSink: auditSink,
          foregroundProbe: foregroundProbe,
          taskPool: taskPool);
      return;
    }
    cur._onDevice ??= onDevice;
    cur._cloudEngine ??= cloudEngine;
    cur._quota ??= quota;
    cur._probe ??= probe;
    cur._routeResolver ??= routeResolver;
    cur._capabilityRegistry ??= capabilityRegistry;
    cur._auditSink ??= auditSink;
    cur._foregroundProbe ??= foregroundProbe;
    cur._taskPool ??= taskPool;
  }

  static void resetForTest() => _instance = null;

  /// 生产保活挂钩（主进程 WakeLock；EngineServiceBridge 桥面 15min 硬超时
  /// 兜底键泄漏）。未接线平台 = 纯计数空转（DEGRADE 留痕）。
  static SupplyKeepalive _defaultKeepalive() => SupplyKeepalive(
        acquire: (key) => OnDeviceEngineBinding.channel
            .invokeMethod<void>('keepaliveAcquire', <String, Object>{'key': key}),
        release: (key) => OnDeviceEngineBinding.channel
            .invokeMethod<void>('keepaliveRelease', <String, Object>{'key': key}),
      );

  OnDeviceCapabilityService? _onDevice;
  SamplingEngine? _cloudEngine;
  SupplyQuota? _quota;
  Future<DeviceProbe?> Function()? _probe;
  AiRouteResolver? _routeResolver;
  AppCapabilityRegistry? _capabilityRegistry;
  AiAuditSink? _auditSink;
  CallerForegroundProbe? _foregroundProbe;
  SupplyTaskPool? _taskPool;

  /// 受理期保活（冷装载窗口持有；三钥匙 = 任务终态/cancel/死亡，汇于任务
  /// 收尾 finally + 打断 catch 的 [SupplyKeepalive.letGo]）。
  final SupplyKeepalive keepalive;

  final Map<String, _InFlight> _inflight = {};

  /// 观测面：在途请求数（测试/QoS 断言用）。
  int get inflightCount => _inflight.length;

  // ---- 线级入口（reverse_wiring 会话钩子消费） ----

  /// ai/complete + ai/cancel 分派。返回 true = 本 method 已受理（含错误帧）；
  /// false = 非 AI method（调用方回落既有反向钩子）。
  Future<bool> handleAiMethod({
    required String method,
    required Object id,
    required Object? params,
    ResolvedCallerIdentity? caller,
    required String callerKeyFallback,
    required void Function(Map<String, Object?> frame) emit,
  }) async {
    if (method == AiWire.methodComplete) {
      await _accept(
          id: id, params: params, caller: caller, callerKeyFallback: callerKeyFallback, emit: emit);
      return true;
    }
    if (method == AiWire.methodCancel) {
      await _cancel(id: id, params: params, emit: emit);
      return true;
    }
    return false;
  }

  Future<void> _accept({
    required Object id,
    required Object? params,
    ResolvedCallerIdentity? caller,
    required String callerKeyFallback,
    required void Function(Map<String, Object?> frame) emit,
  }) async {
    final callerKey = caller?.packageName ?? callerKeyFallback;
    final sw = Stopwatch()..start();
    void audit(String outcome) => debugPrint('[AI-CAP] caller=$callerKey '
        'skill=ai/complete ms=${sw.elapsedMilliseconds} $outcome');

    // ① 参数校验（契约 api.md §8.1）。
    final p = params is Map<String, Object?> ? params : const <String, Object?>{};
    final instruction = p['instruction'];
    final input = p['input'];
    if (instruction is! String || instruction.trim().isEmpty) {
      emit(_errorFrame(id, -32602, '缺少 instruction（任务指令）'));
      audit('reject=params');
      return;
    }
    if (input is! String) {
      emit(_errorFrame(id, -32602, '缺少 input（待处理文本）'));
      audit('reject=params');
      return;
    }
    final cfg = AiCompleteConfig.fromParams(p['config']);
    // 联合态收编（契约 0.5.0 §8.7）：allow_deferred 缺省 false = 冷态同步
    // fast-fail 存量零变化；true = 冷态原子入池回联合态回执（不等装载）。
    final allowDeferred = p['allow_deferred'] == true;
    final meta = p['_meta'];
    final progressToken =
        meta is Map ? meta['progressToken'] : null;
    final asyncCapable =
        progressToken is String && progressToken.isNotEmpty ||
            progressToken is num;
    void emitPhase(String phase, int progress) {
      if (!asyncCapable) return;
      emit(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': <String, Object?>{
          'progressToken': progressToken,
          'progress': progress,
          '_meta': <String, Object?>{AiWire.progressMetaPhase: phase},
        },
      });
    }

    // ② 受理链（档案 gate → 预算 → 配额 → 路由 → guard → 执行）。
    emitPhase(AiWire.phaseStartingHost, 0);
    try {
      final out = await _execute(
        instruction: instruction,
        input: input,
        cfg: cfg,
        callerKey: callerKey,
        asyncCapable: asyncCapable,
        allowDeferred: allowDeferred,
        onPhase: emitPhase,
        requestId: id,
        emit: emit,
      );
      if (out == null) {
        // 异步路径已自行发完全部帧（含终帧/作废）。
        await _writeAudit(callerKey, route: 'async', ok: true, durationMs: sw.elapsedMilliseconds);
        return;
      }
      emit(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': <String, Object?>{
          'content': <String, Object?>{'type': 'text', 'text': out.text},
          'model': out.model,
        },
      });
      audit('ok leg=${out.model} outChars=${out.text.length}');
      await _writeAudit(callerKey, route: out.model, ok: true, durationMs: sw.elapsedMilliseconds);
    } on AiCompleteFailure catch (e) {
      emit(_aiError(id, e.status, e.message, retryAfterMs: e.retryAfterMs));
      audit('fail=${e.status}');
      await _writeAudit(callerKey, route: '-', ok: false, durationMs: sw.elapsedMilliseconds, note: e.status);
    } on Object catch (e) {
      emit(_aiError(id, AiWire.failEngineFailed, '受理链未预期失败: $e'));
      audit('fail=unexpected');
      await _writeAudit(callerKey, route: '-', ok: false, durationMs: sw.elapsedMilliseconds, note: 'unexpected');
    }
  }

  /// ops.log 审计（§4 audit 恒开；fail-closed 纪律 = 写失败 DEGRADE 留痕，
  /// 网关审计件同款口径，不阻断受理）。
  Future<void> _writeAudit(String caller,
      {required String route, required bool ok, required int durationMs, String? note}) async {
    final sink = _auditSink;
    if (sink == null) return;
    try {
      await sink(
        caller: caller,
        method: AiWire.methodComplete,
        route: route,
        ok: ok,
        durationMs: durationMs,
        note: note,
      );
    } on Object catch (e) {
      debugPrint('[DEGRADE] ai-audit: $e');
    }
  }

  /// ai/cancel（幂等）：命中在途 → 协作式取消并摘除；未命中/已终态 → 静默
  /// 确认。被取消请求**不再发终帧**（调用方以本 ack 本地收口——契约 §8.4）。
  Future<void> _cancel({
    required Object id,
    required Object? params,
    required void Function(Map<String, Object?> frame) emit,
  }) async {
    final p = params is Map<String, Object?> ? params : const <String, Object?>{};
    final cancelId = p[AiWire.keyCancelId];
    if (cancelId is! String || cancelId.isEmpty) {
      emit(_errorFrame(id, -32602, '缺少 ${AiWire.keyCancelId}（被取消的请求 id）'));
      return;
    }
    final entry = _inflight[cancelId];
    if (entry != null && !entry.ended) {
      entry.ended = true;
      try {
        await entry.cancel?.call();
      } on Object catch (e) {
        debugPrint('[DEGRADE] ai/cancel($cancelId): $e');
      }
    }
    emit(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': <String, Object?>{}});
  }

  /// QoS（设计稿 §5）：宿主自用会话（USER_INTERACTIVE）进入时，对全部在途
  /// 外部任务发协作式打断——立即回 `PREEMPTED_BY_HOST` + `retry_after_ms`
  /// 终帧，迟到的产出丢弃（打断未生效不得假设算力已腾出，K11 红线由引擎侧
  /// 终态自收；禁重启引擎腾算力）。挂点 = 宿主端侧生成入口（hybrid_device_leg）。
  static Future<void> preemptAllForHostUse() async {
    final svc = _instance;
    if (svc == null || svc._inflight.isEmpty) return;
    final entries = List.of(svc._inflight.values);
    for (final entry in entries) {
      if (entry.ended) continue;
      entry.ended = true;
      entry.preempted = true;
      entry.emit(_aiError(
        entry.requestId,
        AiWire.failPreemptedByHost,
        '宿主自用任务进入，本次外部推理协作式让路（稍后重试）',
        retryAfterMs: kAiDefaultRetryAfterMs,
      ));
      try {
        await entry.cancel?.call();
      } on Object catch (e) {
        debugPrint('[DEGRADE] ai-preempt(${entry.requestId}): $e');
      }
    }
  }

  // ---- 统一核心（ai/complete 受理 + sampling 适配壳共用；D2 收敛单源） ----

  /// sampling 适配壳核心（mcp 层经 `samplingRequestHandler(completeCore:)`
  /// 注入——mcp 域禁反向 import coordinator，故以纯值函数跨界）。
  /// 路由/配额/隔离/审计与 ai/complete 同一份链（D2：禁双推理路径）。
  Future<CoreCompletion> completeCore({
    required String instruction,
    required String input,
    int? maxTokens,
    double? temperature,
  }) async {
    final out = await _execute(
      instruction: instruction,
      input: input,
      cfg: AiCompleteConfig(maxTokens: maxTokens, temperature: temperature),
      callerKey: 'sampling-shell',
      asyncCapable: false,
    );
    return CoreCompletion(text: out!.text, model: out.model);
  }

  /// 受理链执行（失败抛 [AiCompleteFailure]）。
  ///
  /// 返回 null = 异步路径已自行发完全部帧（含终帧/作废），调用方不再补发；
  /// 非 null = 同步直出（调用方包 result 帧）。
  Future<CoreCompletion?> _execute({
    required String instruction,
    required String input,
    required AiCompleteConfig cfg,
    required String callerKey,
    required bool asyncCapable,
    bool allowDeferred = false,
    void Function(String phase, int progress)? onPhase,
    Object? requestId,
    void Function(Map<String, Object?> frame)? emit,
  }) async {
    // ⓪ 能力档案 gate（§4 唯一裁决点）：冻结 = capabilityScope 撤销 →
    // UNAUTHORIZED（含解冻指引）；lifecyclePolicy 前台校验（探针未知 = 放行，
    // 未知 ≠ 已知有害）；per-caller 限流取档案配额（缺档案时回退装配配额）。
    final registry = _capabilityRegistry;
    SupplyQuota? effectiveQuota = _quota;
    if (registry != null) {
      final profile = await registry.profileFor(callerKey);
      if (profile.revoked) {
        throw const AiCompleteFailure(
          AiWire.failUnauthorized,
          '本应用的 AI 借用权限已被冻结（连续内容违规）——可在 GoodHub 设置中申请解冻',
        );
      }
      final probe = _foregroundProbe;
      if (profile.requiresForeground && probe != null) {
        final foreground = await probe(callerKey);
        if (foreground == false) {
          throw const AiCompleteFailure(
            AiWire.failCallerNotInForeground,
            '后台调用被拒（本信任档仅前台可用）——请切换到前台后重试',
          );
        }
      }
      effectiveQuota = profile.quota;
    }

    // ① 文本预算（128KB 线；UTF-8 字节口径）。
    if (utf8.encode(input).length > kAiInputMaxBytes) {
      throw const AiCompleteFailure(
        AiWire.failBudgetExceeded,
        '输入超 128KB 预算线（诚实降级：超线请求禁静默截断产废文）——请分段处理',
      );
    }

    // ② K22 配额：并发占用 → 频次预检（产出前）→ 产出才计入 → finally 释放。
    final quota = effectiveQuota;
    if (quota != null && !quota.acquire()) {
      throw AiCompleteFailure(
        AiWire.failResourceBusy,
        '宿主受理槽占满（并发上限 ${quota.maxConcurrent}），稍后重试',
        retryAfterMs: kAiDefaultRetryAfterMs,
      );
    }
    try {
      if (quota != null) {
        final denial = quota.checkFrequency(DateTime.now());
        if (denial != null) {
          throw AiCompleteFailure(
            AiWire.failRateLimit,
            '调用方频次超限（滑动窗口次数制）',
            retryAfterMs: denial.inMilliseconds,
          );
        }
      }

      // ③ D1 路由（设备主裁决；调用方无权强制）。
      final leg = await _resolveRoute();

      // ④ HardwareGuard（端侧腿前置拦截：温控 ≥SEVERE 或低电量未充电 →
      // 硬件自保熔断；转云端仅当路由裁决本身是云——禁静默降级）。
      try {
        if (leg == AiRouteLeg.onDevice) {
          await _hardwareGuard();
          final out = await _runOnDevice(instruction, input, cfg, callerKey,
            asyncCapable, allowDeferred, onPhase, requestId, emit);
          // K22 频次：仅实际产出计入（打断/取消/抢占路径 out=null 不计）。
          if (out != null) {
            quota?.countOutput(DateTime.now());
            registry?.resetViolations(callerKey); // 「连续违规」的另一半：成功复位
          }
          return out;
        }
        final cloudOut = await _runCloud(instruction, input, cfg);
        quota?.countOutput(DateTime.now());
        registry?.resetViolations(callerKey);
        return cloudOut;
      } on AiCompleteFailure catch (e) {
        // §5 安全防火墙：内容违规分类命中 → 连续计数（3 次冻结，注册表单源）。
        final r = _capabilityRegistry;
        if (r != null && aiContentViolationDefault(e.status, e.message)) {
          await r.reportViolation(callerKey, e.message);
        }
        rethrow;
      }
    } finally {
      quota?.release();
    }
  }

  Future<AiRouteLeg> _resolveRoute() async {
    final resolver = _routeResolver;
    if (resolver != null) return resolver();
    // 缺省路由：端侧优先（零成本零云延迟），端腿未装配回云腿；双腿皆缺 =
    // 宿主不可达（HOST_OFFLINE）。
    if (_onDevice != null) return AiRouteLeg.onDevice;
    if (_cloudEngine != null) return AiRouteLeg.cloud;
    throw const AiCompleteFailure(
        AiWire.failHostOffline, '宿主推理能力未装配（端侧/云端双腿皆缺）');
  }

  /// HardwareGuard（设计稿 §5）：温控 ≥SEVERE 或 低电量且未充电 →
  /// `DEVICE_THROTTLED`。探针不可用 = 放行（DeviceTierGate「未知 ≠ 已知有害」
  /// 同款口径；真保护由 :engine 运行时护栏链兜底）。
  Future<void> _hardwareGuard() async {
    final probe = _probe;
    if (probe == null) return;
    final DeviceProbe? p;
    try {
      p = await probe();
    } on Object catch (e) {
      debugPrint('[DEGRADE] ai-hardware-guard probe: $e');
      return;
    }
    if (p == null) return;
    final thermal = p.thermalStatus;
    if (thermal != null && thermal >= 3) {
      throw const AiCompleteFailure(
          AiWire.failDeviceThrottled, '设备温控 SEVERE+（硬件自保熔断，稍后重试）');
    }
    final battery = p.batteryPct;
    if (battery != null && battery >= 0 && battery < DeviceTierGate.minBatteryPct) {
      if (p.isCharging != true) {
        throw const AiCompleteFailure(
            AiWire.failDeviceThrottled, '电量低且未充电（硬件自保熔断，充电后重试）');
      }
    }
  }

  /// 端侧腿执行：状态预判（零等待调用方冷态 fast-fail）→ 冷装载（异步 +
  /// 保活）→ 可中断聚合（K17 + cancel + 抢占三源注册）。
  Future<CoreCompletion?> _runOnDevice(
    String instruction,
    String input,
    AiCompleteConfig cfg,
    String callerKey,
    bool asyncCapable,
    bool allowDeferred,
    void Function(String phase, int progress)? onPhase,
    Object? requestId,
    void Function(Map<String, Object?> frame)? emit,
  ) async {
    final device = _onDevice;
    if (device == null) {
      throw const AiCompleteFailure(
          AiWire.failHostOffline, '宿主端侧推理未装配');
    }
    final availability = await device.availability();
    if (availability == OnDeviceCapabilityAvailability.unavailable) {
      // 装载终态失败（资产缺失/设备不支持/内存不足）——非冷态，诚实归引擎失败。
      throw const AiCompleteFailure(
          AiWire.failEngineFailed, '端侧引擎不可用（装载终态失败）');
    }
    final cold = availability == OnDeviceCapabilityAvailability.cold;
    // 联合态收编（契约 0.5.0 §8.7）：冷态 + 显式 opt-in → 原子入池回执
    // （两种调用形态皆成立——deferred 本身即「不等」语义；先于 fast-fail
    // 与冷装载判定）。缺 callerKey 不受理（M5：无法寻址交付）。
    final pool = _taskPool;
    if (cold && allowDeferred && pool != null) {
      try {
        final entry = await pool.submit(
          callerKey: callerKey,
          instruction: instruction,
          input: input,
        );
        debugPrint('[AI-CAP] caller=$callerKey skill=ai/complete '
            'deferred taskId=${entry.taskId}');
        return CoreCompletion(
          text: jsonEncode(deferredReceiptJson(entry)),
          model: 'goodhub-on-device',
        );
      } on Object catch (pe) {
        // 入池失败（per-caller/全局配额满等）回落同步错误语义（调用方自处）。
        debugPrint('[DEGRADE] ai-complete deferred submit: $pe');
      }
    }
    if (cold && !asyncCapable) {
      // 状态预判（设计稿 §3.7 同步原子坍缩）：零等待调用方 + 非就绪 → 一 RTT
      // 结构化 fast-fail，零排队消耗。S16 懒加载边界同款（后台冷装载不被自动满足）。
      throw const AiCompleteFailure(
          AiWire.failModelCold, '端侧引擎冷态（零等待通道不装载）——请转异步形态等冷启动');
    }

    final keepaliveKey =
        'ai-complete-$callerKey-${DateTime.now().microsecondsSinceEpoch}';
    void Function()? unregisterK17;
    try {
      if (cold) {
        // 异步冷装载：LOADING_MODEL 阶段帧 + 受理期保活（防抖：仅此窗口持有）。
        onPhase?.call(AiWire.phaseLoadingModel, 1);
        await keepalive.hold(keepaliveKey);
        try {
          await device.loadExplicit();
        } on Object catch (e) {
          throw AiCompleteFailure(
              AiWire.failEngineFailed, '端侧模型装载失败: $e');
        }
      }
      onPhase?.call(AiWire.phaseGenerating, 3);

      // 在途登记（ai/cancel + QoS 寻址；sampling core 无 requestId 不登记）。
      final _InFlight? entry =
          (requestId != null && emit != null)
              ? _InFlight(requestId, callerKey, emit)
              : null;
      if (entry != null) {
        _inflight[requestId.toString()] = entry;
      }
      final primitive = device;
      final interruptible = primitive is OnDeviceInterruptible
          ? primitive as OnDeviceInterruptible
          : null;
      final config = OnDevicePrimitiveConfig(
        maxTokens: cfg.effectiveMaxTokens,
        temperature: cfg.temperature ?? 0.3,
        responseFormat: cfg.responseFormat,
      );
      String text;
      if (entry != null && interruptible != null) {
        text = await interruptible.completeInterruptible(
          instruction: instruction,
          input: input,
          config: config,
          fallback: PrimitiveFallbackPolicy.failFast,
          traceId: 'ai_complete_${DateTime.now().microsecondsSinceEpoch}',
          onSubscribed: (cancel) {
            entry.cancel = cancel;
            // K17 接线（同一注册表）：调用方死亡 → 协作式打断 + 作废。
            unregisterK17 = callerDeathInterruptSingleton
                ?.register(callerKey, () async {
              entry.ended = true;
              await cancel();
            });
          },
        );
      } else {
        // 退化路径（无在途登记需求 / 实现不支持可中断聚合）：语义同源，
        // 仅无打断能力（K17 在该形态不生效，属能力缺失非静默降级）。
        text = await device.complete(
          instruction: instruction,
          input: input,
          config: config,
          fallback: PrimitiveFallbackPolicy.failFast,
          traceId: 'ai_complete_${DateTime.now().microsecondsSinceEpoch}',
        );
      }
      if (entry != null && entry.ended) {
        // 取消/死亡/抢占竞态：产出作废（抢占终帧已发；cancel/死亡不发终帧）。
        return null;
      }
      _inflight.remove(requestId?.toString());
      entry?.ended = true;
      return CoreCompletion(text: text, model: 'goodhub-on-device');
    } on OnDeviceInterruptedException {
      // 打断生效（cancel/死亡/抢占）：cancel 与死亡不发终帧（调用方本地收口
      // / 已死）；抢占终帧已在抢占时刻发出。产出即弃、不计频次。
      return null;
    } on OnDevicePrimitiveException catch (e) {
      final msg = e.message;
      if (msg.contains('service_busy') || msg.contains('正被占用')) {
        throw AiCompleteFailure(AiWire.failResourceBusy, '端侧执行槽被占（$msg）',
            retryAfterMs: kAiDefaultRetryAfterMs);
      }
      if (msg.contains('PII')) {
        // 隐私围栏拒绝（fail-closed）——用户主权守卫语义；message 保留 PII
        // 锚（§5 违规分类命中靠它计入连续违规）。
        throw AiCompleteFailure(
            AiWire.failUserRejected, '输入含 PII 未通过宿主隐私围栏（fail-closed 拒绝）');
      }
      throw AiCompleteFailure(AiWire.failEngineFailed, '端侧推理失败: $msg');
    } finally {
      unregisterK17?.call();
      if (requestId != null) _inflight.remove(requestId.toString());
      await keepalive.letGo(keepaliveKey);
    }
  }

  /// 云腿执行（BYOK；N7 出站围栏经云引擎装饰器单咽喉自然覆盖——注入件即
  /// sampling 同一引擎实例）。**响应式承载体**：v1 云腿未承载约束解码，
  /// `responseFormat` 声明即显式拒服务（S17b 红线：结构化场景禁无约束降级档
  /// ——无约束产物必然解析失败，禁静默产出废文）。
  Future<CoreCompletion> _runCloud(
      String instruction, String input, AiCompleteConfig cfg) async {
    final cloud = _cloudEngine;
    if (cloud == null) {
      throw const AiCompleteFailure(
          AiWire.failHostOffline, '宿主云端推理未装配（BYOK 未配置）');
    }
    if (cfg.responseFormat != null) {
      throw const AiCompleteFailure(
        AiWire.failEngineFailed,
        '云端腿 v1 未承载约束解码（responseFormat）——结构化场景请走端侧路由'
        '（设备主裁决）或去除 responseFormat 声明',
      );
    }
    final messages = <ChatMessageData>[
      SystemChatMessage(instruction),
      UserChatMessage(input),
    ];
    final buf = StringBuffer();
    try {
      await for (final chunk in cloud.sendText(
        messages: messages,
        maxTokens: cfg.effectiveMaxTokens,
      )) {
        buf.write(chunk);
      }
    } on McpRpcException {
      rethrow;
    } on Object catch (e) {
      throw AiCompleteFailure(AiWire.failEngineFailed, '云端推理失败: $e');
    }
    final text = buf.toString().trim();
    if (text.isEmpty) {
      throw const AiCompleteFailure(AiWire.failEngineFailed, '云端产出为空');
    }
    return CoreCompletion(text: text, model: 'goodhub-cloud');
  }
}

/// 结构化错误帧（十二码表；`error.code = -32000` + `data.status` + 可选
/// `retry_after_ms`）。
Map<String, Object?> _aiError(
  Object id,
  String status,
  String message, {
  int? retryAfterMs,
}) =>
    <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{
        'code': AiWire.failureRpcCode,
        'message': message,
        'data': <String, Object?>{
          'status': status,
          // Dart null-aware 值：retryAfterMs 为 null 时整条键值缺席。
          AiWire.keyRetryAfterMs: ?retryAfterMs,
        },
      },
    };

/// 标准 JSON-RPC 错误帧（参数违规 -32602 等）。
Map<String, Object?> _errorFrame(Object id, int code, String message) =>
    <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': code, 'message': message},
    };
