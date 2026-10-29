/// 端侧引擎公共契约（立法源 = docs/design/on-device-capability.md §2 v2.7）。
///
/// 本件承载跨进程契约的 Dart 侧镜像：`EngineStatus` 枚举序数与 AIDL
/// `checkStatus()`/`initEngine()` 返回的 int 一一对应（0..5），禁调序。
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
  assetMissing,       // 2 驱动就绪但模型未下载
  insufficientMemory, // 3 当前可用 RAM 低于门禁
  circuitBroken,      // 4 处于熔断保护期
  unsupportedDevice,  // 5 硬件 / 芯片架构不匹配（D1 中低端）
}

/// 由 AIDL 序数还原枚举；越界值视为 unsupportedDevice（防跨端漂移崩溃）。
EngineStatus engineStatusFromOrdinal(int ordinal) =>
    ordinal >= 0 && ordinal < EngineStatus.values.length
        ? EngineStatus.values[ordinal]
        : EngineStatus.unsupportedDevice;

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
/// 约束（§6.7）：停用词不接受原始字符串——客户端无全功能 BPE encoder，
/// 字符串→id 编码由共享 tokenizer/服务端在 Prompt 编排层完成后传入。
class GenerationConfig {
  const GenerationConfig({
    this.maxTokens = 512,
    this.temperature = 0.7,
    this.topP = 0.9,
    this.stopTokenIds = const {},
    this.stopTokenSequences = const [],
  });

  final int maxTokens;
  final double temperature;
  final double topP;
  final Set<int> stopTokenIds;
  final List<List<int>> stopTokenSequences;
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
  const OnDeviceLoadException(this.reason, {this.retryable = false});

  final String reason;

  /// true = `:engine` 进程 / binder 中断（AMS 会重启并重连，实测 ~3s），
  /// [AidlOnDeviceEngine.enable] 对此做有界退避重试；终态失败（设备不支持 /
  /// 资产缺失 / 内存不足）一律 false——可自愈中断与终态失败必须分口径，
  /// 混同会把「进程被杀」报成「硬件不支持」（lesson gdw-load-notbound）。
  final bool retryable;

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
  Future<EngineStatus> enable({OnDeviceModelOption? model});

  /// 卸载释放（退回 unloaded，释放权重内存）。
  Future<void> disable();
}

/// 端侧引擎抽象接口（总纲 §2 完整粒度）。
abstract interface class OnDeviceEngine {
  /// 结构化状态查询；`busy/ready` 禁 TTL 缓存（v2.6 调度纪律）。
  Future<EngineStatus> checkStatus();

  /// `== ready` 语法糖（总纲 §2）。
  Future<bool> isAvailable() async => (await checkStatus()) == EngineStatus.ready;

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
