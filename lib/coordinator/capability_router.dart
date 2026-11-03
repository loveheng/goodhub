/// 能力路由判定链（task-capability W2 · S14；设计 SSOT =
/// `docs/design/on-device-task-capability.md` §5.1）。
///
/// **定位**：路由治理层的纯判定函数——从「有没有工具」的间接推断改为读
/// [CapabilityRequirement] 显式声明。判定链六段，顺序固定：
/// **声明 → 窗口准入 → 时效 → 端侧就绪 → 准入画像 → 云端可达**。
///
/// **落空分类红线**：前两段（声明、窗口准入）属**声明自身可满足性**
/// （纯声明 + 资产规格，路由前即可判定 = 编排问题）；后几段属**端侧
/// 当前状态**（运行时资源问题）。两类落空的文案与降级路径不得混淆——
/// [DeviceRouteVerdict.declarationSide] 即该分类的机械承载。
///
/// **零行为变化纪律**：聊天路径无显式声明时经 [deriveChatRequirement]
/// 从请求形状推导（等价旧 `toolFaceOk` 判据），显式声明优先——存量
/// 请求路由行为不变，S14b/c/d/e 各维度再逐段接线细化。
///
/// **排除位（S14e，K10）**：声明 `localOnly`（禁止云端）时，**处置本应是
/// 「分流云端」的落空一律改判为排除位违规**（快速失败不切云——切云即违反
/// 声明 = 该步数据出境）。机械承载 = [DeviceRouteVerdict.localOnlyViolation]，
/// 出口 = [LocalOnlyViolationException]。
library;

import '../core/capability_requirement.dart';
import '../core/errors/inference_error.dart';
import '../llm/cloud/cloud_llm.dart';

/// 判定链段位（顺序即评估序；todos S14 六段口径）。
enum DeviceRouteStage {
  /// ① 声明：needsTools / needsStructuredOutput / localOnly 组合可满足性。
  declaration,

  /// ② 窗口准入：tokenBudget vs 资产窗口（静态准入段；S14c 接 tokens.dart）。
  windowAdmission,

  /// ③ 时效：latencyClass × 冷热态 × 网络可达（S14b 细化驻留匹配度）。
  latency,

  /// ④ 端侧就绪：引擎挂载态。
  readiness,

  /// ⑤ 准入画像：DispatchProfile 双坏排除。
  admissionProfile,

  /// ⑤' 内存地板：availMem 跌破绝对地板（S14d；资源故障类，分流云端）。
  memoryFloor,

  /// ⑥ 配额：按调用方身份超限（S14d；**治理违规类**，快速失败不切云）。
  quota,
}

/// 路由判定结论（纯值，可缓存/可测）。
class DeviceRouteVerdict {
  const DeviceRouteVerdict({
    required this.deviceAllowed,
    this.blockedAt,
    this.reason = '',
    this.declarationSide = false,
    this.governanceViolation = false,
    this.localOnlyViolation = false,
  });

  /// 端侧路径是否放行。
  final bool deviceAllowed;

  /// 落空段位（放行时 null——判定链全过）。
  final DeviceRouteStage? blockedAt;

  /// 落空原因（人可读，含理由码；逐级可区分）。
  final String reason;

  /// 落空分类：true = 声明自身可满足性侧（编排问题）；false = 端侧当前
  /// 状态侧（资源问题）。放行时 false 无语义。
  final bool declarationSide;

  /// 治理违规类落空（S14d，K9：配额超限）——处置与资源故障相反：
  /// **快速失败不切云**（切云 = 把调用方算力成本转嫁宿主云端账单与并发
  /// 容量，配额形同虚设）。资源故障类落空（本字段 false 的落空）才走
  /// 分流云端保产出。
  final bool governanceViolation;

  /// 排除位违规落空（S14e，K10：声明 `localOnly` 禁止云端）——处置与资源
  /// 故障相反：**快速失败不切云**（切云即违反声明 = 该步数据出境）。
  ///
  /// 与 [governanceViolation] 分属两端口径：治理违规 = 调用方超额（配额），
  /// 排除位违规 = 声明禁止出境。两者都快速失败，但归因与文案不同。
  ///
  /// 机械口径：**处置本应是「分流云端」的落空**，在本步声明带排除位时改判
  /// 为本字段为真。两处例外（处置本就不切云）：① 时效段离线冷态（处置 =
  /// 装载等待，云端不可达分流必失败）；② 配额段（治理违规另有类型化异常）。
  final bool localOnlyViolation;

  /// 全过。
  static const DeviceRouteVerdict allow =
      DeviceRouteVerdict(deviceAllowed: true);
}

/// availMem 绝对地板（S14d）：单源 = `engine/MemoryGuardEvaluator.kt`
/// `ABSOLUTE_FLOOR_BYTES`（1GB，跌破即系统进入低内存杀截区间）——本常量为
/// Dart 路由层同值镜像，**漂移须与 Kotlin 侧同步**（注释钉死双端键名）。
/// 红线：地板只作动态准入判定，**不入准入画像**（混入会污染后端健康判定）。
const int kAvailMemAbsoluteFloorBytes = 1024 * 1024 * 1024;

/// 配额超限治理异常（S14d，K9）：治理违规快速失败**不切云**——超限后自动
/// 走云端等于把调用方的算力成本转嫁宿主云端账单与并发容量，配额形同虚设。
class QuotaExceededException implements Exception {
  const QuotaExceededException(this.subject, [this.retryAfter]);

  /// 超限的调用主体标签。
  final String subject;

  /// 建议重试等待时长（null = 未提供）。
  final Duration? retryAfter;

  @override
  String toString() =>
      '端侧算力配额超限（主体：$subject）'
      '${retryAfter == null ? '' : '，建议 ${retryAfter!.inSeconds}s 后重试'}';
}

/// 排除位违规异常（S14e，K10）：声明 [CapabilityRequirement.localOnly] 禁止
/// 云端，路由落空时**快速失败不切云**——切云即违反声明（该步数据不得出境）。
///
/// 归口与 [QuotaExceededException]（治理违规：调用方超额）分属两端口径：本异常
/// = 声明禁止出境（数据流向约束），配额异常 = 调用方超出授权额度（用量约束）。
/// 两者都快速失败不切云，但归因与文案不同。
///
/// 继承 [InferenceException]：端侧/混合路由失败域的既有异常族（UI 错误卡按
/// 该族白话化），本异常只是带段位归因的子类——不改既有错误卡口径。
class LocalOnlyViolationException extends InferenceException {
  const LocalOnlyViolationException(super.message, {this.stage});

  /// 落空段位（归因用；null = 未判定）。
  final DeviceRouteStage? stage;

  @override
  String toString() =>
      'LocalOnlyViolationException: $message'
      '${stage == null ? '' : '（落空段位：${stage!.name}）'}';
}

/// 调用主体属性（S14b；红线：跨 App 场景以调用方 App 为准不以宿主为准）。
enum CallerSubject {
  /// 宿主前台交互：结果须即时可见，可触发换驻留（换装载走既有场景 C 链）。
  hostForeground,

  /// 宿主后台任务（如 task-consume 后台消费）：驻留不匹配时分流云端，
  /// **禁触发换驻留**（K19：换驻留 = 换装载 = 进程重建 + 秒级冷装载，
  /// 不得因后台任务打断前台活跃期）。
  hostBackground,

  /// 外部 App 调用（W5 供给面导出通道接线；以调用方 App 身份为准）。
  externalApp,
}

/// 理由码（D3 裁决口径；随判定落库为 S14b/D3 残余项）。
enum LatencyReasonCode {
  /// 在线 + 交互级 + 冷态 → 分流云端（最保守档）。
  coldLoadBypassedToCloud('COLD_LOAD_BYPASSED_TO_CLOUD'),

  /// 离线 + 交互级 + 冷态 → 装载等待（云端不可达，分流必失败）。
  offlineColdLoadWait('OFFLINE_COLD_LOAD_WAIT');

  const LatencyReasonCode(this.code);
  final String code;
}

/// 六段判定链纯函数。
///
/// 参数口径：
/// - [requirement]：能力需求声明（显式声明或推导结果）；
/// - [deviceMounted]：端侧引擎挂载态（onDevice != null）；
/// - [deviceCold]：端侧冷态（未加载/装载中 = loadState != ready）；
/// - [windowTokens]：当前资产窗口（null = 窗口未知——**窗口未知不拦**，
///   归因交 S14c 接线口径，本段只在双方已知时裁决，防未知窗口误杀端侧）；
/// - [profileExcluded]：准入画像双坏（DispatchProfile.routeTarget() == null）；
/// - [offline]：物理断网（云端不可达，决定落空处置可行性）；
/// - [subject]：调用主体属性（缺省宿主前台交互——存量调用零变化）；
/// - [residentMatched]：驻留资产匹配度（当前驻留 vs 目标资产同族同版本；
///   null = 未知不判——票据取证不可达时不拦，交装载链路对账）；
/// - [inputEstimateTokens]：输入 token 字符级上界估算（`estimateTokens`
///   逐 message 求和口径；null = 未知不判——双未知不拦延续 S14 前口径）；
/// - [outputReserve]：输出预留（缺省 512，与 `_deviceSend` 预检同口径）；
/// - [availMemBytes]：整机可用内存（bytes；null = 取证不可达不判——探针
///   缺席/异常不拦端侧，交运行时护栏链兜底）。≤ [kAvailMemAbsoluteFloorBytes]
///   → 内存地板落空（**资源故障类**，分流云端：云端不在本机执行，本机
///   内存紧张不影响云端产出，快速失败等于把唯一能产出的一侧判死）。
///   地板不入准入画像（红线）；
/// - [quotaExceeded]：调用方身份配额是否超限（判定链只留判定位，配额实例
///   由装配方持有——复用 `SamplingQuota` 滑窗形态，**不新建限流器**）。
///   超限 → 配额段落空（**治理违规类**，快速失败不切云，K9）。
DeviceRouteVerdict evaluateDeviceRoute({
  required CapabilityRequirement requirement,
  required bool deviceMounted,
  required bool deviceCold,
  int? windowTokens,
  required bool profileExcluded,
  required bool offline,
  CallerSubject subject = CallerSubject.hostForeground,
  bool? residentMatched,
  int? inputEstimateTokens,
  int outputReserve = 512,
  int? availMemBytes,
  bool quotaExceeded = false,
}) {
  // 落空构造器（S14e）：排除位口径统一收口一处——**处置本应是「分流云端」的
  // 落空**，若本步声明带 `localOnly` 排除位，则改判为排除位违规（快速失败
  // 不切云：切云即违反声明 = 该步数据出境）。
  //
  // 两处例外（处置本就不切云，排除位不改变处置）：
  // ① 时效段离线冷态（处置 = 装载等待；云端不可达，分流必失败）；
  // ② 配额段（治理违规，另由 [QuotaExceededException] 承接）。
  DeviceRouteVerdict blocked(
    DeviceRouteStage stage,
    String reason, {
    bool declarationSide = false,
    bool governance = false,
    bool cloudFallbackApplies = true,
  }) =>
      DeviceRouteVerdict(
        deviceAllowed: false,
        blockedAt: stage,
        reason: reason,
        declarationSide: declarationSide,
        governanceViolation: governance,
        localOnlyViolation:
            requirement.localOnly && cloudFallbackApplies && !governance,
      );

  // ① 声明段——声明自身可满足性。
  // 声明自相矛盾 = 禁云端 + 端侧承载缺位（端侧供给面单轮无工具 K20 /
  // 结构化承载未落地 K15），任何供给路径都无法满足 → 显式失败（不切云）。
  final deviceCannotServe = requirement.needsTools ||
      requirement.needsStructuredOutput;
  if (deviceCannotServe && requirement.localOnly) {
    return blocked(
      DeviceRouteStage.declaration,
      '声明不可满足：localOnly 禁止云端，'
          '${requirement.needsTools ? '声明需要工具（端侧单轮无工具）' : ''}'
          '${requirement.needsStructuredOutput ? '声明需结构化产出（端侧约束解码承载未就绪）' : ''}',
      declarationSide: true,
    );
  }
  // needsTools / 结构化 → 端侧不可服务（但云端可服务 → 分流云端，编排问题）。
  if (deviceCannotServe) {
    return blocked(
      DeviceRouteStage.declaration,
      requirement.needsTools
          ? '声明需要工具（端侧供给面单轮无工具）→ 云端编排'
          : '声明需结构化产出（端侧约束解码承载未就绪）',
      declarationSide: true,
    );
  }

  // ② 窗口准入段——静态准入（声明 × 资产规格，路由前可判定）。
  // 红线（S14c）：超窗拒绝并切云保产出，端侧不引入第二套截断。
  // ②-a 资产窗口维度：输入估算（tokens.dart 字符级上界口径）+ 输出预留
  // 超资产窗口 → 拒（与 [onDeviceInputOverflows] 同式——本函数即其迁移
  // 单源，hybrid 侧预检终检复用同一式，禁漂移）。双未知不判（S14c 前
  // 「窗口未知不拦」口径延续：窗口或估算任一缺席即放行，归因交账）。
  final budget = requirement.tokenBudget;
  if (windowTokens != null && inputEstimateTokens != null) {
    if (onDeviceInputOverflows(
      contentChars: inputEstimateTokens,
      outputReserve: outputReserve,
      windowTokens: windowTokens,
    )) {
      return blocked(
        DeviceRouteStage.windowAdmission,
        '窗口准入落空：输入估算(~$inputEstimateTokens)+输出预留'
            '($outputReserve)+64 超资产窗口($windowTokens)',
        declarationSide: true,
      );
    }
  }
  // ②-b 声明预算维度：本步 token 预算（输入+输出）被超 → 拒（声明自身
  // 可满足性侧）。窗口未知时由 budget 独立裁决（对照表缺席不豁免声明）。
  if (budget != null && inputEstimateTokens != null) {
    if (inputEstimateTokens + outputReserve > budget) {
      return blocked(
        DeviceRouteStage.windowAdmission,
        '窗口准入落空：输入估算(~$inputEstimateTokens)+输出预留'
            '($outputReserve) 超声明 tokenBudget($budget)',
        declarationSide: true,
      );
    }
  }

  // ③ 时效段——交互级遇冷态按 D3 最保守档。
  // 离线 + 冷态 → OFFLINE_COLD_LOAD_WAIT（装载等待；取消语义与理由码落库
  // 为 S14b/D3 残余项，本段先出判定不拦——交既有就绪段装载分支处理）。
  if (requirement.latencyClass == LatencyClass.interactive && deviceCold) {
    final code = offline
        ? LatencyReasonCode.offlineColdLoadWait
        : LatencyReasonCode.coldLoadBypassedToCloud;
    return blocked(
      DeviceRouteStage.latency,
      '时效落空：交互级遇端侧冷态 → ${code.code}',
      // 离线冷态处置 = 装载等待（云端不可达，分流必失败）——排除位不改变处置；
      // 在线冷态处置 = 分流云端 → 带排除位时改判快速失败不切云（S14e）。
      cloudFallbackApplies: !offline,
    );
  }

  // ④ 端侧就绪段。
  if (!deviceMounted) {
    return blocked(
      DeviceRouteStage.readiness,
      '端侧当前状态：引擎未挂载',
    );
  }

  // ④' 驻留资产匹配度（K19，S14b）：驻留不匹配 = 换驻留 = 换装载 = 进程
  // 重建 + 秒级冷装载。仅宿主前台交互可触发换驻留（走既有场景 C 装载链）；
  // 后台任务 / 外部 App 在前台活跃期禁触发换驻留 → 分流云端（云端不在本机
  // 执行，换驻留代价不影响云端产出）。residentMatched = null（票据取证
  // 不可达）不拦，交装载链路对账。
  if (residentMatched == false &&
      subject != CallerSubject.hostForeground) {
    return blocked(
      DeviceRouteStage.readiness,
      '端侧当前状态：驻留资产不匹配且主体为'
          '${subject == CallerSubject.hostBackground ? '宿主后台任务' : '外部 App'}'
          '（前台活跃期禁换驻留，K19）',
    );
  }

  // ⑤ 准入画像段（双坏查表即切云，不让 :engine 死一次确认坏后端）。
  if (profileExcluded) {
    return blocked(
      DeviceRouteStage.admissionProfile,
      '端侧当前状态：准入画像双坏（全后端 EXCLUDED/ERROR）',
    );
  }

  // ⑤' 内存地板段（S14d，资源故障类 → 分流云端保产出）：availMem 跌破
  // 绝对地板 = 系统已进低内存杀截区间。云端不在本机执行，本机内存紧张
  // 不影响云端产出——快速失败等于把唯一能产出的一侧判死。地板只作动态
  // 准入，不入准入画像（红线：混入会污染后端健康判定）。
  if (availMemBytes != null && availMemBytes <= kAvailMemAbsoluteFloorBytes) {
    return blocked(
      DeviceRouteStage.memoryFloor,
      '端侧当前状态：availMem(${availMemBytes ~/ (1024 * 1024)}MB) '
          '跌破绝对地板(${kAvailMemAbsoluteFloorBytes ~/ (1024 * 1024)}MB)',
    );
  }

  // ⑥ 配额段（S14d，治理违规类 → 快速失败不切云，K9）：配额超限 = 调用方
  // 超额使用宿主算力，切云等于把算力成本转嫁宿主云端账单与并发容量。
  // 与资源故障类落空分属两端口径，处置相反。
  if (quotaExceeded) {
    return blocked(
      DeviceRouteStage.quota,
      '治理违规：调用方(${subject.name})端侧算力配额超限 → 快速失败不切云',
      governance: true,
    );
  }

  // ⑥ 云端可达段：不拦端侧，只作落空处置的可行性输入（资源故障落空 +
  // 云端不可达 = 无可产出路径 → 显式失败）。结果随调用方 offline 自取。
  return DeviceRouteVerdict.allow;
}

/// P1-5 预检判据（纯函数，测试钉用；S14c 自 hybrid_cloud_engine 迁入单源）：
/// 内容字符数（ASCII 最坏 1 字 1 token 口径，与 prompt builder 预算同口径）
/// + 输出预留 + JSON 脚手架开销 64，超窗口 = 拒绝。
bool onDeviceInputOverflows({
  required int contentChars,
  required int outputReserve,
  required int windowTokens,
}) =>
    contentChars + outputReserve + 64 > windowTokens;

/// 聊天路径推导口径（无显式声明时的过渡等价映射，零行为变化）。
///
/// needsTools = 带工具 且 工具面非设备可放行——即旧 `toolFaceOk` 判据
/// （`tools.isEmpty || deviceToolPolicy(tools)`）取反编码进声明。其余
/// 维度取保守缺省。显式 [CapabilityRequirement] 优先，推导仅兜底。
CapabilityRequirement deriveChatRequirement(
  List<CloudToolSchema> tools,
  bool Function(List<CloudToolSchema> tools)? deviceToolPolicy,
) {
  final toolFaceDeviceOk =
      tools.isEmpty || (deviceToolPolicy?.call(tools) ?? false);
  return CapabilityRequirement(needsTools: !toolFaceDeviceOk);
}
