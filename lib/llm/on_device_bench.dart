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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/storage/keyed_write_queue.dart';
import 'cloud/cloud_llm.dart';
import 'on_device_bench_archive.dart';
import 'on_device_bench_suite.dart';
import 'on_device_chat_prompt.dart';
import 'on_device_engine.dart';
import 'on_device_model_catalog.dart';

// S2：单例接口化后，裸装载链与原语生成经能力接口探测取用（禁持具体类）。
OnDeviceExplicitLoadAware _explicitEngine() {
  final engine = sharedOnDeviceEngine;
  if (engine is! OnDeviceExplicitLoadAware) {
    throw StateError('端侧引擎未实现显式装载扩展面（OnDeviceExplicitLoadAware）');
  }
  return engine;
}

/// 吞吐测量门（启动引导 ready 后自动跑一轮）。
///
// 触发方式（dart-define，测量期构建专用）：
//   flutter build apk --debug --dart-define=ON_DEVICE_BENCH=true
// 默认关闭——正式交付构建不自动跑测量轮。
const bool kOnDeviceBenchOnReady = bool.fromEnvironment(
  'ON_DEVICE_BENCH',
  defaultValue: false,
);

/// 测量轮指定模型目录（诊断面，dart-define 控制）。
///
/// 启动引导的资产通路走 `OnDeviceAssetManager`，其 support 根目录是 App
/// **内部**目录（adb 无权写入，只能由 App 自己经 OTA 通道下载）。做跨栈
/// 对照时需加载已手工落位的资产，故本开关让 bench 直接 `loadModel` 指定
/// 目录，绕过资产分发。空 = 沿用启动引导的资产（生产语义不变）。
///
///   --dart-define=ON_DEVICE_BENCH_MODEL_DIR=<已落位的模型目录绝对路径>
const String kOnDeviceBenchModelDir = String.fromEnvironment(
  'ON_DEVICE_BENCH_MODEL_DIR',
);

/// D-4 双段对照（2026-11-03）：true = NPU 段后追加 `backendHint:'gpu'` 强制
/// GPU 段（backendHint 为探针面专用通道，bench 属诊断面同规则；:engine 禁
/// 同进程重载——段间经生产同款 disable→enable 重载链，进程冷启动自愈）。
/// false = 仅单段（Runner 自裁），存量行为。
const bool kOnDeviceBenchGpuPass = bool.fromEnvironment(
  'ON_DEVICE_BENCH_GPU_PASS',
  defaultValue: true,
);

/// KV-Cache 复用实证（2026-11-03）：true = 追加 TTFT-历史长度对照扫（cache
/// probe）。判据：同问题在 64/192/384/640 tok 历史下 TTFT 线性增长 = 每请求
/// 全量重 prefill（LiteRtLmRunner 每请求新建 Conversation，SDK 回调面无
/// token 计数无法直读缓存命中——本对照是唯一可观测面）；平坦 = 有前缀缓存。
const bool kOnDeviceBenchCacheProbe = bool.fromEnvironment(
  'ON_DEVICE_BENCH_CACHE_PROBE',
  defaultValue: false,
);

/// 任务套件扫描（task-capability W2 · S11）：按**任务类型 × 端侧可行性**
/// 采集真机数据（首 token 延迟 / 吞吐 / 上下文体量档 / 产出质量档）——对照表
/// 的数据来源（`docs/design/on-device-task-capability.md` §5.2）。
///
/// 触发（测量期构建专用）：
///   flutter build apk --debug --dart-define=ON_DEVICE_BENCH=true \
///     --dart-define=ON_DEVICE_BENCH_TASK_SUITE=true
/// 开启后**替代**存量短/长场景扫描（不叠加——同轮两种口径混采会让 TTFT
/// 不可比）。用例集与机械质量判据 = `on_device_bench_suite.dart`；采集行
/// 模型与归档渲染 = `on_device_bench_archive.dart`。
const bool kOnDeviceBenchTaskSuite = bool.fromEnvironment(
  'ON_DEVICE_BENCH_TASK_SUITE',
  defaultValue: false,
);

class OnDeviceBench {
  OnDeviceBench._();

  /// 当前测量模型的上下文窗口（prompt 拼装预算裁剪用；explicit 模式 = null）。
  static int? _caseContextTokens;

  /// 任务套件的产出上限（token）——任务型产出普遍短于自由对话。
  static const int _taskMaxTokens = 256;

  /// 本轮采集行（落盘为对照表归档）。
  static final List<OnDeviceBenchRow> _rows = [];

  static const int _maxTokens = 128;
  static const int _paddingCharsShort = 380; // ≈256 tok
  static const int _paddingCharsLong = 3000; // ≈2K tok

  static String _pad(int chars) =>
      '以下是与任务无关的背景资料，用于对齐预填充长度，请忽略其内容。' * ((chars / 30).ceil());

  /// D-4 双段测量：pass1 = Runner 自裁（NPU 优先）→ disable → pass2 =
  /// backendHint 'gpu' 强制 GPU 档。结果经 debugPrint 结构化输出（logcat
  /// 留痕，tok/s 直接对照 llama_cpp+GPU ~39 tok/s 归档基线）；内存/发热
  /// 由 adb 侧外部采集（dumpsys），不进本测量。
  static Future<void> run() async {
    debugPrint(
      '[on-device-bench] baseline: llama_cpp+GPU ~39 tok/s (archived)',
    );
    if (kOnDeviceBenchModelDir.isNotEmpty) {
      if (kOnDeviceBenchTaskSuite) {
        debugPrint(
          '[DEGRADE] on-device-bench: explicit 模式不支持任务套件'
          '（任务套件需选中模型的窗口/采样元数据），回落存量短/长场景',
        );
      }
      await _loadExplicitModelDir(kOnDeviceBenchModelDir);
      await _runCases('explicit', null);
      return;
    }
    final model = await OnDeviceModelSelection.read();
    if (model == null) {
      debugPrint('[DEGRADE] on-device-bench: no registered model, skip');
      return;
    }
    debugPrint(
      '[on-device-bench] model=${model.dirName} '
      'ctx=${model.contextTokens ?? '?'}',
    );
    _caseContextTokens = model.contextTokens;
    // 段标签按**实际可控维度**命名（不把自裁段叫成 NPU 段）：任务套件模式下
    // 段一 = Runner 自裁、段二 = 强制 GPU 档——Dart 侧读不到后端画像（:engine
    // 未透出 activeRuntime），标 NPU 会把自裁结果误记成 NPU 实测。
    final tag1 = kOnDeviceBenchTaskSuite ? 'pass=auto' : 'pass=NPU';
    final tag2 = kOnDeviceBenchTaskSuite ? 'pass=gpu' : 'pass=GPU';
    if (await _enableModel(model, null, 'pass1')) {
      await _runSegmentCases(tag1, model);
    }
    if (!kOnDeviceBenchGpuPass) return;
    await sharedOnDeviceEngine.disable();
    if (await _enableModel(model, 'gpu', 'pass2')) {
      await _runSegmentCases(tag2, model);
    }
    await _flushArchive();
  }

  /// 单段扫描分派：任务套件模式走任务套件（对照表数据），否则走存量短/长
  /// 场景（既有基准口径）——两者不叠加，避免同轮两种口径混采。
  static Future<void> _runSegmentCases(
    String tag,
    OnDeviceModelOption model,
  ) async {
    if (kOnDeviceBenchTaskSuite) {
      await _runTaskSuite(tag, model);
    } else {
      await _runCases(tag, model.contextTokens);
    }
  }

  /// 装载 [model]（backendHint：null = Runner 自裁 / 'gpu' = 强制 GPU 档）
  /// 并轮询就绪；enable 有界等待返回「装载中」时（含段间冷启动重载窗口）
  /// 继续票据面轮询，150s 覆盖冷启动重载。
  static Future<bool> _enableModel(
    OnDeviceModelOption model,
    String? backendHint,
    String tag,
  ) async {
    try {
      final st = await sharedOnDeviceEngine.enable(
        model: model,
        backendHint: backendHint,
      );
      debugPrint(
        '[on-device-bench] $tag enable(${backendHint ?? 'auto'}) '
        '-> ${st.name}',
      );
      if (st == EngineStatus.unsupportedDevice) return false;
    } on OnDeviceLoadException catch (e) {
      debugPrint(
        '[on-device-bench] $tag enable FAILED: ${e.reason} '
        '(continue polling; load chain retries in background)',
      );
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
    final longChars = _longPadChars(contextTokens);
    final longPad = _pad(longChars);
    await _case(tag, 'short~256ctx', shortPrompt, shortPad);
    await _case(tag, 'long~${longChars ~/ 2}ctx', '请用一句话总结上文背景资料的用途。', longPad);
    await _case(tag, 'short-repeat', shortPrompt, shortPad);
    if (kOnDeviceBenchCacheProbe) await _cacheProbeCases(tag, contextTokens);
  }

  /// KV-Cache 复用实证扫：同问题、历史 padding 按 64/192/384/640 tok 阶梯
  /// 放大，TTFT 曲线定谳「每请求全量重 prefill vs 前缀缓存」（判据见
  /// [kOnDeviceBenchCacheProbe] 注）。输入预算与长场景同口径（输出 512 +
  /// 系统开销 ~100 预留），窗口外档位自动裁掉。
  static Future<void> _cacheProbeCases(String tag, int? contextTokens) async {
    const question = '请用一句话介绍骁龙 8 Elite 的 NPU。';
    final budgetTokens = contextTokens == null
        ? 640
        : ((contextTokens - 612).clamp(64, 640));
    for (final tok in const [64, 192, 384, 640]) {
      if (tok > budgetTokens) break;
      await _case(tag, 'cache~${tok}tok', question, _pad((tok * 1.3).round()));
    }
  }

  // ── 任务套件扫描（task-capability W2 · S11）──────────────────────────

  /// 任务套件扫描：逐用例跑一轮，产出结构化采集行（`TASK`）+ 原始产出行
  /// （`TASKOUT`，人工场次目视复核用）。
  static Future<void> _runTaskSuite(
    String tag,
    OnDeviceModelOption model,
  ) async {
    final rec = model.recommendedSampling;
    debugPrint(
      '[on-device-bench] $tag task-suite start: '
      'cases=${OnDeviceBenchSuite.cases.length} '
      'sampling=T${rec?.temperature ?? 1.0}/P${rec?.topP ?? 0.95} '
      '(model recommended / 内建缺省)',
    );
    for (final c in OnDeviceBenchSuite.cases) {
      await _taskCase(tag, c, model);
    }
  }

  /// 单个任务用例：构造消息 → 流式生成 → 机械质量判据 → 采集行。
  static Future<void> _taskCase(
    String tag,
    OnDeviceBenchCase c,
    OnDeviceModelOption model,
  ) async {
    final composed = <(String, String)>[];
    var inputChars = 0;
    for (final t in c.turns) {
      final content = t.role == 'user'
          ? _withPadding(t.content, c.tier, model.contextTokens)
          : t.content;
      if (t.role == 'user') inputChars += content.length;
      composed.add((t.role, content));
    }
    final messages = <CloudChatMessage>[
      for (final (role, content) in composed)
        if (role == 'user')
          UserMessage(content)
        else
          AssistantMessage(content: content),
    ];
    final prompt = buildOnDeviceChatPromptJson(
      messages,
      contextTokens: _caseContextTokens,
    );
    final rec = model.recommendedSampling;
    final config = GenerationConfig(
      maxTokens: _taskMaxTokens,
      // 采样走**模型推荐档**（meta recommendedSampling，缺省 T=1.0/P=0.95）：
      // 真机反证（2026-11-02）低温窄分布会触发 gemma3-1b 复读环，低温测出的
      // 质量档是采样伪影而非端侧适用性。
      temperature: rec?.temperature ?? 1.0,
      topP: rec?.topP ?? 0.95,
    );
    final sw = Stopwatch()..start();
    Duration? ttft;
    var chars = 0;
    var chunks = 0;
    final buf = StringBuffer();
    try {
      await for (final chunk in sharedOnDeviceEngine.generate(
        requestId: 'bench-task-${DateTime.now().microsecondsSinceEpoch}',
        prompt: prompt,
        config: config,
      )) {
        ttft ??= sw.elapsed;
        chars += chunk.deltaText.length;
        chunks++;
        buf.write(chunk.deltaText);
      }
      final output = buf.toString();
      if (ttft == null) {
        // DRAIN 诊断档：:engine sink 不投递，本侧收不到任何块——不是失败，
        // :engine 的 bench 行仍带 tpot/numGenerated。
        debugPrint(
          '[on-device-bench] $tag task=${c.id} DRAIN: no chunk delivered',
        );
        _emitTaskRow(
          tag,
          c,
          model,
          promptChars: inputChars,
          error: 'DRAIN 无块投递',
        );
        return;
      }
      final total = sw.elapsed;
      final decodeSpan = total - ttft;
      final tpotMs = chunks > 1
          ? decodeSpan.inMicroseconds / 1000 / (chunks - 1)
          : 0.0;
      final tokPerSec = tpotMs > 0 ? 1000 / tpotMs : 0.0;
      final grade = c.grader(output);
      _emitTaskRow(
        tag,
        c,
        model,
        promptChars: inputChars,
        ttftMs: ttft.inMilliseconds,
        tpotMs: tpotMs,
        tokPerSec: tokPerSec,
        chars: chars,
        quality: grade.quality.id,
        score: grade.score,
        note: grade.note,
      );
      _emitTaskOut(c, output);
    } catch (e) {
      _emitTaskRow(tag, c, model, promptChars: inputChars, error: '$e');
    }
  }

  /// 长体量档补 padding（口径对齐存量长场景：ctx 感知，中文 ≈1.3 字/token；
  /// 预算 = 窗口 - 输出预留 512 - 系统+用户预留 256 ≈ 上下文余量）。
  static String _withPadding(
    String content,
    OnDeviceBenchInputTier tier,
    int? contextTokens,
  ) {
    if (tier != OnDeviceBenchInputTier.long) return content;
    return '$content\n\n${_pad(_longPadChars(contextTokens))}';
  }

  /// 长场景 padding 字符数（存量场景与任务套件共用单一口径）。
  static int _longPadChars(int? contextTokens) => contextTokens == null
      ? _paddingCharsLong
      : (((contextTokens - 612) * 1.3).round()).clamp(200, _paddingCharsLong);

  /// 采集行（机器可解析；键集固定 = `kOnDeviceBenchRowKeys`，缺项即坏行）。
  static void _emitTaskRow(
    String tag,
    OnDeviceBenchCase c,
    OnDeviceModelOption model, {
    int? promptChars,
    int? ttftMs,
    double? tpotMs,
    double? tokPerSec,
    int? chars,
    String? quality,
    double? score,
    String? note,
    String? error,
  }) {
    final row = OnDeviceBenchRow(
      model: model.dirName,
      ctx: model.contextTokens ?? 0,
      segment: tag,
      taskType: c.taskType.id,
      caseId: c.id,
      tier: c.tier.id,
      promptChars: promptChars ?? 0,
      ttftMs: ttftMs ?? 0,
      tpotMs: tpotMs ?? 0,
      tokPerSec: tokPerSec ?? 0,
      chars: chars ?? 0,
      quality: quality ?? 'fail',
      score: score ?? 0,
      note: note ?? '',
      error: error ?? '',
    );
    _rows.add(row);
    debugPrint('[on-device-bench] TASK ${jsonEncode(row.toJson())}');
  }

  /// 原始产出行（人工场次目视复核；截断防 logcat 行长超限）。
  static void _emitTaskOut(OnDeviceBenchCase c, String output) {
    final clipped = output.length > 400
        ? '${output.substring(0, 400)}…'
        : output;
    debugPrint(
      '[on-device-bench] TASKOUT ${jsonEncode({'case': c.id, 'output': clipped})}',
    );
  }

  /// 采集落盘（外部应用目录——adb 可直接 pull，不依赖 root / run-as）。
  ///
  /// 产出两件：`rows.jsonl`（一行一条采集行，供消费面解析）与 `archive.md`
  /// （对照表 markdown，格式对齐既有真机基准归档）。
  static Future<void> _flushArchive() async {
    if (_rows.isEmpty) return;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) {
        debugPrint('[DEGRADE] on-device-bench: external files dir unavailable');
        return;
      }
      final out = Directory('${dir.path}/bench');
      if (!await out.exists()) await out.create(recursive: true);
      final rows = _rows.map((r) => jsonEncode(r.toJson())).join('\n');
      // 原子写唯一入口（arch-guard R10）：队列内 tmp→flush→rename，防崩溃留半截
      // 归档（半截归档会被误读成「采集已完成」）。
      await KeyedWriteQueue.instance.enqueueAtomicWrite(
        '${out.path}/rows.jsonl',
        utf8.encode('$rows\n'),
      );
      await KeyedWriteQueue.instance.enqueueAtomicWrite(
        '${out.path}/archive.md',
        utf8.encode(
          renderBenchArchive(
            _rows,
            model: _rows.first.model,
            collectedAt: DateTime.now().toIso8601String(),
          ),
        ),
      );
      debugPrint(
        '[on-device-bench] archive written: ${out.path}/archive.md '
        '(${_rows.length} rows)',
      );
    } catch (e) {
      debugPrint('[DEGRADE] on-device-bench: archive write failed: $e');
    }
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
        st = await _explicitEngine().loadModel(dir);
        break;
      } on OnDeviceLoadException catch (e) {
        debugPrint(
          '[on-device-bench] loadModel($dir) attempt#$attempt FAILED: ${e.reason}',
        );
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
        // 显式装载链投影写回（2026-11-05 drift 观测债）：裸 loadModel 绕过
        // enable 的 _loadState 写面——就绪后按权威票据补写，消除后续每次
        // generate 的 session-mirror drift。
        await _explicitEngine().reconcileLoadStateFromTicket();
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
    String tag,
    String name,
    String question,
    String padding,
  ) async {
    // LiteRtLmRunner 契约 = messages JSON（生产链同构；真机实证 2026-11-03：
    // 裸字符串 prompt 会被 Runner 以 invalid prompt shape 拒绝 status=-3）。
    final prompt = buildOnDeviceChatPromptJson([
      UserMessage('$padding\n\n$question'),
    ], contextTokens: _caseContextTokens);
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
        debugPrint(
          '[on-device-bench] $tag case=$name DRAIN: no chunk '
          'delivered (see EngineService bench line for tpot)',
        );
        return;
      }
      final decodeSpan = total - ttft;
      final tpotMs = chunks > 1
          ? decodeSpan.inMicroseconds / 1000 / (chunks - 1)
          : 0.0;
      final tokPerSec = tpotMs > 0 ? (1000 / tpotMs).toStringAsFixed(1) : '?';
      debugPrint(
        '[on-device-bench] $tag case=$name ttft=${ttft.inMilliseconds}ms '
        'total=${total.inMilliseconds}ms decodeSpan=${decodeSpan.inMilliseconds}ms '
        'chunks=$chunks chars=$chars tpot~${tpotMs.toStringAsFixed(1)}ms/chunk '
        'tok/s~$tokPerSec',
      );
    } catch (e) {
      debugPrint('[on-device-bench] $tag case=$name FAILED: $e');
    }
  }
}
