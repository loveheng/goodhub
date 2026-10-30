import 'package:flutter/foundation.dart';

import 'llm.dart';
import 'on_device_engine.dart';
import 'on_device_engine_aidl.dart';
import 'on_device_model_catalog.dart';

/// 适配件：把总纲 §2 的 [OnDeviceEngine] 挂进既有 `HybridCloudEngine` 的
/// 端侧槽（`OnDeviceLlmEngine`，单发聚合语义——hybrid 只做单发提取）。
///
/// `EngineDiedException` 不在此吞：原样上抛给混合引擎的死亡兜底
/// （`_deviceSendWithDiedFallback`，S1-5），由其无缝切云。
///
/// 落点说明（2026-10-30 体量收口）：本件自 [AidlOnDeviceEngine] 主文件拆出
/// ——端侧引擎实现（控制面 + 数据面解码 + 装载状态机）与「挂进混合引擎的装配
/// 适配」是两件事，拆后各件单一职责；主文件回落 800 行体量线内（standards §8.3
/// 超标件只减不增）。
class AidlOnDeviceLlmEngineAdapter
    implements OnDeviceLlmEngine, OnDeviceEnableCapable, OnDeviceFailureReasonAware {
  AidlOnDeviceLlmEngineAdapter(this._inner);

  final AidlOnDeviceEngine _inner;
  String? _currentRequestId;

  /// 最近一次生成的失败原因（零产出归因面，2026-10-30 真机实证「第二轮没有
  /// 输出」：失败原因若一律显示「空产出」，用户与排查者无从区分「模型没说话」
  /// 与「会话重置失败 / 热降级 / 通道拒绝」）。
  String? _lastFailureReason;

  @override
  String? get lastFailureReason => _lastFailureReason;

  @override
  String get name => '端侧引擎（:engine Genie）';

  @override
  Future<bool> get isAvailable => _inner.isAvailable();

  @override
  String? get unavailableReason => null;

  @override
  Future<String?> unavailableReasonAsync() async {
    final s = await _inner.checkStatus();
    // 面向用户的白话原因（禁泄漏内部枚举名——否则用户读到
    // 「端侧引擎状态：thermalCutoff」这类不可读文案）。
    return s == EngineStatus.ready
        ? null
        : '端侧引擎状态：${engineStatusFailureReason(s)}';
  }

  // ---- OnDeviceEnableCapable（显式加载）----

  @override
  ValueListenable<OnDeviceLoadState> get loadState => _inner.loadState;

  @override
  Future<EngineStatus> enable({OnDeviceModelOption? model}) =>
      _inner.enable(model: model);

  @override
  Future<void> disable() => _inner.disable();

  /// 前台态判定（场景 A/B/C 切云语义拆分）：透传桥面 Activity 计数。
  Future<bool> isForeground() => _inner.isForeground();

  @override
  Future<String?> generate(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
  }) async {
    final requestId = 'aidl-${DateTime.now().microsecondsSinceEpoch}';
    _currentRequestId = requestId;
    final fullPrompt = system == null ? prompt : '$system\n\n$prompt';
    try {
      final buf = StringBuffer();
      await for (final chunk in _inner.generate(
        requestId: requestId,
        prompt: fullPrompt,
        config: GenerationConfig(maxTokens: maxTokens),
      )) {
        buf.write(chunk.deltaText);
      }
      final text = buf.toString();
      debugPrint('[on_device] gen done requestId=$requestId '
          'promptChars=${fullPrompt.length} outChars=${text.length}');
      if (text.isEmpty) {
        _lastFailureReason = '空产出（端侧模型未产出任何内容）';
        return null;
      }
      _lastFailureReason = null;
      return text;
    } on EngineDiedException {
      rethrow; // 死亡兜底契约（S1-5）：原样上抛给混合引擎捕获切云，禁在此吞。
    } catch (e) {
      // OnDeviceLlmEngine 契约：生成失败返回 null（翻译式降级）——上层发
      // 「端侧生成失败」可观测报错（unavailableReasonAsync 带真值），
      // 不再让裸 StateError 穿透成错误卡。
      _lastFailureReason = '端侧生成异常：${e.runtimeType}'
          '${e is StateError ? '（${e.message}）' : ''}';
      debugPrint('[DEGRADE] on_device generate: $e');
      return null;
    } finally {
      if (_currentRequestId == requestId) _currentRequestId = null;
    }
  }

  @override
  Future<bool> cancelActive() async {
    final current = _currentRequestId;
    if (current == null) return false;
    await _inner.cancel(current);
    return true;
  }

  @override
  Future<bool> warmup() async {
    await _inner.warmup();
    return true;
  }

  @override
  Future<void> release() => _inner.release();

  @override
  Future<bool> isWarmed() async => true;
}
