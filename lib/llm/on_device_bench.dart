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

import 'on_device_engine.dart';
import 'on_device_engine_aidl.dart';

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

class OnDeviceBench {
  OnDeviceBench._();

  static const int _maxTokens = 128;
  static const int _paddingCharsShort = 380; // ≈256 tok
  static const int _paddingCharsLong = 3000; // ≈2K tok

  static String _pad(int chars) =>
      '以下是与任务无关的背景资料，用于对齐预填充长度，请忽略其内容。' *
      ((chars / 30).ceil());

  /// 跑一轮两场景测量；结果经 debugPrint 结构化输出（logcat 留痕）。
  ///
  /// case=short-repeat：同 session 内**逐字重发** short 场景 prompt——Genie
  /// 前缀复用（GenieX 拍板红利③，NPU 稿 §2.4）生效时第二轮 Prefill 命中
  /// KV 缓存，TTFT 应显著低于首轮；对照差值即前缀复用收益观测（S2-3 收口
  /// 时的遗留观测项）。
  static Future<void> run() async {
    if (kOnDeviceBenchModelDir.isNotEmpty) {
      await _loadExplicitModelDir(kOnDeviceBenchModelDir);
    }
    const shortPrompt = '请用一句话介绍骁龙 8 Elite 的 NPU。';
    final shortPad = _pad(_paddingCharsShort);
    await _case('short~256ctx', shortPrompt, shortPad);
    await _case('long~2Kctx', '请用一句话总结上文背景资料的用途。', _pad(_paddingCharsLong));
    await _case('short-repeat', shortPrompt, shortPad);
  }

  /// 显式装载 [dir] 并轮询就绪（[kOnDeviceBenchModelDir] 诊断开关用）。
  ///
  /// 4B 会话创建（3GB ctx-bin）显著慢于 1.7B，故就绪轮询放宽到 90s。
  static Future<void> _loadExplicitModelDir(String dir) async {
    EngineStatus st;
    try {
      st = await sharedOnDeviceEngine.loadModel(dir);
    } on OnDeviceLoadException catch (e) {
      // 装载链路通道异常（进程中断 / 未知码）现按语义上抛而非折算
      // unsupportedDevice——bench 诊断面如实打印原因后收手。
      debugPrint('[on-device-bench] loadModel($dir) FAILED: ${e.reason}');
      return;
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

  static Future<void> _case(String name, String question, String padding) async {
    final prompt = '$padding\n\n$question';
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
        debugPrint('[on-device-bench] case=$name DRAIN: no chunk delivered '
            '(see EngineService bench line for tpot)');
        return;
      }
      final decodeSpan = total - ttft;
      final tpotMs =
          chunks > 1 ? decodeSpan.inMicroseconds / 1000 / (chunks - 1) : 0.0;
      debugPrint('[on-device-bench] case=$name ttft=${ttft.inMilliseconds}ms '
          'total=${total.inMilliseconds}ms decodeSpan=${decodeSpan.inMilliseconds}ms '
          'chunks=$chunks chars=$chars tpot~${tpotMs.toStringAsFixed(1)}ms/chunk');
    } catch (e) {
      debugPrint('[on-device-bench] case=$name FAILED: $e');
    }
  }
}
