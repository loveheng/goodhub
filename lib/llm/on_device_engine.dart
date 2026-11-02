/// 端侧引擎公共契约（立法源 = docs/design/on-device-capability.md §2 v2.7）。
///
/// 本件承载跨进程契约的 Dart 侧镜像：`EngineStatus` 枚举序数与 AIDL
/// `checkStatus()`/`initEngine()` 返回的 int 一一对应（0..6），禁调序
///（仅允许在末尾追加新状态，见 [EngineStatus.thermalCutoff]）。
/// `OnDeviceEngine` 抽象接口与 `GenerationConfig` 随 S1-5 生成管线落地。
///
/// 调度纪律（§2 v2.6）：`busy` 与 `ready` 严禁任何 TTL 缓存，必须随查随废；
/// 业务分流决策绝不依赖 `checkStatus()` 的 `busy`——直接调 `generate()`，
/// 由 `:engine` 内部 Mutex 原子抢占，冲突抛 `ServiceBusyException` 切云。
library;

import 'package:flutter/foundation.dart';
import 'on_device_model_catalog.dart';

/// 端侧引擎结构化状态（序数 = AIDL int，禁调序）。
enum EngineStatus {
  ready,              // 0 就绪可用
  busy,               // 1 执行中，支持抢占 / 策略 B 驳回
  assetMissing,       // 2 资产缺失（M4 起回归终态语义：真·未导入/校验不过）
  insufficientMemory, // 3 当前可用 RAM 低于门禁
  circuitBroken,      // 4 处于熔断保护期（引擎故障，需熔断器/人工介入）
  unsupportedDevice,  // 5 硬件 / 芯片架构不匹配（D1 中低端）
  thermalCutoff,      // 6 热降级切云期（≥SEVERE；环境降级可自愈，温度回落即恢复）
  loading,            // 7 M4 追加（受理态，P2-14 销账）：模型装载中
  // 8 追加（Fix1 恢复语义去歧义）：`:engine` 拒绝同进程重载（单进程单装载
  // 纪律——geniex destroy 是否完整释放 ION/DSP PD 不可实证，同进程复载必死）
  // → 进程将自杀重启装载。**可重试中断，非终态**——与 assetMissing（真·未
  // 导入）严格分开：此前复用 assetMissing 把「空闲回收后重载」报成「请重新
  // 导入模型」（补救方向完全误导），且重载链路实际已断（端侧静默永久失效）。
  reloading,
  // 9 追加（F2，2026-10-31 ADR）：未知序数收容态——跨端漂移/未知状态非终态，
  // 折算为「未知需对账」驱动票据原子刷新（I2 未知≠终态），严禁再投毒进
  // unsupportedDevice 终态（此前越界兜底违背 I2，属旧语义残留）。
  unknownNeedReconcile,
}

/// 由 AIDL 序数还原枚举；越界值收容为 unknownNeedReconcile（未知≠终态，
/// 驱动票据对账，防跨端漂移既崩溃也不谎报终态）。
EngineStatus engineStatusFromOrdinal(int ordinal) =>
    ordinal >= 0 && ordinal < EngineStatus.values.length
        ? EngineStatus.values[ordinal]
        : EngineStatus.unknownNeedReconcile;

/// 端侧状态的**面向用户**原因文案（禁把内部枚举名直接抛给用户——真机曾见
/// 「模型装载失败（circuitBroken）」，用户看不懂也无从行动；枚举名只进日志）。
String engineStatusFailureReason(EngineStatus status) => switch (status) {
      EngineStatus.ready => '引擎已就绪',
      EngineStatus.busy => '引擎执行中',
      EngineStatus.assetMissing => '端侧模型未导入（请在设置导入模型后重试）',
      EngineStatus.insufficientMemory => '可用内存不足（请清理后台应用后重试）',
      EngineStatus.circuitBroken => '端侧引擎处于熔断保护期（请稍后重试）',
      EngineStatus.unsupportedDevice => '当前设备不支持本地推理',
      EngineStatus.thermalCutoff => '设备过热，端侧已暂停（温度回落后可重试）',
      EngineStatus.loading => '端侧模型装载中（请稍候）',
      EngineStatus.reloading => '端侧引擎重启装载中（请稍候）',
      EngineStatus.unknownNeedReconcile => '端侧状态未知（正在对账，请稍候）',
    };

/// 生成收尾原因（AIDL onGenerateFinished 的 finishReason int 映射）。
enum EngineFinishReason {
  stop,       // 0 正常完成
  cancelled,  // 1 §6.3 cancel：清在途后收尾
}

EngineFinishReason engineFinishReasonFromOrdinal(int ordinal) =>
    ordinal == 1 ? EngineFinishReason.cancelled : EngineFinishReason.stop;

/// 流式生成块（总纲 §2；tokenUsage 待 QNN 后端接入后补——Mock 阶段无计量）。
class EngineChunk {
  const EngineChunk({required this.deltaText, this.finishReason});

  final String deltaText;
  final EngineFinishReason? finishReason;
}

/// 生成参数（总纲 §2 GenerationConfig）。
///
/// 停用词契约（D-3 重构 2026-11-01，decisions.md ADR）：下发原始字符串序列
/// `stopSequences`，编码判定下沉各 Runner Native 自治（自绑 tokenizer 实时
/// match）——预编码 id 跨后端词表不互通（GGUF BPE vs .litertlm SentencePiece），
/// 旧 `stopTokenIds` 契约已退役。
class GenerationConfig {
  const GenerationConfig({
    this.maxTokens = 512,
    // Gemma3 官方推荐采样（技术报告 T=1.0 / top-p=0.95 / top-k=40，topK 已在
    // LiteRtLmRunner 对齐）：2026-11-02 真机反证——旧默认 0.7/0.9 下 gemma3-1b
    // 首问 7 字符陷数字环复读（看门狗截停），同机同模型 Google AI Edge
    // Gallery（官方 demo，官方推荐值）正常输出 → 低温窄分布低熵陷阱定谳。
    // 模型级参数：真机验证绿后升格 meta modelProfile.recommendedSampling（另立项）。
    this.temperature = 1.0,
    this.topP = 0.95,
    this.stopSequences = const [],
  });

  final int maxTokens;
  final double temperature;
  final double topP;
  final List<String> stopSequences;
}

/// `:engine` 进程死亡/致命事件（总纲 §2）：驱动 Panic、算子越界 abort、
/// 外部处决（SIGKILL/LMK 经 ServiceDisconnected 合流）。调用方（混合引擎）
/// 捕获即无缝切云，绝不让 Flutter 主进程闪退。
class EngineDiedException implements Exception {
  const EngineDiedException([this.reason = ':engine died']);

  final String reason;

  @override
  String toString() => 'EngineDiedException: $reason';
}

/// 端侧引擎显式加载状态（懒加载兜底：启动不占权重内存；首次命中端侧路径才
/// 进入 loading，加载完成转 ready；失败转 failed 并携带原因——UI 显式呈现，
/// 不静默降级为云端）。
enum OnDeviceLoadState {
  unloaded, // 未加载（启动默认：模型权重不驻留、:engine 不预启）
  loading, // 显式加载中（bind→就绪→资产→loadModel→数据面 worker）
  ready, // 已加载就绪（数据面 worker 在位，可生成）
  failed, // 加载失败（原因见 [OnDeviceLoadException]）
}

/// 端侧显式加载失败（区别于运行时 [EngineDiedException]）：仅发生在
/// [OnDeviceEnableCapable.enable] 阶段——模型装载 / 数据面 worker 启动等环节。
/// 语义 = 端侧不可用且**不静默切云**（由上层决定报错还是降级），与请求中途
/// 引擎死亡（[EngineDiedException]→无缝切云）正交。
class OnDeviceLoadException implements Exception {
  const OnDeviceLoadException(
    this.reason, {
    this.retryable = false,
    this.degraded = false,
    this.expectRestart = false,
  });

  final String reason;

  /// true = `:engine` 进程 / binder 中断（AMS 会重启并重连，实测 ~3s），
  /// [AidlOnDeviceEngine.enable] 对此做有界退避重试；终态失败（设备不支持 /
  /// 资产缺失 / 内存不足）一律 false——可自愈中断与终态失败必须分口径，
  /// 混同会把「进程被杀」报成「硬件不支持」（lesson gdw-load-notbound）。
  final bool retryable;

  /// true = **环境降级**（当前仅热降级：设备过热，`:engine` 已切云）——物理
  /// 降温即恢复，**不是引擎故障**。上层按 §5.2 Thermal→Cloud 切云完成本轮
  /// （产出优先），不按终态失败判死、不计入熔断口径；与 [retryable]（进程 /
  /// 通道中断，可退避重试）正交。
  final bool degraded;

  /// true = 本次中断源于「`:engine` 拒绝同进程重载 → 进程将自杀重启装载」
  /// （单进程单装载纪律）。该中断是**预期**的：紧随其后的 `not_bound` /
  /// 连接超时属冷启动窗口常态，**禁计入 fastKillStreak**——否则「有意自杀」
  /// 被误判为 LMK 快死，起跑水位抬到 5GB，反把端侧重载彻底堵死（4B 机型
  /// 常态 availMem 达不到 5GB → 端侧永久不可用）。
  final bool expectRestart;

  @override
  String toString() => 'OnDeviceLoadException: $reason';
}

/// 端侧「显式加载」能力（NPU :engine 路径支持；旧 LiteRT-LM 桥 / 不可用实现
/// 不实现本接口，[HybridCloudEngine] 经 `is OnDeviceEnableCapable` 探测）。
abstract interface class OnDeviceEnableCapable {
  /// 加载状态（unloaded/loading/ready/failed），UI 据此呈现加载指示。
  ValueListenable<OnDeviceLoadState> get loadState;

  /// 显式加载：bind→就绪→资产→loadModel→数据面 worker。幂等（ready 后 no-op）；
  /// 失败抛 [OnDeviceLoadException]（带原因），不静默降级。
  /// backendHint（AIDL 2026-11-02 #8）：准入探针后端选择权注入（'gpu' = 强制
  /// GPU 档装载）；null = Runner 自裁——业务面禁传（后端选择权归画像查表）。
  Future<EngineStatus> enable({OnDeviceModelOption? model, String? backendHint});

  /// 卸载释放（退回 unloaded，释放权重内存）。
  Future<void> disable();
}

/// 端侧引擎抽象接口（总纲 §2 完整粒度）。
abstract interface class OnDeviceEngine {
  /// 权威状态查询（M4 Contract：走**票据面** checkSession——`checkStatus`
  /// 轮询面已退役，状态唯一来源 = `:engine` 票据）。票据不可得（未连接 /
  /// 通道超时）返回 **null = 未知态**（I2 禁猜测，调用方按不可用/未知分流）。
  Future<EngineStatus?> authoritativeStatus();

  /// `== ready` 语法糖（总纲 §2）。状态未知（null）按不可用处理。
  Future<bool> isAvailable() async =>
      (await authoritativeStatus()) == EngineStatus.ready;

  Future<void> warmup();

  /// 流式生成。实现层须 `StreamController(onCancel: () => cancel(requestId))`
  /// （总纲 §2 流生命周期自动绑定，杜绝孤儿任务空跑）。
  Stream<EngineChunk> generate({
    required String requestId,
    required String prompt,
    GenerationConfig config = const GenerationConfig(),
  });

  /// 经 atomic stop_requested 下沉（§6.3）。
  Future<void> cancel(String requestId);

  /// KV-Cache 回滚（§2.4 Prefix Cache 唯一主路线；0 等价旧 resetContext）。
  Future<void> truncateContext({int keepTokens = 0});

  /// 主动回收 → COLD-EVICTED（§4.1）。
  Future<void> release();
}
