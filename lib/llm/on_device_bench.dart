/// 端侧吞吐正式测量（on-device S2，§1.2 验收口径）。
///
/// **打点定义（NPU 稿 §1.2：端到端打点）**：
/// - **TTFT**：Dart 发起 `generate` → 首个流块到达（含平台通道/AIDL 全链）；
/// - **decode span**：首块 → 末块到达（`:engine` 侧另打点 per-chunk 粒度，
///   logcat `EngineService: bench` 行，两者对照可剥离 40ms 微批量化偏差）；
/// - **TPOT 近似**：decode span / (chunkCount-1)——Genie 回调粒度即 decode
///   token 粒度，微批只影响投递不影响打点（时间戳在 sink 入口采集）。
///
/// 场景对齐 §1.2：短文本 ≈256ctx、长文本 ≈2Kctx。**ctx 计数为字符近似**
/// （Qwen 中文 ≈1.3~1.5 字/token；正式 tokenizer 精确计数归 §4.5 Detokenizer
/// 资产落地），结论按量级对照验收线，不逐 ms 抠。
library;

import 'package:flutter/foundation.dart';

import 'cloud/cloud_llm.dart';
import 'on_device_chat_prompt.dart';
import 'on_device_engine.dart';
import 'on_device_engine_aidl.dart';
import 'on_device_model_catalog.dart';

/// 吞吐测量门（启动引导 ready 后自动跑一轮）。
///
// 触发方式（dart-define，测量期构建专用）：
//   flutter build apk --debug --dart-define=ON_DEVICE_BENCH=true
// 默认关闭——正式交付构建不自动跑测量轮。
const bool kOnDeviceBenchOnReady =
    bool.fromEnvironment('ON_DEVICE_BENCH', defaultValue: false);

/// 测量轮指定模型目录（诊断面，dart-define 控制）。
///
/// 启动引导的资产通路走 `OnDeviceAssetManager`，其 support 根目录是 App
/// **内部**目录（adb 无权写入，只能由 App 自己经 OTA 通道下载）。做跨栈
/// 对照时需加载已手工落位的资产，故本开关让 bench 直接 `loadModel` 指定
/// 目录，绕过资产分发。空 = 沿用启动引导的资产（生产语义不变）。
///
///   --dart-define=ON_DEVICE_BENCH_MODEL_DIR=<已落位的模型目录绝对路径>
const String kOnDeviceBenchModelDir =
    String.fromEnvironment('ON_DEVICE_BENCH_MODEL_DIR');

/// D-4 双段对照（2026-11-03）：true = NPU 段后追加 `backendHint:'gpu'` 强制
/// GPU 段（backendHint 为探针面专用通道，bench 属诊断面同规则；:engine 禁
/// 同进程重载——段间经生产同款 disable→enable 重载链，进程冷启动自愈）。
/// false = 仅单段（Runner 自裁），存量行为。
const bool kOnDeviceBenchGpuPass =
    bool.fromEnvironment('ON_DEVICE_BENCH_GPU_PASS', defaultValue: true);

class OnDeviceBench {
  OnDeviceBench._();

  /// 当前测量模型的上下文窗口（prompt 拼装预算裁剪用；explicit 模式 = null）。
  static int? _caseContextTokens;

  static const int _maxTokens = 128;
  static const int _paddingCharsShort = 380; // ≈256 tok
  static const int _paddingCharsLong = 3000; // ≈2K tok

  static String _pad(int chars) =>
      '以下是与任务无关的背景资料，用于对齐预填充长度，请忽略其内容。' *
      ((chars / 30).ceil());

  /// D-4 双段测量：pass1 = Runner 自裁（NPU 优先）→ disable → pass2 =
  /// backendHint 'gpu' 强制 GPU 档。结果经 debugPrint 结构化输出（logcat
  /// 留痕，tok/s 直接对照 llama_cpp+GPU ~39 tok/s 归档基线）；内存/发热
  /// 由 adb 侧外部采集（dumpsys），不进本测量。
  static Future<void> run() async {
    debugPrint('[on-device-bench] baseline: llama_cpp+GPU ~39 tok/s (archived)');
    if (kOnDeviceBenchModelDir.isNotEmpty) {
      await _loadExplicitModelDir(kOnDeviceBenchModelDir);
      await _runCases('explicit', null);
      return;
    }
    final model = await OnDeviceModelSelection.read();
    if (model == null) {
      debugPrint('[DEGRADE] on-device-bench: no registered model, skip');
      return;
    }
    debugPrint('[on-device-bench] model=${model.dirName} '
        'ctx=${model.contextTokens ?? '?'}');
    _caseContextTokens = model.contextTokens;
    if (await _enableModel(model, null, 'pass1')) {
      await _runCases('pass=NPU', model.contextTokens);
    }
    if (!kOnDeviceBenchGpuPass) return;
    await sharedOnDeviceEngine.disable();
    if (await _enableModel(model, 'gpu', 'pass2')) {
      await _runCases('pass=GPU', model.contextTokens);
    }
  }

  /// 装载 [model]（backendHint：null = Runner 自裁 / 'gpu' = 强制 GPU 档）
  /// 并轮询就绪；enable 有界等待返回「装载中」时（含段间冷启动重载窗口）
  /// 继续票据面轮询，150s 覆盖冷启动重载。
  static Future<bool> _enableModel(
      OnDeviceModelOption model, String? backendHint, String tag) async {
    try {
      final st = await sharedOnDeviceEngine
          .enable(model: model, backendHint: backendHint);
      debugPrint('[on-device-bench] $tag enable(${backendHint ?? 'auto'}) '
          '-> ${st.name}');
      if (st == EngineStatus.unsupportedDevice) return false;
    } on OnDeviceLoadException catch (e) {
      debugPrint('[on-device-bench] $tag enable FAILED: ${e.reason} '
          '(continue polling; load chain retries in background)');
    }
    for (var i = 0; i < 150; i++) {
      final s = await sharedOnDeviceEngine.authoritativeStatus();
      if (s == EngineStatus.ready) {
        debugPrint('[on-device-bench] $tag ready after ~${i}s');
        return true;
      }
      if (s == EngineStatus.unsupportedDevice ||
          s == EngineStatus.assetMissing) {
        debugPrint('[on-device-bench] $tag terminal: ${s?.name}');
        return false;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    debugPrint('[DEGRADE] on-device-bench: $tag not ready after 150s');
    return false;
  }

  /// 两场景测量（ctx 感知：[contextTokens] 在场时长场景 padding 收窄到
  /// 窗口内——输出 512 + 系统开销 ~100 预留，中文 ≈1.3 字/token 折算）。
  static Future<void> _runCases(String tag, int? contextTokens) async {
    const shortPrompt = '请用一句话介绍骁龙 8 Elite 的 NPU。';
    final shortPad = _pad(_paddingCharsShort);
    final longChars = contextTokens == null
        ? _paddingCharsLong
        : (((contextTokens - 612) * 1.3).round()).clamp(200, _paddingCharsLong);
    final longPad = _pad(longChars);
    await _case(tag, 'short~256ctx', shortPrompt, shortPad);
    await _case(
        tag, 'long~${longChars ~/ 2}ctx', '请用一句话总结上文背景资料的用途。', longPad);
    await _case(tag, 'short-repeat', shortPrompt, shortPad);
  }

  /// 显式装载 [dir] 并轮询就绪（[kOnDeviceBenchModelDir] 诊断开关用）。
  ///
  /// 4B 会话创建（3GB ctx-bin）显著慢于 1.7B，故就绪轮询放宽到 90s。
  static Future<void> _loadExplicitModelDir(String dir) async {
    // Spike-1 测量期重试（npu-geniex-runtime 设计稿 §6）：启动首调可能撞
    // force-stop 后旧 ：engine binder 死亡（进程中断），等 3s 重试避开竞态。
    EngineStatus st = EngineStatus.assetMissing;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        st = await sharedOnDeviceEngine.loadModel(dir);
        break;
      } on OnDeviceLoadException catch (e) {
        debugPrint('[on-device-bench] loadModel($dir) attempt#$attempt FAILED: ${e.reason}');
        if (attempt == 3) return;
        await Future.delayed(const Duration(seconds: 3));
      }
    }
    debugPrint('[on-device-bench] loadModel($dir) -> ${st.name}');
    for (var i = 0; i < 90; i++) {
      // M4：票据面权威状态（checkStatus 轮询面已退役）；未知（null）= 装载
      // 中继续轮（禁猜测终态）。
      final s = await sharedOnDeviceEngine.authoritativeStatus();
      if (s == EngineStatus.ready) {
        debugPrint('[on-device-bench] model ready after ~${i}s');
        return;
      }
      if (s == EngineStatus.unsupportedDevice) {
        debugPrint('[on-device-bench] loadModel rejected: ${s?.name}');
        return;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    debugPrint('[DEGRADE] on-device-bench: model not ready after 90s');
  }

  static Future<void> _case(
      String tag, String name, String question, String padding) async {
    // LiteRtLmRunner 契约 = messages JSON（生产链同构；真机实证 2026-11-03：
    // 裸字符串 prompt 会被 Runner 以 invalid prompt shape 拒绝 status=-3）。
    final prompt = buildOnDeviceChatPromptJson(
      [UserMessage('$padding\n\n$question')],
      contextTokens: _caseContextTokens,
    );
    final sw = Stopwatch()..start();
    Duration? ttft;
    var chars = 0;
    var chunks = 0;
    try {
      await for (final chunk in sharedOnDeviceEngine.generate(
        requestId: 'bench-${DateTime.now().microsecondsSinceEpoch}',
        prompt: prompt,
        config: const GenerationConfig(maxTokens: _maxTokens, temperature: 0.7),
      )) {
        ttft ??= sw.elapsed;
        chars += chunk.deltaText.length;
        chunks++;
      }
      final total = sw.elapsed;
      // DRAIN 诊断档：:engine 侧 sink 不投递，本侧收不到任何块（ttft 为 null）
      // ——不是失败，:engine 的 bench 行仍带 tpot/numGenerated，取数在 logcat。
      if (ttft == null) {
        debugPrint('[on-device-bench] $tag case=$name DRAIN: no chunk '
            'delivered (see EngineService bench line for tpot)');
        return;
      }
      final decodeSpan = total - ttft;
      final tpotMs =
          chunks > 1 ? decodeSpan.inMicroseconds / 1000 / (chunks - 1) : 0.0;
      final tokPerSec =
          tpotMs > 0 ? (1000 / tpotMs).toStringAsFixed(1) : '?';
      debugPrint('[on-device-bench] $tag case=$name ttft=${ttft.inMilliseconds}ms '
          'total=${total.inMilliseconds}ms decodeSpan=${decodeSpan.inMilliseconds}ms '
          'chunks=$chunks chars=$chars tpot~${tpotMs.toStringAsFixed(1)}ms/chunk '
          'tok/s~$tokPerSec');
    } catch (e) {
      debugPrint('[on-device-bench] $tag case=$name FAILED: $e');
    }
  }
}
