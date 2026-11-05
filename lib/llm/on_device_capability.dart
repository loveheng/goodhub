/// 端侧能力原语门面（OnDeviceCapabilityService，on-device-capability §2 公共
/// 服务面的 Dart 载体）。
///
/// **职责边界（2026-10-31 用户拍板，ADR 见 epic decisions.md）**：本门面只提供
/// **模型能力供给**——无状态 `complete()` 原语；摘要 / 翻译 / 打标签 / 文本优化
/// 等**任务语义由消费方编排**（外部 MCP 服务或各消费点自带 instruction），
/// 本层不内置任务模板、不进聊天历史、不产生任何会话副作用。
///
/// 设计要点：
/// - **无状态单发**：instruction+input → 单轮消息序列（复用
///   `buildOnDeviceChatPromptJson`，system 合并与历史预算裁剪由该件承载）；
/// - **不触发装载**：懒加载立法（2026-10-29）下，2GB 装载只由聊天等主路径
///   显式触发；原语在端侧会话未就绪时**立即按降级策略收口**，绝不作为装载
///   触发源（避免后台摘要类任务突发拉起 2GB 权重）；
/// - **槽位等待**（2026-10-31 裁决）：`:engine` 单执行槽即容量为 1 的队列，
///   原语撞 `service_busy` 时在 [slotWaitBudget] 有界窗口内退避重试，超时按
///   降级策略收口——前台会话事实优先，原语不与主交互争抢；
/// - **降级类型化 + 标记化**：三档 [PrimitiveFallbackPolicy]，降级一律打
///   `[DEGRADE]` 留痕（可自动降级、不可静默降级）；
/// - **熔断双轨**（F5 落地项预告）：本层失败不进主聊天会话 CircuitBreaker，
///   失败仅向上抛类型化异常由消费方按策略处置。
///
/// 纯 Dart 件（无平台依赖），消费方 = coordinator / 未来 MCP 导出面。
library;

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;

import 'cloud/cloud_llm.dart';
import 'on_device_chat_prompt.dart';
import 'on_device_engine.dart';

/// 降级策略（三档，类型化禁止隐式）。
enum PrimitiveFallbackPolicy {
  /// 快速失败：端侧不可用/失败直接抛 [OnDevicePrimitiveException]，
  /// 由消费方自行兜底（摘要器 E1 口径：调用方保留原文 + [DEGRADE]）。
  failFast,

  /// 切云端完成：调用装配注入的云端兜底函数；未注入时落 [degradeToTruncate]。
  degradeToCloud,

  /// 确定性地板：原文按字符级硬上限折叠（Head+Tail，口径对齐
  /// agent_loop `kToolResultHardCapTokens` ≈ 8KB），返回折叠文本。
  degradeToTruncate,
}

/// 挂起态载荷（W3-S18c，K21 三条红线的机械承载）：
/// - **已算完产物**：待确认操作的意图与参数是流收口后已算完的产物，不是
///   半截生成态；
/// - **继续签名**：调用方凭 [resumeToken] 与用户确认凭据在新一轮重入；
///   宿主**不驻留等待实例**（挂起即返回，等待在调用方/用户侧）；
/// - **不占执行槽**：挂起发生在流收口之后，算力已让槽；
///   **禁在算力占用期内同步等待人工确认**。
class PrimitiveSuspension {
  const PrimitiveSuspension({
    required this.intent,
    required this.params,
    required this.resumeToken,
    this.payload,
  });

  /// 待确认操作的意图（人可读，供确认卡渲染）。
  final String intent;

  /// 操作参数（结构化键值；超长载荷用既有 `$ref` 引用句柄承载）。
  final Map<String, String> params;

  /// 继续签名：新一轮重入的凭据（宿主不驻留等待实例，签名即重入锚）。
  final String resumeToken;

  /// 已算完的产物文本（挂起时生成已完成——红线：非半截生成态）。
  final String? payload;
}

/// 原语调用参数（刻意最小：无任务模板位）。
class OnDevicePrimitiveConfig {
  const OnDevicePrimitiveConfig({
    this.maxTokens = 256,
    this.temperature = 0.3,
    this.topP = 0.9,
    this.prefixReuse,
  });

  /// 产出上限（原语任务输出体量界；摘要默认 256）。
  final int maxTokens;

  /// 原语任务偏确定性，低温缺省。
  final double temperature;
  final double topP;

  /// 前缀复用提示（S18b 契约留位，可选）：调用方显式持有 [PrefixReuseHandle]
  /// 后在后续调用传入。**不承诺命中率**（K12——[Fact] 2026-11-05 真机实证：
  /// GenieSession 每请求 `w.reset()` 单发隔离下同 prompt 重发 TTFT 持平
  /// （4661→4971ms，Ace 6 / Qwen3.5-2B llama_cpp 栈）= 每请求全量重 prefill，
  /// 无跨请求前缀缓存命中，Runner 侧不承载；重评触发 =
  /// context-stepped-pruning §2.5 ADR（SDK 暴露会话级复用接口））。
  /// 不支持提示的引擎面静默忽略（能力缺失非降级，
  /// 见 [OnDevicePrefixReuseAware] 契约注）。缺省 null = 既有行为零变化。
  final PrefixReuseHint? prefixReuse;
}

/// 前缀复用句柄（S18b 契约留位）：供给面签发、调用方显式持有与失效的不透明
/// 凭据。**本期只落契约与句柄传递**——句柄不承载任何已实证的缓存语义，
/// [Fact] 2026-11-05 真机实证前缀复用无收益（见 [OnDeviceCapabilityConfig.prefixReuse]
/// 注），Runner 侧不承载，句柄维持纯传递载体。
class PrefixReuseHandle {
  const PrefixReuseHandle({required this.scope, required this.epoch});

  /// 复用域标识（调用方语义，如 `summarize` / `classify:<item-id>`）。
  final String scope;

  /// 签发纪元（供给面单调递增；同 scope 重新签发即新纪元，旧句柄可被失效）。
  final int epoch;

  @override
  String toString() => 'PrefixReuseHandle($scope#$epoch)';

  @override
  bool operator ==(Object other) =>
      other is PrefixReuseHandle &&
      other.scope == scope &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(scope, epoch);
}

/// 前缀复用提示（S18b）：句柄 + 可选的前缀体量预估，经
/// [OnDevicePrimitiveConfig.prefixReuse] 随原语调用传递。
class PrefixReuseHint {
  const PrefixReuseHint({required this.handle, this.expectedPrefixChars});

  final PrefixReuseHandle handle;

  /// 预期稳定前缀体量（字符数，可选）——供 Runner 侧自治匹配参考，不承诺。
  final int? expectedPrefixChars;

  @override
  String toString() =>
      'PrefixReuseHint($handle${expectedPrefixChars == null ? '' : ', ~$expectedPrefixChars chars'})';
}

/// **前缀复用能力**（可选接口——S18b 契约留位的承载面）。
///
/// 设计为**可选接口**而非主接口方法（同 [OnDeviceInterruptible] 铁律）：
/// 主接口加方法会迫使所有实现与桩件同步改签名（零收益的破坏面）；本能力
/// 无现有实现可兑现（引擎侧承载待实证），更须隔离在可选面上。
///
/// **K12 红线**：**收益未实证前不承诺命中率**——本接口只承载「句柄签发 /
/// 传递 / 失效」的契约壳，不承诺任何复用效果； Runner 侧自治匹配（引用
/// 既有前缀缓存与上下文回滚能力，**不新建缓存机制**）随收益实证落地。
abstract interface class OnDevicePrefixReuseAware {
  /// 签发前缀复用句柄（纯值构造，零副作用、不触发装载）。
  ///
  /// [scope] 为调用方语义的复用域标识；同 scope 重复签发返回**新纪元**句柄
  /// （旧句柄不自动失效，由调用方显式 [invalidatePrefixReuse]）。
  PrefixReuseHandle acquirePrefixReuseHandle({required String scope});

  /// 显式失效句柄（幂等）：调用方主动废弃复用域（如底层资产换装后）。
  /// 本期契约壳 = no-op（引擎侧承载待实证）；实现方禁抛（失效失败不构成
  /// 原语失败，句柄语义未实证前失效也无实义）。
  Future<void> invalidatePrefixReuse(PrefixReuseHandle handle);
}

/// 原语失败（failFast 语义的唯一出口；cause 保留真因供归因）。
class OnDevicePrimitiveException implements Exception {
  const OnDevicePrimitiveException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'OnDevicePrimitiveException: $message${cause == null ? '' : ' (cause: $cause)'}';
}

/// 原语被打断（协作式打断生效，K11）。
///
/// **语义边界**：本异常只表示「本次调用作废」（产出丢弃、不计数、不回程），
/// **不承诺算力已腾出**——打断是协作式的（中断只在生成循环检查点生效），
/// 等待窗口耗尽时不得假设打断已生效（K11）。
class OnDeviceInterruptedException implements Exception {
  const OnDeviceInterruptedException([this.reason = '端侧调用被打断']);

  final String reason;

  @override
  String toString() => 'OnDeviceInterruptedException: $reason';
}

/// **可中断聚合**能力（可选接口——K17 调用方进程死亡联动打断的承载面）。
///
/// 供给面实现方可支持：在流建立后、收尾前允许**外部取消**（取消随退订下沉
/// → 引擎 `cancel(requestId)` → 算力立即让槽）。
///
/// **同口径铁律**：本能力与 [OnDeviceCapabilityService.complete] **语义完全
/// 相同**（受理段收口 / 三档降级 / 失败计数 / 空产出判定同一份实现）——
/// 禁另立一套降级链（双源即漂移），实现方须把 [complete] 降为
/// [completeInterruptible] 的包装。
///
/// 设计为**可选接口**而非主接口方法：主接口加方法会迫使所有实现与桩件
/// 同步改签名（零收益的破坏面）；可选接口让不支持的实现走退化路径
/// （执行器按 [OnDeviceCapabilityService.complete] 执行，无打断能力）。
abstract interface class OnDeviceInterruptible {
  /// complete 的可中断变体：与 [OnDeviceCapabilityService.complete] 同语义，
  /// 差别 = [onSubscribed] 回调拿到**幂等取消钩子**（外部打断源注册位）。
  ///
  /// 打断触发（取消钩子被调）→ 订阅取消 → 引擎让槽 → 本方法以
  /// [OnDeviceInterruptedException] 收口（**无产出**、**不计入失败计数**——
  /// 打断是外部事件，不是端侧不可用）。
  Future<String> completeInterruptible({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config,
    PrimitiveFallbackPolicy fallback,
    String? traceId,
    void Function(Future<void> Function() cancel)? onSubscribed,
  });
}

/// 端侧能力原语（公共服务抽象面；实现 = AIDL 引擎，测试 = 假件）。
///
/// **供给面唯一入口（W3-S16 收口钉）**：[complete] 是端侧算力供给面的
/// **唯一**调用入口——新增消费方一律经本接口，禁绕过原语面直连
/// [OnDeviceSupplyFace].generate 自组管线（直连面 = 主聊天路径专属，
/// 与供给面分层，见 `docs/design/on-device-task-capability.md` §3 四层
/// 分层）。收口纪律：新入口只须转为契约声明，不新增第二原语。
///
/// **无状态 / 幂等语义（K20）**：
/// - **无状态**：单次调用自足——语义由 [complete] 参数全量给定，调用方
///   侧无会话/上下文残留可依赖；实现侧不驻留任何轮次状态（每次调用独立
///   构造 prompt，历史归调用方注入）；
/// - **单轮边界**：不驱动工具往返（round-trip 由宿主工具环/任务来源方
///   推进），失败重调 = 重新推理，语义幂等（无外部状态累积副作用）；
/// - **不触发装载**：会话未就绪按 [PrimitiveFallbackPolicy] 收口（懒加载
///   边界保持，显式装载走 W3-S18 可用性查询面，不归原语）。
abstract interface class OnDeviceCapabilityService {
  /// 单发完成：instruction（任务指令）+ input（输入文本）→ 模型产出文本。
  ///
  /// 失败时行为由 [fallback] 决定；[traceId] 仅作日志归因，不参与路由。
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config,
    PrimitiveFallbackPolicy fallback,
    String? traceId,
  });

  /// 能力可用性查询（W3-S18）：只读探测，零副作用、不触发装载。
  ///
  /// 供给面调用前的判据面——调用方据此决定直调 / 显式装载 / 分流云端。
  Future<OnDeviceCapabilityAvailability> availability();

  /// 幂等显式装载（W3-S18）：**仅由调用方主动发起**——本方法是装载的显式
  /// 入口，不是 [complete] 的隐式兜底；懒加载边界保持（原语调用绝不触发
  /// 装载，红线见 S16 契约钉）。幂等：已 ready 时 no-op 直接返回。
  ///
  /// 装载失败抛 [OnDeviceLoadException]（真因透传，禁静默降级）。
  Future<void> loadExplicit();

  /// 流式原语（W3-S18c）：instruction + input → 产出文本流。
  ///
  /// 端侧引擎契约本就是流式——本方法是**暴露既有能力**（S18c 实证基线），
  /// [complete] 降为其聚合包装。语义约束：
  /// - **取消随退订下沉**：订阅取消即透传 `cancel(requestId)`（引擎层
  ///   `onCancel:` 既有承载），算力立即让槽，无孤儿任务空跑；
  /// - **受理段收口**：熔断窗口 / PII 过滤 / 未就绪判定在流建立**前**完成
  ///   ——未就绪直接抛 [OnDevicePrimitiveException]（流式消费方自行按策略
  ///   降级，本方法不内嵌三档降级——那是 [complete] 聚合包装的职责）；
  /// - **挂起态边界（K21）**：挂起是消费方编排产物——待确认操作必须是
  ///   **已算完的产物**（流已收口、执行槽已释放）打包为 [PrimitiveSuspension]
  ///   返回；**禁在算力占用期内同步等待人工确认**（挂起不占执行槽）。
  Stream<EngineChunk> completeStream({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config,
    String? traceId,
  });
}

/// 能力可用性三态（W3-S18）。
enum OnDeviceCapabilityAvailability {
  /// 热态：权重已驻留，可立即产出。
  ready,

  /// 冷态：未装载或装载中（可经 [OnDeviceCapabilityService.loadExplicit]
  /// 显式装载；交互级遇冷态的分流裁决归路由判定链 D3 档）。
  cold,

  /// 不可用：装载终态失败（资产缺失 / 设备不支持 / 内存不足）。
  unavailable,
}

/// 原语输入过滤端口（F5 PII 入口收口的注入位）：在 input 进入端侧引擎前
/// 做规则遮蔽（正则四类等）。null = 未装配（当前生产缺省——PII 围栏立法源
/// 在 coordinator `pii_fence.dart`，抽 core 前不做双源复制；正式接线随
/// 能力原语对外导出（Step 2/P2）立项）。**fail-closed 纪律**：装配后过滤
/// 抛异常 = 拒绝本次原语调用（绝不静默放行原文）。
typedef PrimitiveInputFilter = String Function(String input);

/// AIDL 引擎实现：消费进程级单例 [sharedOnDeviceEngine] 的生成流。
///
/// 生命周期 owner：引擎单例由 main.dart 生命周期管理，本类不持有、不释放。
///
/// **熔断双轨（2026-10-31 裁决）**：本类自带独立失败计数——连续
/// [failureThreshold] 次失败进入 [degradeCooldown] 降级窗口，窗口内新请求
/// 直接走降级路径（`[DEGRADE]` 留痕）；**绝不触碰主聊天会话的
/// CircuitBreaker**（原语失败只代表原语任务形态失败，引擎级物理崩溃仍由
/// 主熔断器经 EngineDiedException 口径响应）。
class AidlOnDeviceCapabilityService
    implements OnDeviceCapabilityService, OnDeviceInterruptible, OnDevicePrefixReuseAware {
  AidlOnDeviceCapabilityService(this._engine,
      {this.cloudFallback, this.inputFilter});

  final OnDeviceSupplyFace _engine;

  /// 前缀复用句柄签发纪元（进程内单调；仅句柄身份，非会话状态——K20 无状态
  /// 纪律不受影响：句柄不驻留轮次语义，承载归 Runner 侧待实证项）。
  int _prefixEpoch = 0;

  /// degradeToCloud 的云端兜底函数（装配注入；null 时该档落 truncate）。
  final Future<String> Function(
    String instruction,
    String input,
    OnDevicePrimitiveConfig config,
  )? cloudFallback;

  /// PII 入口过滤（见 [PrimitiveInputFilter] 注释；null = 未装配）。
  final PrimitiveInputFilter? inputFilter;

  /// 熔断双轨独立计数（不进主会话 CircuitBreaker）。
  int _consecutiveFailures = 0;
  DateTime? _degradedUntil;

  /// 连续失败阈值（2026-10-31 裁决：满 3 次降级）。
  static const int failureThreshold = 3;

  /// 降级窗口（窗口内直接走降级路径，不再压引擎）。
  static const Duration degradeCooldown = Duration(minutes: 5);

  /// 槽位有界等待窗口（2026-10-31 裁决：2000ms）。
  static const Duration slotWaitBudget = Duration(milliseconds: 2000);

  /// 降级 truncate 字符地板（对齐 kToolResultHardCapTokens≈2000t≈8KB）。
  static const int truncateFloorChars = 8192;

  /// 原语请求自增序号（requestId 唯一性；进程内单调）。
  int _seq = 0;

  bool _inDegradeCooldown() {
    final until = _degradedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  @override
  Future<OnDeviceCapabilityAvailability> availability() async {
    // 只读探测（零副作用，不触发装载）——loadState 三态映射：
    // ready=热态；unloaded/loading=冷态；failed=不可用（终态失败）。
    return switch (_engine.loadState.value) {
      OnDeviceLoadState.ready => OnDeviceCapabilityAvailability.ready,
      OnDeviceLoadState.failed => OnDeviceCapabilityAvailability.unavailable,
      _ => OnDeviceCapabilityAvailability.cold,
    };
  }

  @override
  Future<void> loadExplicit() async {
    // 幂等显式装载（S18）：仅由调用方主动发起；ready = no-op。
    // enable() 为 OnDeviceEnableCapable 合取成员（OnDeviceSupplyFace 保证
    // 在场），失败真因透传（OnDeviceLoadException），禁静默降级。
    if (_engine.loadState.value == OnDeviceLoadState.ready) return;
    await _engine.enable();
  }

  @override
  PrefixReuseHandle acquirePrefixReuseHandle({required String scope}) {
    // S18b 契约留位：纯值签发（零副作用、不触发装载、不驻留轮次状态）。
    // 纪元单调递增保证同 scope 重新签发可辨新旧；句柄**不承载已实证的
    // 缓存语义**（K12：收益未实证前不承诺命中率），引擎侧承载随待实证
    // 项落地——届时 Runner 侧经 hint.handle 自治匹配，本面只传递。
    return PrefixReuseHandle(scope: scope, epoch: ++_prefixEpoch);
  }

  @override
  Future<void> invalidatePrefixReuse(PrefixReuseHandle handle) async {
    // S18b 契约留位：幂等 no-op（句柄语义未实证，失效亦无实义；实现方
    // 禁抛——失效失败不构成原语失败）。引擎侧回滚承载随收益实证落地。
  }

  @override
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) =>
      // 语义单源（S18c + K17）：complete = completeInterruptible 的聚合包装
      // （降级三档 / 熔断计数 / 空产出判定只在下面一份实现里——禁双源漂移）。
      completeInterruptible(
        instruction: instruction,
        input: input,
        config: config,
        fallback: fallback,
        traceId: traceId,
      );

  @override
  Future<String> completeInterruptible({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
    void Function(Future<void> Function() cancel)? onSubscribed,
  }) async {
    // 受理段（流建立前收口：熔断窗口 / PII / 未就绪）由 completeStream 内
    // 完成，其异常经流错误通道进入本方法的 catch → 统一走 [_degrade] 收口
    // （禁旁路降级链：旁路 = 计数丢失 + degradeToCloud 档在该形态下失效）。
    try {
      final buf = StringBuffer();
      final completer = Completer<String>();
      var interrupted = false;
      late StreamSubscription<EngineChunk> sub;
      // 取消钩子（幂等）：打断源经 [onSubscribed] 注册 → 退订 → 引擎
      // `cancel(requestId)` 让槽（取消随退订下沉）。
      Future<void> cancelOnce() async {
        if (interrupted) return;
        interrupted = true;
        await sub.cancel();
        if (!completer.isCompleted) {
          completer.completeError(const OnDeviceInterruptedException());
        }
      }
      sub = completeStream(
        instruction: instruction,
        input: input,
        config: config,
        traceId: traceId,
      ).listen(
        (chunk) => buf.write(chunk.deltaText),
        onError: (Object e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(buf.toString().trim());
        },
        cancelOnError: true,
      );
      // 订阅建立后立即交出取消钩子（打断源注册位）——自此外部打断可让槽。
      onSubscribed?.call(cancelOnce);
      final t = await completer.future;
      if (t.isEmpty) {
        return await _degrade(fallback, '端侧产出为空', traceId,
            instruction: instruction, input: input, config: config);
      }
      _consecutiveFailures = 0; // 成功即复位独立计数
      _degradedUntil = null;
      return t;
    } on OnDeviceInterruptedException {
      // 打断是**外部事件**（调用方死亡等），不是端侧不可用——不计入降级失败
      // 计数、不走降级策略（产出作废由调用方处置；K11：打断未生效不等于算力
      // 已腾出，引擎侧终态自收）。
      rethrow;
    } catch (e) {
      final reason = e is OnDevicePrimitiveException
          ? e.message
          : '端侧原语失败: $e';
      return await _degrade(fallback, reason, traceId,
          instruction: instruction, input: input, config: config);
    }
  }

  @override
  Stream<EngineChunk> completeStream({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    String? traceId,
  }) async* {
    // 受理段（流建立前收口）：熔断窗口 → PII 过滤（fail-closed）→ 未就绪
    // 判定（懒加载边界：不触发装载，直接抛给流式消费方自行降级）。
    if (_inDegradeCooldown()) {
      throw OnDevicePrimitiveException(
          '原语降级窗口内（连续 $_consecutiveFailures 次失败）');
    }
    String effectiveInput;
    final filter = inputFilter;
    if (filter == null) {
      effectiveInput = input;
    } else {
      try {
        effectiveInput = filter(input);
      } catch (fe) {
        throw OnDevicePrimitiveException(
            'PII 过滤失败（fail-closed 拒绝）: $fe');
      }
    }
    if (_engine.loadState.value != OnDeviceLoadState.ready) {
      throw OnDevicePrimitiveException('端侧会话未就绪（未装载/装载中）');
    }
    final prompt = buildOnDeviceChatPromptJson([
      SystemMessage(instruction),
      UserMessage(effectiveInput),
    ]);
    final requestId =
        'prim_${traceId == null ? '' : '${traceId}_'}${_seq++}';
    // 槽位有界退避受理（service_busy 窗口内重试，超时上抛——流式消费方
    // 自行处置）；受理成功后**直通引擎流**：取消随退订下沉（订阅取消即
    // 透传 cancel(requestId)，算力立即让槽——引擎层 onCancel 既有承载）。
    final deadline = DateTime.now().add(slotWaitBudget);
    while (true) {
      try {
        yield* _engine.generate(
          requestId: requestId,
          prompt: prompt,
          config: GenerationConfig(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
          ),
        );
        return;
      } on PlatformException catch (e) {
        final busy =
            e.code == 'service_busy' && DateTime.now().isBefore(deadline);
        if (!busy) rethrow;
        await Future<void>.delayed(
            const Duration(milliseconds: 150)); // 有界退避重试
      }
    }
  }

  /// 降级收口：一律 `[DEGRADE]` 留痕，再按策略执行。
  Future<String> _degrade(
    PrimitiveFallbackPolicy fallback,
    String reason,
    String? traceId, {
    required String instruction,
    required String input,
    required OnDevicePrimitiveConfig config,
  }) async {
    // 熔断双轨计数：每次降级即累计，满阈值进入冷却窗口（成功在 complete()
    // 内复位）。failFast 下同样计数——消费者自行兜底不代表任务成功。
    _consecutiveFailures++;
    if (_consecutiveFailures >= failureThreshold && _degradedUntil == null) {
      _degradedUntil = DateTime.now().add(degradeCooldown);
      // ignore: avoid_print
      print('[DEGRADE] on_device_primitive: $_consecutiveFailures consecutive '
          'failures → degrade cooldown ${degradeCooldown.inMinutes}min');
    }
    // ignore: avoid_print
    print('[DEGRADE] on_device_primitive'
        '${traceId == null ? '' : '($traceId)'}: $reason → $fallback');
    switch (fallback) {
      case PrimitiveFallbackPolicy.failFast:
        throw OnDevicePrimitiveException(reason);
      case PrimitiveFallbackPolicy.degradeToCloud:
        final fb = cloudFallback;
        if (fb != null) return fb(instruction, input, config);
        return _truncate(input); // 云兜底未装配：落确定性地板
      case PrimitiveFallbackPolicy.degradeToTruncate:
        return _truncate(input);
    }
  }

  /// 确定性地板：超 [truncateFloorChars] 时 Head 80% + Tail 20% 折叠。
  String _truncate(String input) {
    if (input.length <= truncateFloorChars) return input;
    const mark = '\n[……已按端侧原语地板折叠……]\n';
    final headLen = truncateFloorChars * 4 ~/ 5;
    final tailLen = truncateFloorChars - headLen;
    return input.substring(0, headLen) + mark + input.substring(input.length - tailLen);
  }
}
