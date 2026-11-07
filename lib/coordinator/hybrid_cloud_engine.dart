/// 混合引擎：按降级控制器在云端流式与端侧单发之间路由（M2-T2，architecture §2）。
///
/// - **端侧职责硬约束（§2）**：端侧不承担通用调度——仅当请求**无工具**（任务 note
///   类单发提取）时才可走端侧；带工具请求永远走云端；
/// - **判据触发**：云端失败/超时，当次请求立即端侧兜底（产出优先），并计入
///   控制器供后续请求路由；端侧也不可用时原样上抛（禁静默吞——调用方产出可观测 note）；
/// - **打断语义（S14e，K11，术语订正）**：云端恢复不干扰进行中推理——路由只
///   发生在请求起点，天然满足。端侧槽冲突走**协作式打断**（非抢占）：打断
///   只在生成循环检查点生效，等待窗口耗尽**不得假设打断已生效**，按策略性
///   降级处置（切云或显式上浮等待），**不得以重启引擎腾算力**（重启即冷装载
///   = 秒级装载 + 前台卡顿；仓内既有认知：打断等待可能被停止流调用吃掉，
///   见 lessons.md engine-stream 行）；
/// - **取消**：cancel 订阅即级联取消（§10 Abort 级联①步）——云端断流取消底层请求，
///   端侧经 StreamController onCancel 立即调 cancelActive 终止原生生成。
///
/// S3 拆分（extensibility-hardening）：本件只剩编排——探针采集 =
/// `hybrid_route_probes.dart`、冷装载状态机 = `hybrid_device_load.dart`、
/// 云腿 = `hybrid_cloud_leg.dart`、端腿 = `hybrid_device_leg.dart`；特征
/// golden = test/coordinator/hybrid_send_golden_test.dart。
library;

import 'package:flutter/foundation.dart';

import '../core/errors/inference_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/llm.dart';
import '../llm/on_device_asset_manager.dart';
import '../llm/on_device_engine.dart';
import '../llm/on_device_model_catalog.dart';
import 'capability_router.dart';
import 'degradation_controller.dart';
import 'hybrid_cloud_leg.dart';
import 'hybrid_device_leg.dart';
import 'hybrid_device_load.dart';
import 'hybrid_route_probes.dart';

// P1-5 预检判据纯函数已迁 `capability_router.dart` 单源（S14c，禁双式
// 漂移）；此处 re-export 保持既有 import 面与测试钉兼容。
export 'capability_router.dart' show onDeviceInputOverflows;
// S3 拆分兼容面：端腿语义件（归因过滤 / 中断白话 / 超窗异常）经本件
// re-export——既有测试 import 零改动。
export 'hybrid_device_leg.dart'
    show OnDeviceContextOverflowException, engineInterruptReason, evictionLifecycleDied;

class HybridCloudEngine implements CloudLlmEngine {
  HybridCloudEngine({
    required this.controller,
    this.cloud,
    this.onDevice,
    this.isOfflineProbe,
    this.deviceTierGate,
    this.deviceToolPolicy,
    this.preferOnDevice = false,
    this.isForegroundProbe,
    this.availMemProbe,
    this.quotaChecker,
    this.onDeviceModelResolver,
  }) : _enableCapable = onDevice is OnDeviceEnableCapable
            ? onDevice as OnDeviceEnableCapable
            : null;

  /// 端侧显式加载能力（探测：onDevice 实现 [OnDeviceEnableCapable] 才非 null）。
  /// 首次命中端侧路径前由 [send] 触发 [OnDeviceEnableCapable.enable]，加载过程
  /// 对用户可见；加载失败显式报错、不走云端。
  final OnDeviceEnableCapable? _enableCapable;

  final DegradationController controller;

  /// 云端引擎（null = 未配置 BYOK，仅端侧路径）。
  final CloudLlmEngine? cloud;

  /// 端侧引擎（null = 引擎未挂载/平台不支持）。
  final OnDeviceLlmEngine? onDevice;

  /// 前台态探针（注入；null = 视为后台保守处理）：场景 A/B/C 切云语义拆分——
  /// 场景 B（未加载 + 后台触发）**不切云**，打 PendingForegroundLoad 暂存等
  /// 前台；场景 C（未加载 + 前台发起）加载态 + 超时保护 → 显式失败或按需
  /// 降级云端。探测异常按**后台**处理（宁暂存，不误切云外发数据）。
  final Future<bool> Function()? isForegroundProbe;

  /// 物理断网探测（注入；null = 不探测视作在线）。判据「断网即切」的探测位，
  /// T3 接 Connectivity 实测。
  final Future<bool> Function()? isOfflineProbe;

  /// 设备分级门禁（§16，注入；null = 不门禁）。裁决 (pass, reason)；
  /// 关闸 ≡ 端侧不可用（路由语义与 onDevice=null 一致），reason 留痕可观测。
  final Future<({bool pass, String reason})> Function()? deviceTierGate;

  /// 端侧工具面判据（S2 正式接线，注入；null = 严格 `tools.isEmpty`）。
  ///
  /// §2 端侧硬约束的本意是「需要**云端工具编排**的请求不得走端侧」。但
  /// AgentLoop 的工具面恒定含宿主本地元工具（get_connected_apps / 记忆 /
  /// 资源等，宿主本地拦截执行），按字面 `tools.isEmpty` 纯聊天永远不可端侧。
  /// 注入方（hybrid_assembly）以「tools 全为宿主本地元工具 → 放行」收口——
  /// 端侧单发不产工具调用，元工具静默缺席 = 离线降级的可接受语义。
  final bool Function(List<CloudToolSchema> tools)? deviceToolPolicy;

  /// 用户偏好优先端侧（设置页持久化，默认 false）：即便云端健康也想走端侧；
  /// 门禁关闸 / 引擎死亡仍无缝切云（兜底语义不变）。默认 false = 云端优先，
  /// 避免 1.5B 弱模型在未选时默认降质。
  final bool preferOnDevice;

  /// 整机可用内存探针（S14d，注入；null = 不判交运行时护栏链兜底）：
  /// 返回 availMem bytes。判定链内存地板段值源——地板常量单源 =
  /// `MemoryGuardEvaluator.kt` ABSOLUTE_FLOOR_BYTES（1GB），探针异常按
  /// null（取证不可达不判）收口，禁把探针故障读成内存紧张。
  final Future<int?> Function()? availMemProbe;

  /// 调用方配额判定（S14d，注入；null = 无配额面不判——聊天路径 owner/
  /// 后台任务无按身份配额，外部 App 通道 W5 接线时注入）：返回 true =
  /// 该调用方配额已超限。配额实例由装配方持有（复用 `SamplingQuota`
  /// 滑窗形态，不新建限流器），判定链只消费结论。
  final bool Function()? quotaChecker;

  /// 当前选中端侧模型解析器（注入；null = 走落盘 `OnDeviceModelSelection.read`）。
  /// 值源与装配面同源，仅用于让窗口准入/超窗预检在测试与诊断场景可注入
  /// 指定窗口资产；缺省行为零变化。
  final Future<OnDeviceModelOption?> Function()? onDeviceModelResolver;

  // ---- S3 腿装配（thunk 断互引环：云腿恢复切端 ↔ 端腿失败切云）----

  late final HybridCloudLeg _cloudLeg = HybridCloudLeg(
    controller: controller,
    deviceLegOf: () => _deviceLeg,
    devicePromptOf: _buildPrompt,
    cloudForbidden: _cloudForbidden,
  );

  HybridDeviceLeg? _deviceLegCache;

  /// 端腿惰性构造（仅在端侧可用路径首次触达时；onDevice 为 null 的纯云端
  /// 引擎永不构造——`onDevice!` 在此安全）。
  HybridDeviceLeg get _deviceLeg => _deviceLegCache ??= HybridDeviceLeg(
        cloudLeg: _cloudLeg,
        cloud: cloud,
        device: onDevice!,
        devicePromptOf: _buildPrompt,
        cloudForbidden: _cloudForbidden,
        readSelectedModel: _readSelectedModel,
      );

  /// 排除位守卫单点（S14e，K10）：本步声明 `localOnly`（禁止云端）时，**任何
  /// 把请求内容送往云端的路径都必须关闸**——端侧运行时失败（引擎死亡 /
  /// 输入超窗 / 装载失败）的原语义是「切云保产出」，但切云即违反声明
  /// （该步数据出境）。
  ///
  /// 红线：排除位只在路由落空处拦、运行时留漏口 = 声明形同虚设——两处口径
  /// 必须一致。判定单一入口 = 本函数（禁各处散判 `requirement?.localOnly`）。
  bool _cloudForbidden(CloudChatRequest request) =>
      request.requirement?.localOnly == true;

  /// 端侧载荷构造单源（collector 同源，禁二次估法）。
  Future<HybridDevicePrompt> _buildPrompt(
    CloudChatRequest request, {
    OnDeviceModelOption? selected,
  }) =>
      buildDevicePrompt(request,
          selected: selected, onDeviceModelResolver: onDeviceModelResolver);

  /// 选中模型单一读取口（注入优先，缺省落盘选择）。
  Future<OnDeviceModelOption?> _readSelectedModel() =>
      onDeviceModelResolver?.call() ?? OnDeviceModelSelection.read();

  @override
  String get name => cloud == null
      ? '混合引擎（仅端侧）· ${onDevice?.name ?? '无'}'
      : '混合引擎 · ${cloud!.name}';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) async* {
    // —— 探针采集（独立件，纯读取零决策：判定链消费的全部现场一次取齐）——
    final probes = await collectHybridRouteProbes(
      request: request,
      controller: controller,
      onDevice: onDevice,
      enableCapable: _enableCapable,
      preferOnDevice: preferOnDevice,
      isOfflineProbe: isOfflineProbe,
      isForegroundProbe: isForegroundProbe,
      deviceTierGate: deviceTierGate,
      deviceToolPolicy: deviceToolPolicy,
      onDeviceModelResolver: onDeviceModelResolver,
      availMemProbe: availMemProbe,
      quotaChecker: quotaChecker,
    );
    // 门禁改 advisory（2026-10-31 用户裁决）：RAM/电量/温控判定只留痕提示，
    // 不拦路——真保护 = 运行时护栏链（:engine 隔离 + EngineDied 切云 + 熔断 +
    // 内存护栏驱逐 + MemGate 起跑闸 + :engine 温控连续确认沿）。误判史多次
    // 实证拦截成本高于收益，「紧急强行启用」随拦截语义一并退役。
    if (!probes.gate.pass) {
      debugPrint(
          '[HybridEngine] [advisory] 门禁不达标（不拦截）：${probes.gate.reason}');
    }
    // —— 判定（capability_router 纯函数）——
    final verdict = evaluateDeviceRoute(
      requirement: probes.requirement,
      deviceMounted: onDevice != null,
      deviceCold: probes.deviceCold,
      // 窗口段值源已接（S14c）：windowTokens/输入估算双未知不拦；画像段
      // 保持下方既有查表门禁（零行为变化）。
      windowTokens: probes.selectedModel?.contextTokens,
      profileExcluded: false,
      offline: probes.offline,
      subject: probes.subject,
      residentMatched: probes.residentMatched,
      inputEstimateTokens: probes.inputEstimateTokens,
      outputReserve: request.maxTokens ?? 512,
      availMemBytes: probes.availMemBytes,
      quotaExceeded: probes.quotaExceeded,
    );
    // 理由码随判定落库（D3 残余，S14b）：[ROUTE] 结构化行 = 路由判定的
    // 可观测载体（logcat 可 grep），理由码/段位/主体/驻留匹配全量在行。
    debugPrint('[ROUTE] ${verdict.deviceAllowed ? 'ALLOW' : 'BLOCK'}'
        ' stage=${verdict.blockedAt?.name ?? '-'}'
        ' declSide=${verdict.declarationSide}'
        ' governance=${verdict.governanceViolation}'
        ' localOnly=${verdict.localOnlyViolation}'
        ' exclude=${probes.requirement.localOnly}'
        ' subject=${probes.subject.name}'
        ' residentMatched=${probes.residentMatched?.toString() ?? 'unknown'}'
        ' cold=${probes.deviceCold} offline=${probes.offline}'
        ' availMem=${probes.availMemBytes?.toString() ?? 'unknown'}'
        '${verdict.reason.isEmpty ? '' : ' reason=${verdict.reason}'}');
    // 排除位违规（S14e，K10）与治理违规（配额超限，K9）：两端口径快速失败
    // 不切云（切云即数据出境 / 治理违规另走类型化异常，不叠加）。
    if (verdict.localOnlyViolation) {
      throw LocalOnlyViolationException(
        '本轮请求无法完成：${verdict.reason}',
        stage: verdict.blockedAt,
      );
    }
    if (verdict.governanceViolation) {
      throw QuotaExceededException(probes.subject.name);
    }
    var canDevice = verdict.deviceAllowed && onDevice != null;
    // D3：离线 + 交互级 + 冷态 = 装载等待（OFFLINE_COLD_LOAD_WAIT）——云端
    // 不可达时分流必失败，不拦，交既有就绪段装载分支（场景 B/C）；装载等待
    // 的取消语义（放弃本轮等待）随 S14b/D3 残余项落地。
    if (!verdict.deviceAllowed &&
        verdict.blockedAt == DeviceRouteStage.latency &&
        probes.offline) {
      canDevice = true;
    }
    // S14e 排除位收口单通道 = 上方 verdict.localOnlyViolation 分支
    // （LocalOnlyViolationException，覆盖声明不可满足类与端侧状态类全部
    // 落空段）；D3 离线装载等待特例已在判定链内豁免（localOnly 不禁端侧，
    // 等待装载是唯一可完成路径，合法）。此处不得再有第二 localOnly 处置
    // 分支（禁双通道漂移）。
    String? deviceSkipReason;
    if (!canDevice && onDevice != null) {
      deviceSkipReason = verdict.reason;
      debugPrint(
          '[HybridEngine] 端侧跳过（${verdict.declarationSide ? '声明侧' : '端侧状态侧'}）：$deviceSkipReason');
    }
    // DispatchProfile 路由查表（设计稿 §6，2026-11-01 拍板）：装载决策前读
    // 准入画像——双后端 EXCLUDED/ERROR → 查表即切云，不让 :engine 死一次
    // 确认坏后端；单坏（NPU.EXCLUDED 且 GPU 未探/健康）→ 放行，降级链自试。
    var profileExcluded = false;
    if (canDevice && probes.wantDevice) {
      try {
        // selectedModel 已在窗口值源处单次读取（S14c 上移），此处复用。
        final profile = probes.selectedModel == null
            ? null
            : await OnDeviceAssetManager.instance
                .readDispatchProfile(probes.selectedModel!);
        if (profile != null && profile.routeTarget() == null) {
          profileExcluded = true;
          debugPrint('[DEGRADE] HybridEngine: 准入画像双坏 → 切云 '
              '(NPU=${profile.backends['NPU']?.reason.name}/'
              'GPU=${profile.backends['GPU']?.reason.name})');
        }
      } catch (e) {
        debugPrint('[DEGRADE] HybridEngine: admission profile read: $e');
      }
    }
    // S14e 排除位守卫：准入画像双坏的处置是切云（坏后端记忆，下轮查表直跳）——
    // 本步声明禁止云端时不得切云，快速失败（切云即违反声明 = 数据出境）。
    if (profileExcluded && probes.requirement.localOnly) {
      throw LocalOnlyViolationException(
        '本轮请求无法完成：端侧当前状态：准入画像双坏（全后端 EXCLUDED/ERROR）',
        stage: DeviceRouteStage.admissionProfile,
      );
    }
    // —— 分派（冷装载状态机 → 端腿 / 云腿）——
    if (canDevice && probes.wantDevice && !profileExcluded) {
      // 冷装载状态机（场景 A/B/C，独立件）：Deferred = 本轮显式收口不切云
      // （场景 B 暂存通告 / q-1 终态装载失败）；CloudFallback = 场景 C 可自愈
      // 类降级云端（产出优先）。
      final load = await coordinateDeviceLoad(
        cap: _enableCapable,
        foreground: probes.foreground,
        request: request,
        cloudForbidden: _cloudForbidden(request),
        hasCloud: cloud != null,
      );
      if (load is DeviceLoadDeferred) throw load.exception;
      if (load is DeviceLoadCloudFallback) {
        yield* _cloudLeg.send(cloud!, request,
            allowDeviceFallback: false, onActivity: onActivity);
        return;
      }
      yield* _deviceLeg.send(
        request,
        reason: probes.offline
            ? '物理断网'
            : (preferOnDevice ? '用户偏好优先端侧' : '云端降级冷却期'),
        prompt: probes.preparedPrompt,
      );
      return;
    }
    final c = cloud;
    if (c == null) {
      if (canDevice) {
        yield* _deviceLeg.send(request,
            reason: '云端未配置', prompt: probes.preparedPrompt);
        return;
      }
      throw InferenceException(
          '无可用推理引擎：云端未配置且端侧不可用${deviceSkipReason == null ? '' : '（$deviceSkipReason）'}');
    }
    yield* _cloudLeg.send(
      c,
      request,
      // 画像双坏 → 端侧兜底一并关闸（查表即决策，§6；禁降级链再撞坏后端）。
      allowDeviceFallback: canDevice && !profileExcluded,
      onActivity: onActivity,
    );
  }
}
