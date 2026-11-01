import 'dart:async';

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
    // M4：票据面权威状态（checkStatus 轮询面已退役）。未知（null）如实报
    // 「状态未知」，禁猜测成某个具体态。
    final s = await _inner.authoritativeStatus();
    if (s == null) return '端侧引擎状态未知（:engine 未连接或通道超时）';
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
  Stream<String> generateStream(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
  }) {
    final requestId = 'aidl-${DateTime.now().microsecondsSinceEpoch}';
    _currentRequestId = requestId;
    // prompt = 消息序列 JSON（2026-10-31 设计修正），system 已在消息序列内
    //（由 :engine 侧 ChatML 构造 system 轮）——旧 system 拼接退役。
    final fullPrompt = prompt;
    // 双层控制器：内层 _inner 流的取消须同步联动 cancelActive（onCancel 里
    // 退订内层订阅触发 _inner 的 onCancel → cancel(requestId)），外层订阅者
    // 取消 = 内层退订 = 生成终止（流生命周期自动绑定，杜绝孤儿生成空跑）。
    late final StreamController<String> ctrl;
    StreamSubscription<EngineChunk>? sub;
    var sawAny = false;
    ctrl = StreamController<String>(
      onCancel: () async {
        await sub?.cancel();
        if (_currentRequestId == requestId) _currentRequestId = null;
      },
    );
    sub = _inner.generate(
      requestId: requestId,
      prompt: fullPrompt,
      config: GenerationConfig(maxTokens: maxTokens),
    ).listen(
      (chunk) {
        if (chunk.deltaText.isEmpty) return;
        sawAny = true;
        ctrl.add(chunk.deltaText);
      },
      onError: (Object e) {
        if (_currentRequestId == requestId) _currentRequestId = null;
        ctrl.addError(e);
      },
      onDone: () async {
        if (_currentRequestId == requestId) _currentRequestId = null;
        // 内容取证（与旧聚合路径同口径：outChars/bytes 不符、复读环等须见
        // 实际内容才能定位）；零产出归因在此落 lastFailureReason，调用方
        // 经 OnDeviceFailureReasonAware 取真因（契约：零产出 = 无事件 close）。
        debugPrint('[on_device] gen stream done requestId=$requestId '
            'promptChars=${fullPrompt.length} sawAny=$sawAny');
        _lastFailureReason =
            sawAny ? null : '空产出（端侧模型未产出任何内容）';
        await ctrl.close();
      },
      cancelOnError: true,
    );
    return ctrl.stream;
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
