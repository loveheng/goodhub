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
import 'on_device_engine_aidl.dart';

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

/// 原语调用参数（刻意最小：无任务模板位）。
class OnDevicePrimitiveConfig {
  const OnDevicePrimitiveConfig({
    this.maxTokens = 256,
    this.temperature = 0.3,
    this.topP = 0.9,
  });

  /// 产出上限（原语任务输出体量界；摘要默认 256）。
  final int maxTokens;

  /// 原语任务偏确定性，低温缺省。
  final double temperature;
  final double topP;
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

/// 端侧能力原语（公共服务抽象面；实现 = AIDL 引擎，测试 = 假件）。
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
class AidlOnDeviceCapabilityService implements OnDeviceCapabilityService {
  AidlOnDeviceCapabilityService(this._engine,
      {this.cloudFallback, this.inputFilter});

  final AidlOnDeviceEngine _engine;

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
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) async {
    // 熔断双轨：降级窗口内不再压引擎（连槽位探测都省，直接走降级路径）。
    if (_inDegradeCooldown()) {
      return _degrade(fallback, '原语降级窗口内（连续 $_consecutiveFailures 次失败）',
          traceId,
          instruction: instruction, input: input, config: config);
    }
    // PII 入口过滤（评审修复 #2：过滤**前置**到 try 外——降级路径同样只允许
    // 已过滤文本出境，fail-closed：过滤失败 = 拒绝调用，以占位符替代原文，
    // 绝不让未过滤原文经任何降级档流出）。
    String effectiveInput;
    final filter = inputFilter;
    if (filter == null) {
      effectiveInput = input;
    } else {
      try {
        effectiveInput = filter(input);
      } catch (fe) {
        return await _degrade(
            fallback, 'PII 过滤失败（fail-closed 拒绝）: $fe', traceId,
            instruction: instruction,
            input: '[已按 PII 围栏拦截：过滤失败，原文不外传]',
            config: config);
      }
    }
    try {
      // 懒加载边界：会话未就绪不触发装载，直接按策略收口。
      if (_engine.loadState.value != OnDeviceLoadState.ready) {
        return await _degrade(fallback, '端侧会话未就绪（未装载/装载中）', traceId,
            instruction: instruction, input: effectiveInput, config: config);
      }
      final prompt = buildOnDeviceChatPromptJson([
        SystemMessage(instruction),
        UserMessage(effectiveInput),
      ]);
      final requestId =
          'prim_${traceId == null ? '' : '${traceId}_'}${_seq++}';
      final out = await _generateWithSlotWait(
        requestId: requestId,
        prompt: prompt,
        config: config,
      );
      final t = out.trim();
      if (t.isEmpty) {
        return await _degrade(fallback, '端侧产出为空', traceId,
            instruction: instruction, input: effectiveInput, config: config);
      }
      _consecutiveFailures = 0; // 成功即复位独立计数
      _degradedUntil = null;
      return t;
    } on OnDevicePrimitiveException {
      rethrow;
    } catch (e) {
      return await _degrade(fallback, '端侧原语失败: $e', traceId,
          instruction: instruction, input: effectiveInput, config: config);
    }
  }

  /// 生成 + 槽位有界等待：`service_busy` 在预算窗口内退避重试，其余异常上抛。
  Future<String> _generateWithSlotWait({
    required String requestId,
    required String prompt,
    required OnDevicePrimitiveConfig config,
  }) async {
    final deadline = DateTime.now().add(slotWaitBudget);
    while (true) {
      try {
        final buf = StringBuffer();
        await for (final chunk in _engine.generate(
          requestId: requestId,
          prompt: prompt,
          config: GenerationConfig(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
          ),
        )) {
          buf.write(chunk.deltaText);
        }
        return buf.toString();
      } on PlatformException catch (e) {
        final busy = e.code == 'service_busy' &&
            DateTime.now().isBefore(deadline);
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
