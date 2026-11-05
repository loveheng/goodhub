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
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/errors/cloud_llm_error.dart';
import '../core/errors/inference_error.dart';
import '../core/tokens.dart' show estimateTokens;
import '../llm/cloud/cloud_llm.dart';
import '../llm/cloud/byok_store.dart';
import '../llm/llm.dart';
import '../llm/on_device_admission_probe.dart';
import '../llm/on_device_asset_manager.dart';
import '../llm/on_device_dispatch_profile.dart';
import '../llm/on_device_engine_binding.dart';
import '../llm/on_device_engine.dart';
import '../llm/on_device_model_catalog.dart';
import '../llm/on_device_pending_load.dart';
import '../llm/on_device_chat_prompt.dart';
import '../llm/on_device_history_policy_store.dart';
import 'capability_router.dart';
import 'degradation_controller.dart';

// P1-5 预检判据纯函数已迁 `capability_router.dart` 单源（S14c，禁双式
// 漂移）；此处 re-export 保持既有 import 面与测试钉兼容。
export 'capability_router.dart' show onDeviceInputOverflows;

/// 端侧 prompt 构造结果：实际送达 :engine 的载荷 + 裁剪后内容字符数 +
/// 选中模型（窗口值/采样参数同源），供窗口准入与超窗预检共用。
typedef _DevicePrompt = ({
  String promptJson,
  int contentChars,
  OnDeviceModelOption? selected,
});

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

  /// 断网探测（无探测位 = 视作在线）。
  ///
  /// 探测异常按**在线**处理的方向取舍（P2-1 评估后保留）：失败朝向「更丰富的
  /// 路径」——继续尝试云端，云端自有判据（超时/5xx/连接失败）兜底，且其失败
  /// 已经过 P0-2 错误行动卡对用户可见；反向（按离线切端侧）会让用户在云端
  /// 其实可用时静默失去云端能力，同样不可解释。
  Future<bool> _isOffline() async {
    final probe = isOfflineProbe;
    if (probe == null) return false;
    try {
      return await probe();
    } catch (e) {
      // DEGRADE: 探测失败视作在线——方向=朝向更丰富路径，其失败可见（P0-2）。
      debugPrint('[DEGRADE] hybrid-offline-probe: $e');
      return false;
    }
  }

  /// 排除位守卫（S14e，K10）：本步声明 `localOnly`（禁止云端）时，**任何
  /// 把请求内容送往云端的路径都必须关闸**——端侧运行时失败（引擎死亡 /
  /// 输入超窗 / 装载失败）的原语义是「切云保产出」，但切云即违反声明
  /// （该步数据出境）。
  ///
  /// 红线：排除位只在路由落空处拦、运行时留漏口 = 声明形同虚设——两处口径
  /// 必须一致。判定单一入口 = 本函数（禁各处散判 `requirement?.localOnly`）。
  bool _cloudForbidden(CloudChatRequest request) =>
      request.requirement?.localOnly == true;

  /// 前台态判定（场景 A/B/C 用）：探针缺省或异常 → 视为后台（保守：宁暂存
  /// 等前台，不误切云外发数据）。
  Future<bool> _isForeground() async {
    final probe = isForegroundProbe;
    if (probe == null) return false;
    try {
      return await probe();
    } catch (e) {
      debugPrint('[DEGRADE] hybrid-foreground-probe: $e');
      return false;
    }
  }

  /// 设备门禁查询（advisory；无门禁位 = 无提示）。
  ///
  /// **2026-10-31 用户裁决：门禁层降级 advisory**——判定结果只留痕提示，
  /// 不参与路由拦截（真保护 = 运行时护栏链，见 send() 内注释）。探测异常
  /// 重探一次仍失败按 unknown 如实留痕；「紧急强行启用」随拦截语义退役。
  Future<({bool pass, String reason, bool unknown})> _deviceGate() async {
    final gate = deviceTierGate;
    if (gate == null) return (pass: true, reason: '无门禁位', unknown: false);
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final r = await gate();
        return (pass: r.pass, reason: r.reason, unknown: false);
      } catch (e) {
        lastError = e;
        debugPrint('[DEGRADE] hybrid-device-gate (attempt $attempt): $e');
      }
    }
    return (
      pass: false,
      reason: '门禁探测异常（重试后仍失败：$lastError），端侧状态未知',
      unknown: true,
    );
  }

  /// 选中模型单一读取口（注入优先，缺省落盘选择）。
  Future<OnDeviceModelOption?> _readSelectedModel() =>
      onDeviceModelResolver?.call() ?? OnDeviceModelSelection.read();

  /// 构造端侧实际载荷并给出裁剪后内容字符数。
  ///
  /// 窗口准入（S14c `inputEstimateTokens`）与 P1-5 超窗预检**必须复用本结果**：
  /// 宿主聊天的 system 指令 + 工具面 + 历史动辄数千字符，而端侧默认策略
  /// ⓪ 真裸只把最新 user 轮送进 :engine。按裁剪前的原始消息全量估算，
  /// 1280 窗口的 1B bundle 每轮都会算出 >704 字符而误判超窗（真机：选中
  /// 1B 即报「输入超出端侧模型上下文窗口且未配置云端兜底」）。
  ///
  /// `contentChars` = JSON 解码后各 content 长度之和（[estimateTokens] 字符级
  /// 上界口径），不含 +64 脚手架开销——判据侧由 `onDeviceInputOverflows`
  /// 统一补齐，禁在此重复计入。
  Future<_DevicePrompt> _devicePrompt(
    CloudChatRequest request, {
    OnDeviceModelOption? selected,
  }) async {
    final model = selected ?? await _readSelectedModel();
    final deviceKey = model?.dirName ?? 'device-default';
    final devicePolicyId = await HistoryPolicySelection.readForModel(
        deviceKey, device: true);
    final promptJson = await buildOnDeviceChatPromptJsonAsync(
      request.messages,
      contextTokens: model?.contextTokens,
      historyPolicy: HistoryPolicySelection.resolve(devicePolicyId),
    );
    var contentChars = 0;
    for (final m
        in (jsonDecode(promptJson) as List).cast<Map<String, dynamic>>()) {
      contentChars += estimateTokens(m['content'] as String? ?? '');
    }
    return (
      promptJson: promptJson,
      contentChars: contentChars,
      selected: model,
    );
  }

  @override
  String get name => cloud == null
      ? '混合引擎（仅端侧）· ${onDevice?.name ?? '无'}'
      : '混合引擎 · ${cloud!.name}';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) async* {
    final offline = await _isOffline();
    final gate = await _deviceGate();
    // 门禁改 advisory（2026-10-31 用户裁决）：RAM/电量/温控判定只留痕提示，
    // 不拦路——真保护 = 运行时护栏链（:engine 隔离 + EngineDied 切云 + 熔断 +
    // 内存护栏驱逐 + MemGate 起跑闸 + :engine 温控连续确认沿）。误判史多次
    // 实证拦截成本高于收益，「紧急强行启用」随拦截语义一并退役。
    if (!gate.pass) {
      debugPrint('[HybridEngine] [advisory] 门禁不达标（不拦截）：${gate.reason}');
    }
    // S14 判据改造（task-capability W2，设计稿 §5.1）：从「有没有工具」的
    // 间接推断改为读能力需求声明——未显式声明时按请求形状推导（等价旧
    // toolFaceOk 判据，零行为变化），显式 requirement 优先。落空分类红线：
    // declarationSide=true = 声明自身可满足性（编排问题）；false = 端侧当前
    // 状态（资源问题）——两类落空的文案与降级路径不得混淆。
    final requirement = request.requirement ??
        deriveChatRequirement(request.tools, deviceToolPolicy);
    final deviceCold =
        _enableCapable?.loadState.value != OnDeviceLoadState.ready;
    // S14b 主体属性：前台探针上移（场景 C 复用同一探测值）——探针缺省/异常
    // 按后台保守处理（既有口径）；外部 App 调用面（externalApp）待 W5 供给
    // 面导出接线，聊天路径主体恒为宿主前台交互 / 宿主后台任务二值。
    final wantDevice = offline || !controller.shouldUseCloud || preferOnDevice;
    final canDeviceCandidate = onDevice != null;
    final foreground = canDeviceCandidate && wantDevice
        ? await _isForeground()
        : false;
    final subject = foreground
        ? CallerSubject.hostForeground
        : CallerSubject.hostBackground;
    // S14c 窗口值源：选中模型查表上移单次读取（窗口段 / 画像段 / 驻留取证
    // 三处复用，不新增第二套读取）。窗口 = modelProfile.contextTokens（
    // model-specs.json per-bundle 声明；未标注族 = null 未知不拦）。
    final selectedModel = canDeviceCandidate && wantDevice
        ? await _readSelectedModel()
        : null;
    // S14c 输入估算（2026-11-04 真机回归修正）：按**实际送达 :engine 的裁剪
    // 后载荷**估算，禁按原始请求全量逐 message 求和——端侧默认 ⓪ 真裸只留
    // 最新 user 轮，把原始 system/历史计入会把 1280 窗口的 1B bundle 每轮误判
    // 超窗。构造结果同时交 _deviceSend 复用（禁二次构造 / 禁两套估法）。
    _DevicePrompt? preparedPrompt;
    int? inputEstimateTokens;
    if (selectedModel != null) {
      preparedPrompt = await _devicePrompt(request, selected: selectedModel);
      inputEstimateTokens = preparedPrompt.contentChars;
    }
    // S14b 驻留资产匹配度取证（K19）：仅端侧已就绪时查票据——冷态下无驻留
    // 可言，换驻留禁令不适用（交互级冷态走时效段 D3 档）。票据 modelId 与
    // 装载入参同源（modelIdOf = dirName@digest），前缀比对目标 dirName；
    // 票据不可达（3s 超时）= 未知不判，交装载链路对账。
    bool? residentMatched;
    if (onDevice != null && !deviceCold && selectedModel != null) {
      try {
        final ticket = await OnDeviceEngineBinding().fetchSessionTicket();
        final resident = ticket?.modelId ?? '';
        if (resident.isNotEmpty) {
          final dir = selectedModel.dirName;
          residentMatched = resident == dir || resident.startsWith('$dir@');
        }
      } catch (e) {
        debugPrint('[DEGRADE] hybrid resident-match probe: $e');
      }
    }
    // S14d 动态准入取证：availMem（探针异常 = null 不判，禁把探针故障读成
    // 内存紧张）与调用方配额结论（无配额面不判——聊天路径 owner/后台任务
    // 无按身份配额，外部 App 通道 W5 注入 SamplingQuota 形态判定）。
    int? availMemBytes;
    if (onDevice != null && availMemProbe != null) {
      try {
        availMemBytes = await availMemProbe!();
      } catch (e) {
        debugPrint('[DEGRADE] hybrid availMem probe: $e');
      }
    }
    final quotaExceeded =
        onDevice != null && (quotaChecker?.call() ?? false);
    final verdict = evaluateDeviceRoute(
      requirement: requirement,
      deviceMounted: onDevice != null,
      deviceCold: deviceCold,
      // 窗口段值源已接（S14c）：windowTokens/输入估算双未知不拦；画像段
      // 保持下方既有查表门禁（零行为变化）。
      windowTokens: selectedModel?.contextTokens,
      profileExcluded: false,
      offline: offline,
      subject: subject,
      residentMatched: residentMatched,
      inputEstimateTokens: inputEstimateTokens,
      outputReserve: request.maxTokens ?? 512,
      availMemBytes: availMemBytes,
      quotaExceeded: quotaExceeded,
    );
    // 理由码随判定落库（D3 残余，S14b）：[ROUTE] 结构化行 = 路由判定的
    // 可观测载体（logcat 可 grep），理由码/段位/主体/驻留匹配全量在行。
    debugPrint('[ROUTE] ${verdict.deviceAllowed ? 'ALLOW' : 'BLOCK'}'
        ' stage=${verdict.blockedAt?.name ?? '-'}'
        ' declSide=${verdict.declarationSide}'
        ' governance=${verdict.governanceViolation}'
        ' localOnly=${verdict.localOnlyViolation}'
        ' exclude=${requirement.localOnly}'
        ' subject=${subject.name}'
        ' residentMatched=${residentMatched?.toString() ?? 'unknown'}'
        ' cold=$deviceCold offline=$offline'
        ' availMem=${availMemBytes?.toString() ?? 'unknown'}'
        '${verdict.reason.isEmpty ? '' : ' reason=${verdict.reason}'}');
    // 排除位违规（S14e，K10）：声明 `localOnly`（禁止云端）时，**凡处置本应是
    // 「分流云端」的落空**一律快速失败不切云（切云即违反声明 = 该步数据出境）。
    // 覆盖两类落空：声明不可满足（localOnly + 端侧承载缺位）与端侧当前状态不可用
    // （窗口/时效/就绪/画像/内存地板）。落空段位只影响归因，处置同口径。
    // 治理违规（配额超限）另走 [QuotaExceededException]（K9 两端口径，不叠加）。
    if (verdict.localOnlyViolation) {
      throw LocalOnlyViolationException(
        '本轮请求无法完成：${verdict.reason}',
        stage: verdict.blockedAt,
      );
    }
    // 治理违规（S14d，K9：配额超限）= 快速失败**不切云**——类型化异常，
    // 与资源故障类落空（分流云端保产出）分属两端口径。
    if (verdict.governanceViolation) {
      throw QuotaExceededException(subject.name);
    }
    var canDevice = verdict.deviceAllowed && onDevice != null;
    // D3：离线 + 交互级 + 冷态 = 装载等待（OFFLINE_COLD_LOAD_WAIT）——云端
    // 不可达时分流必失败，不拦，交既有就绪段装载分支（场景 B/C）；装载等待
    // 的取消语义（放弃本轮等待）随 S14b/D3 残余项落地。
    if (!verdict.deviceAllowed &&
        verdict.blockedAt == DeviceRouteStage.latency &&
        offline) {
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
    if (canDevice && wantDevice) {
      try {
        // selectedModel 已在窗口值源处单次读取（S14c 上移），此处复用。
        final profile = selectedModel == null
            ? null
            : await OnDeviceAssetManager.instance
                .readDispatchProfile(selectedModel);
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
    if (profileExcluded && requirement.localOnly) {
      throw LocalOnlyViolationException(
        '本轮请求无法完成：端侧当前状态：准入画像双坏（全后端 EXCLUDED/ERROR）',
        stage: DeviceRouteStage.admissionProfile,
      );
    }
    if (canDevice && wantDevice && !profileExcluded) {
      // 懒加载兜底（用户定调）：首次命中端侧路径才显式加载——bind→就绪→资产→
      // loadModel→数据面 worker，加载过程对用户可见（loadState=loading）。加载
      // 失败显式报错、不走云端（q-1：显式失败不切云）。
      final cap = _enableCapable;
      if (cap != null && cap.loadState.value != OnDeviceLoadState.ready) {
        // 场景 A/B/C 切云语义拆分（2026-10-30 用户裁决）：
        //  A 已加载但运行期夭折 → EngineDiedException 静默无缝切云（见
        //    [_deviceSend] 的引擎死亡分支，本分支不涉及）；
        //  B 未加载冷启动 + **后台**触发 → **不切云、不报错**，打
        //    PendingForegroundLoad 标记（TTL 30min）暂存退出，等下次前台；
        //  C 未加载冷启动 + **前台**用户发起 → 加载态 + 90s 超时保护 →
        //    终态失败显式报错；可自愈类（进程被杀/热降级）按需降级云端。
        //    foreground 探测已上移至主体推导处（S14b），此处复用同一值。
        if (!foreground) {
          await OnDevicePendingLoad.mark();
          debugPrint('[HybridEngine] 场景B：后台冷装载 → 暂存等前台（不切云）');
          throw const InferenceException(
              '端侧模型将在你回到前台时自动加载（后台加载已暂存）');
        }
        try {
          // D3 残余取消语义（S14b 钉死，裁决 = memory D3）：调用方在装载
          // 等待期取消本轮 = **放弃本轮等待**，绝不中止装载——单进程单装载
          // 纪律下中止装载即进程自杀重启。机制依据：enable() 的 Future 不
          // 随流退订取消（async* 生成器 await 检查点语义），且无任何取消
          // 路径调 disable()——装载在后台继续完成，下一轮命中即秒级复用；
          // 本轮在 await 返回前已死（无产出投递）= 等待已放弃。已知边界：
          // 放弃的即时性受 Dart await 检查点限制（不能中断 enable 本身，
          // 禁中止装载优先于即时退出），退订信号先于装载完成到达时本轮在
          // 装载完成后立即静默退出。理由码落痕 = 上方 [ROUTE] 行。
          await cap.enable();
        } on OnDeviceLoadException catch (e) {
          // 终态失败（资产缺失 / 设备不支持 / 内存不足）→ q-1 显式报错**不**
          // 切云；可自愈类（`retryable` = 进程/通道中断、热降级 `degraded`）
          // → 切云完成本轮（产出优先 + §5.2 Thermal→Cloud）。
          //
          // 中断类也切云的依据（真机实证 2026-10-30）：`:engine` 被 LMK 连杀
          // 时，等待端侧自愈 = 用户干等 2 分钟以上（退避 3.5/8/12/30/60s 累计），
          // 本轮必须由云端兜底，否则「2 分钟没有首 token」。
          final recoverable = e.degraded || e.retryable;
          if (!recoverable) {
            throw InferenceException('端侧加载失败：${e.reason}');
          }
          // 排除位守卫（S14e）：可自愈类原语义 = 切云完成本轮（产出优先）；
          // 本步声明禁止云端 → 显式失败不切云（数据不出境）。
          if (_cloudForbidden(request)) {
            throw InferenceException(
                '端侧加载失败：${e.reason}（本步声明禁止云端，不切云）');
          }
          final c = cloud;
          if (c == null) {
            throw InferenceException('端侧加载失败：${e.reason}（可稍后重试）');
          }
          debugPrint('[HybridEngine] 场景C：端侧暂不可用（${e.reason}）→ 降级云端完成本轮');
          yield* _cloudSend(c, request,
              allowDeviceFallback: false, onActivity: onActivity);
          return;
        }
      }
      yield* _deviceSend(
        request,
        reason: offline
            ? '物理断网'
            : (preferOnDevice ? '用户偏好优先端侧' : '云端降级冷却期'),
        prompt: preparedPrompt,
      );
      return;
    }
    final c = cloud;
    if (c == null) {
      if (canDevice) {
        yield* _deviceSend(request,
            reason: '云端未配置', prompt: preparedPrompt);
        return;
      }
      throw InferenceException(
          '无可用推理引擎：云端未配置且端侧不可用${deviceSkipReason == null ? '' : '（$deviceSkipReason）'}');
    }
    yield* _cloudSend(
      c,
      request,
      // 画像双坏 → 端侧兜底一并关闸（查表即决策，§6；禁降级链再撞坏后端）。
      allowDeviceFallback: canDevice && !profileExcluded,
      onActivity: onActivity,
    );
  }

  /// 当前生效云端模型的策略偏好 id：生效 profile（用户显式选择）> 列表首位；
  /// 无任何 profile 返 null（云端无模型 → 无策略面）。读取失败按 null 收口
  /// （DEGRADE 留痕，不阻断云发送）。
  Future<String?> _cloudModelPolicyId() async {
    try {
      final store = ByokStore();
      final preferred = await store.preferredProfileId();
      if (preferred != null) {
        return await HistoryPolicySelection.readForModel(preferred);
      }
      final profiles = await store.load();
      if (profiles.isEmpty) return null;
      return await HistoryPolicySelection.readForModel(profiles.first.id);
    } on Object catch (e) {
      debugPrint('[DEGRADE] hybrid: 云端历史策略偏好读取失败: $e');
      return null;
    }
  }

  Stream<CloudStreamEvent> _cloudSend(
    CloudLlmEngine c,
    CloudChatRequest request, {
    required bool allowDeviceFallback,
    void Function()? onActivity,
  }) async* {
    // 历史策略接线（2026-11-02）：策略挂模型本身（用户拍板）——按生效
    // BYOK profile id 取偏好，非默认 ① 时裁剪消息后再发（默认档整体跳过 =
    // 存量零变化；工具链路内部豁免不裁剪）。
    final cloudPolicyId = await _cloudModelPolicyId();
    var effective = request;
    if (cloudPolicyId != null &&
        cloudPolicyId != HistoryPolicyIds.dropOldest) {
      final trimmed = await applyHistoryPolicyToCloudMessages(
        request.messages,
        HistoryPolicySelection.resolve(cloudPolicyId),
        HistoryPolicySelection.kCloudHistoryCharBudget,
      );
      if (!identical(trimmed, request.messages)) {
        effective = CloudChatRequest(
          messages: trimmed,
          tools: request.tools,
          temperature: request.temperature,
          maxTokens: request.maxTokens,
          requirement: request.requirement,
        );
      }
    }
    try {
      // 流内间隙判定改造（「用其他方式判断」而非固定 30s 死计时）：
      // 旧逻辑以「两事件间静默 > interEventGapTimeout(30s)」判卡流——思考期
      // 模型不产 token 即被误杀（带工具请求无端侧兜底 → 直接 rethrow 中断任务）。
      // 新逻辑改为「传输层字节活体 + 自适应预算（无上限）」：
      //  - onActivity：底层每收到一帧字节（含 SSE 心跳注释帧）即证明连接活着，
      //    重置看门狗；心跳帧只作存活证据、不作工作推进（D2 正交语义不变）。
      //  - 预算自适应：首字节前用 firstTokenTimeout 快速判死连接；已有产出后随
      //    请求已耗时放宽（interEventGapTimeout 为下限、**无上限**，[maxThinkingGap]
      //    已移除），长思考不再被固定 30s 掐断；活体连接永不误杀，仅真死连接（持续
      //    无字节）被兜底下限捕获，其余交给人工「中止」（状态带显示已耗时）。
      final sw = Stopwatch()..start();
      var sawActivity = false;
      var sawOutput = false;
      final ctrl = StreamController<CloudStreamEvent>();
      Timer? watchdog;
      late final StreamSubscription<CloudStreamEvent> srcSub;
      Duration computeBudget() {
        if (!sawActivity) return controller.firstTokenTimeout;
        // 已有活体信号：预算随请求已耗时放宽（0.5×），下限 interEventGapTimeout、
        // **无上限**——活体连接（含 SSE 心跳）永不掐断，长思考不误杀；仅真死连接
        // （持续无字节）被兜底下限捕获，其余交给人工「中止」（状态带显示已耗时）。
        final grown = Duration(
          milliseconds: (sw.elapsed.inMilliseconds * 0.5).round(),
        );
        final floor = controller.interEventGapTimeout;
        return grown <= floor ? floor : grown;
      }

      void fireTimeout() {
        if (ctrl.isClosed) return;
        ctrl.addError(TimeoutException(
          '云端流内间隙超时（首 token ${controller.firstTokenTimeout.inSeconds}s / '
          '自适应下限 ${controller.interEventGapTimeout.inSeconds}s，随请求已耗时放宽、'
          '无上限；心跳帧存活即不触发，仅真死连接触发）',
        ));
        ctrl.close();
        srcSub.cancel();
      }

      void armWatchdog() {
        watchdog?.cancel();
        watchdog = Timer(computeBudget(), fireTimeout);
      }

      void noteActivity() {
        sawActivity = true;
        if (!ctrl.isClosed) armWatchdog();
      }

      srcSub = c.send(effective, onActivity: noteActivity).listen(
        (e) {
          noteActivity();
          if (e is CloudTextDelta || e is CloudToolCallDelta) sawOutput = true;
          if (!ctrl.isClosed) ctrl.add(e);
        },
        onError: (Object err, StackTrace st) {
          watchdog?.cancel();
          if (!ctrl.isClosed) {
            ctrl.addError(err, st);
            ctrl.close();
          }
        },
        onDone: () {
          watchdog?.cancel();
          if (!ctrl.isClosed) ctrl.close();
        },
        cancelOnError: false,
      );
      // 首字节前的死连接快速判据（firstTokenTimeout）。
      armWatchdog();
      try {
        await for (final e in ctrl.stream) {
          yield e;
        }
        controller.reportSuccess();
        // T7 实测新增：流式契约干净完成但零可见产出——推理型模型把 max_tokens
        // 烧在思维链（reasoning_content 不产可见 delta）时出现。产出优先语义下
        // 走端侧兜底；无兜底（带工具）显式暴露，禁静默空产出。
        if (!sawOutput) {
          if (allowDeviceFallback) {
            yield* _deviceSend(request, reason: '云端空产出（流完成但零可见内容）');
          } else {
            throw const InferenceException('云端空产出（流完成但零可见内容/工具调用）');
          }
        }
      } finally {
        watchdog?.cancel();
        await srcSub.cancel();
      }
    } on TimeoutException {
      controller.reportTransportTimeout();
      if (allowDeviceFallback) {
        yield* _deviceSend(request, reason: '云端首 Token 超时');
      } else {
        rethrow;
      }
    } on CloudHttpException catch (e) {
      // 仅 5xx/429 计入降级判据；401/403 等客户端侧错误不降级（换端侧也治不了坏 Key），
      // 但当次请求仍端侧兜底（产出优先）
      controller.reportServerError(e.statusCode ?? 0);
      if (allowDeviceFallback) {
        yield* _deviceSend(request, reason: '云端 HTTP ${e.statusCode ?? '流内错误'}');
      } else {
        rethrow;
      }
    } on CloudNetworkException {
      controller.reportTransportTimeout();
      if (allowDeviceFallback) {
        yield* _deviceSend(request, reason: '云端连接失败/超时');
      } else {
        rethrow;
      }
    } on Exception catch (e) {
      // 语义排除：空产出（流干净完成但零可见内容）与协议违规是**设计上直露**
      // 的结论性失败（UI 各有白话文案），不是传输中断——原样上抛，不进兜底。
      if (e is InferenceException || e is CloudProtocolException) rethrow;
      // 兜底（2026-10-21 真机实测教训，SiliconFlow「Connection closed while
      // receiving data」）：流内异常若不在上述三类之列（传输层未映射的裸
      // ClientException / FormatException / 其他 Exception），旧行为直接穿透
      // 到 UI 错误卡炸整轮会话。按传输中断语义收口：计入降级判据 + 当次
      // 端侧兜底（产出优先）；无兜底（带工具请求）包装为 CloudNetworkException
      // 上抛——UI 白话卡据此给「连不上推理服务」而非裸异常文案，原始异常
      // 信息内嵌保留（错误卡 detail 可复制）。禁静默吞：失败对调用方可见。
      controller.reportTransportTimeout();
      if (allowDeviceFallback) {
        yield* _deviceSend(request, reason: '云端流异常中断: $e');
      } else {
        throw CloudNetworkException('云端流异常中断: $e');
      }
    }
  }

  /// 端侧单发路径：多轮消息压平为单发提取 prompt（§2 端侧职责内的活）。
  ///
  /// 用 StreamController 承载而非裸 async*：async* 的 await 挂起点接不到订阅取消
  /// （Dart Future 不可取消），端侧原生生成会跑到底白烧 CPU/电池；控制器 onCancel
  /// 在取消瞬间同步触发 [OnDeviceLlmEngine.cancelActive]（§10 Abort 级联①步的
  /// 端侧路径）。生成结果为空仍抛 [InferenceException]（经 addError 走流错误，
  /// 与原 async* 语义一致）。
  Stream<CloudStreamEvent> _deviceSend(
    CloudChatRequest request, {
    required String reason,
    _DevicePrompt? prompt,
  }) {
    final device = onDevice!;
    // 已完成标志：stream 正常 done 后 yield* 也会退订（触发 onCancel），
    // 不能把「完成后的正常退订」误判为「取消」——只在未完成时才联动 cancelActive。
    var completed = false;
    late StreamController<CloudStreamEvent> ctrl;
    ctrl = StreamController<CloudStreamEvent>(
      onCancel: () => completed ? Future<void>.value() : device.cancelActive(),
    );
    Future<void>(() async {
      debugPrint('[HybridEngine] 端侧路径（$reason）：${device.name}');
      try {
        // 端侧对话 prompt 构造与载荷估算（_devicePrompt 单源）：消息序列 JSON
        // 由 :engine 侧 ChatML 模板承载角色；历史预算按选中模型窗口动态推导，
        // 策略挂模型本身（默认 ⓪ 真裸 = 仅最新 user 轮）。主入口已构造时复用，
        // 云端兜底等旁路自行构造——两处口径恒等，禁二次估法。
        final prepared = prompt ?? await _devicePrompt(request);
        final promptJson = prepared.promptJson;
        final selected = prepared.selected;
        debugPrint('[HybridEngine] 端侧对话 prompt：promptJsonChars=${promptJson.length}'
            ' contentChars=${prepared.contentChars}');
        // P1-5 输入零预算预检（机制审计，设计定稿 2026-11-01）：**拒绝优先**——
        // 预检超窗显式报错切云（产出优先），设备路径禁第二套截断（阶梯截断 =
        // 上下文治理唯一机制，归 stepped-pruning draft）。预算来源 = 资产面
        // 声明 contextTokens（modelProfile 单源）；未标注（GenieX 系）跳过
        // 预检——其历史字符预算机制（kOnDeviceHistoryCharBudget）在场兜底，
        // 硬编码默认窗口会误拒正常多轮对话。
        // [Fact] 超窗 SDK 行为实证（Qwen 真机轮 2026-11-04，Ace 6）：GenieX
        // llama_cpp 系超窗 = SDK 抛「Input prompt too long」RuntimeException
        // **硬失败**，:engine 捕获转 [DEGRADE]，Dart 侧表现为空产出干净闭合
        // （bytesIn=0/chunks=1，非尾部截断、非进程崩溃）——预检缺席时生产侧
        // 空产出显式报错路径兜底（2026-10-30 已收口），用户可见不静默。
        // GenieX 系无预检沿用现状成立。
        // 判据 = 裁剪后实际载荷（+64 JSON 脚手架）+ 输出预留；按裁剪前原始
        // 消息算会把长 system/历史误当 payload，1280 窗口 1B bundle 每轮误拒
        //（2026-11-04 真机回归）。单轮超 builder 预算仍是唯一真溢出源。
        final ctxTokens = selected?.contextTokens;
        if (ctxTokens != null) {
          final outputReserve = request.maxTokens ?? 512;
          if (onDeviceInputOverflows(
            contentChars: prepared.contentChars,
            outputReserve: outputReserve,
            windowTokens: ctxTokens,
          )) {
            throw OnDeviceContextOverflowException(
                ctxTokens, prepared.contentChars + outputReserve + 64);
          }
        }
        // P1-6（2026-11-01）：流式契约——逐 delta 投递，消除「收满 512 token
        // 才一次投递」的 30s 无出字缺口。零产出（无事件 close）走下方归因。
        // S1 采样下发链（2026-11-03）：meta recommendedSampling 在场则请求级
        // 覆盖引擎内建默认（§3.5 单字段单源，null 字段不覆盖）。
        final sampling = selected?.recommendedSampling;
        var sawOutput = false;
        await for (final delta in device.generateStream(
          promptJson,
          maxTokens: request.maxTokens ?? 512,
          temperature: sampling?.temperature,
          topP: sampling?.topP,
        )) {
          sawOutput = true;
          ctrl.add(CloudTextDelta(delta));
        }
        if (!sawOutput) {
          // 零产出归因（2026-10-30 真机实证「同一对话第二次提问没有输出」）：
          // 端侧**运行时**失败 ≠ 装载失败——q-1 的「显式失败不切云」只约束
          // **装载**失败（用户据此知道「模型没装好」）；此处引擎活着却零产出，
          // 属运行时失败 → **显式上抛并带真因**（既有语义钉「端侧兜底失败 →
          // 上抛（禁静默吞）」不变），但**禁再报笼统「空产出」**：真因（会话
          // 重置失败 / 热降级 / 通道拒绝 / 模型未说话）必须透出，否则用户与
          // 排查者都无从定位「第二轮为什么没有输出」。
          final status = await device.unavailableReasonAsync();
          final aware = device is OnDeviceFailureReasonAware
              ? (device as OnDeviceFailureReasonAware).lastFailureReason
              : null;
          // 引擎就绪时 status 为 null（无失败态）——禁把 null 拼进用户文案
          //（真机实证「端侧生成失败（null）：空产出」不可读）。
          final reason = status ?? '端侧引擎就绪';
          final why = aware ?? status ?? '空产出（模型未产出任何内容）';
          // I6 归因防护（2026-11-05）：归因时引擎**非就绪**（已被驱逐/状态未知/
          // 通道异常）＝零产出不可信为模型缺陷——按会话死亡语义抛 EngineDied
          // （catch 分支无缝切云，产出优先），**禁记 zeroOutput**：否则一次性
          // 基础设施事件被持久化成坏后端记忆，下轮无故跳开端侧。
          if (status != null) {
            throw EngineDiedException(
                'session not ready at empty-output attribution ($status)');
          }
          // DispatchProfile 第二写入方（设计稿 §7）：运行时零产出 → 标观测
          // 后端 EXCLUDED，下轮查表直跳（#4 坏后端记忆并入画像）。
          // （走到此处引擎必就绪：模型真没说话，归因可信。）
          await recordRuntimeBackendExcluded(
              selected, BackendReason.zeroOutput);
          throw InferenceException('端侧生成失败（$reason）：$why');
        }
        ctrl.add(const CloudDone(finishReason: CloudFinishReason.stop));
      } catch (e) {
        if (e is OnDeviceContextOverflowException) {
          // P1-5 拒绝路径（设计 ②「拒绝优先」）：超窗 = 可自愈（换云端产出），
          // 非终态失败——显式报错并切云（产出优先）；不进运行时坏后端记账
          // （超窗是请求形状问题，非设备/后端缺陷）。
          debugPrint('[HybridEngine] 端侧输入超窗（~${e.estimateTokens}/'
              '${e.windowTokens} tokens）→ 拒绝并切云');
          final c = cloud;
          if (_cloudForbidden(request)) {
            // 排除位守卫（S14e）：拒绝优先 = 切云保产出；本步声明禁止云端
            // → 显式失败不切云（超窗数据不出境）。
            ctrl.addError(InferenceException(
                '输入超出端侧模型上下文窗口（约 ${e.windowTokens} tokens），'
                '且本步声明禁止云端（不切云）——请缩短当前输入后重试'));
          } else if (c == null) {
            ctrl.addError(InferenceException(
                '输入超出端侧模型上下文窗口（约 ${e.windowTokens} tokens）且未配置'
                '云端兜底——请缩短当前输入，或配置云端模型后自动切换'));
          } else {
            try {
              await for (final ev
                  in _cloudSend(c, request, allowDeviceFallback: false)) {
                ctrl.add(ev);
              }
            } catch (cloudError) {
              ctrl.addError(cloudError);
            }
          }
        } else if (e is EngineDiedException) {
          // DispatchProfile 第二写入方（设计稿 §7）：运行时崩溃/死亡 → 标
          // EXCLUDED，下轮查表直跳（同 #4 坏后端记忆并入画像）。
          // 归因过滤（2026-11-05，与 I6 收敛去歧义配套）：**在途被驱逐打断**
          //（SESSION_ABORTED_BY_EVICTION）、数据面 EOF（驱逐关闭数据面）与
          // **装载未完成类可重试分码**（session_loading 装载慢被打断 /
          // session_epoch_mismatch 票据过期 / session_model_mismatch 资产变更
          // ——均为可自愈中断，真机实证 14:38 装载 100s 超窗被打断被记成
          // GPU crash）不是后端缺陷——记 crash 会把正常生命周期/环境事件持久
          // 化成坏后端记忆，下轮无故跳开端侧。真进程死亡/看门狗/死锁类照记。
          final diedReason = e.reason.toLowerCase();
          final evictionLifecycle = diedReason.contains('session_aborted_by_eviction') ||
              diedReason.contains('data plane eof') ||
              diedReason.contains('session_loading') ||
              diedReason.contains('session_epoch_mismatch') ||
              diedReason.contains('session_model_mismatch');
          if (!evictionLifecycle) {
            await recordRuntimeBackendExcluded(
                await _readSelectedModel(), BackendReason.crash);
          }
          // on-device S1-5（总纲 §2）：`:engine` 进程死亡/驱动 Panic 无缝切云，
          // 绝不闪退主进程、绝不让用户会话炸错误卡。切云一次直达（端侧已死，
          // 云端再失败只能原样上抛）。同一 ctrl 承载——§10 取消联动（onCancel →
          // device.cancelActive）保持原直连链不变；无云可切时原样上抛。
          final c = cloud;
          if (_cloudForbidden(request)) {
            // 排除位守卫（S14e）：引擎死亡原语义 = 无缝切云（保产出）；本步
            // 声明禁止云端 → 显式失败不切云（数据不出境）。
            debugPrint('[HybridEngine] :engine 死亡且本步禁止云端 → 显式失败');
            ctrl.addError(InferenceException(
                '端侧已中断且本步声明禁止云端（不切云）——可稍后重试，或改用'
                '不禁止云端的步骤声明'));
          } else if (c == null) {
            // 云端缺席：EngineDiedException 是内部切云信号，非用户文案——
            // 裸抛会把 'EngineDiedException: ...' 直接上墙（2026-10-31 真机
            // 热闸事故第二症状）。翻译成白话：端侧已中断 + 无兜底的出路提示。
            debugPrint('[HybridEngine] :engine 中断（${e.reason}）但云端未配置 → 白话报错');
            ctrl.addError(InferenceException(
                '端侧已中断且未配置云端兜底（${engineInterruptReason(e)}）——可稍后重试，或配置云端模型后自动切换'));
          } else {
            debugPrint('[HybridEngine] :engine 死亡 → 无缝切云（$reason）');
            try {
              // 切云沿复用 [_cloudSend]（**非裸流**）：继承其自适应看门狗
              // （首 token 死连接判死 + 流内字节活体自适应预算）与空产出
              // 显式报错——裸 `c.send(request)` 无任何兜底，云端一挂即
              // 本轮永挂（真机「第二轮没有任何响应」的另一半成因）。
              await for (final ev
                  in _cloudSend(c, request, allowDeviceFallback: false)) {
                ctrl.add(ev);
              }
            } catch (cloudError) {
              ctrl.addError(cloudError);
            }
          }
        } else {
          ctrl.addError(e);
        }
      } finally {
        completed = true;
        await ctrl.close();
      }
    });
    return ctrl.stream;
  }
}

/// 端侧中断真因白话化（错误卡文案，禁裸露内部异常串）：按 reason 关键字
/// 归类。温控已摘除（2026-10-31 裁决），thermal 分支随之退役。
String engineInterruptReason(EngineDiedException e) {
  final r = e.reason.toLowerCase();
  // S14e（K11）：协作式打断未生效 = 等待窗口耗尽且在途生成可能仍在跑，
  // 算力仍被占——不得表述为「已腾出/已打断」。
  if (r.contains('interrupt_not_effective') ||
      r.contains('interrupt not effective')) {
    return '端侧算力正被占用，协作式打断未生效（算力尚未让出）';
  }
  if (r.contains('busy')) return '引擎正忙（上一轮尚未让出算力）';
  if (r.contains('session') || r.contains('loading')) return '端侧会话未就绪';
  return '引擎中断';
}

/// P1-5 端侧输入超窗拒绝（机制审计，设计定稿 2026-11-01）：预检超窗即抛，
/// 拒绝优先——设备路径禁第二套截断，拒绝沿切云保产出。携带窗口与估算值
/// 供日志/文案归因。
class OnDeviceContextOverflowException implements Exception {
  OnDeviceContextOverflowException(this.windowTokens, this.estimateTokens);

  final int windowTokens;
  final int estimateTokens;

  @override
  String toString() =>
      '端侧输入超窗: ~$estimateTokens tokens > window $windowTokens';
}
