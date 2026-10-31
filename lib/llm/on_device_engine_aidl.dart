import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'llm.dart';
import 'on_device_asset_manager.dart';
import 'on_device_circuit_breaker.dart';
import 'on_device_detokenizer.dart';
import 'on_device_engine.dart';
import 'on_device_engine_binding.dart';
import 'on_device_load_poll.dart';
import 'on_device_mem_gate.dart';
import 'on_device_session_gate.dart';
import 'on_device_model_catalog.dart';

/// `OnDeviceEngine` 的 AIDL 适配件（on-device epic S1-5，S2 正式接线；
/// S3-6 数据面收编）。
///
/// 经 [OnDeviceEngineBinding]（MethodChannel `goodhub/on_device_engine`）驱动
/// `:engine` 独立进程：generate 为单发流（控制面 startGenerate +
/// onGenerateFinished 收尾）。**token 微批走 native 数据面**（S3-6，NPU 稿
/// §6.1/§6.4）：`:engine` 写 Ashmem RingBuffer + pipe 唤醒，主进程 libgdw
/// worker 经 NativePort 直投 [handleDataBatch]（Binder onTokens 过渡通道已
/// 退役，禁双路）；载荷经 [StreamingDetokenizer] 流式重组为文本 delta
///（S1-4）。
///
/// S2 正式接线：后端 = Genie 持久会话（:engine 内 GenieDialog，替换 S1-5
/// Mock 生成器）；bind 时序竞态经 [OnDeviceEngineBinding.waitReady]（就绪
/// 事件收口）正式解决——warmup/generate 均挂起至就绪或超时快速失败。
///
/// 流生命周期自动绑定（总纲 §2 v2.5）：`StreamController(onCancel:)` 于订阅
/// 取消瞬间透传 `cancel(requestId)`，杜绝孤儿任务空跑发烫。
/// S3-2 FGS 前台预挂阈值：maxTokens ≥ 此值视为「可能耗时」长生成（§6.2
/// 「generate() 发起且判定可能耗时时即附着」；实测 ~60ms/token 下 256 token
/// ≈15s+，越过 OEM 冻结观察窗量级——拍板兜底值，与 EngineService.kt 同锚）。
const int kFgsPromoteMinTokens = 256;

/// 装载 / 状态探测期「`:engine` 进程或 binder 已中断」的通道错误码白名单。
///
/// 语义 = **可自愈中断**（AMS 重启 :engine 并重连，实测 ~3s），与终态枚举
/// `unsupportedDevice`（硬件 / 驱动基线不支持）严格正交——一律折算成后者
/// 会把「装载中被系统内存压力 SIGKILL」报成「设备不支持」，误导排查
/// （lesson gdw-load-notbound 的回归钉）。
///
/// - `not_bound`：桥面 `engine == null`（未绑定 / 已解绑）；
/// - `engine_binder_error`：桥面 handler 内抛 `DeadObjectException` 等
///   （binder 尸体；S2-5 实证 :engine 装载中被 mem-pressure 静默 SIGKILL
///   后即本码——AMS 重启重连前所有通道调用都撞它）。
const Set<String> kEngineInterruptCodes = {'not_bound', 'engine_binder_error'};

/// 装载链路通道异常的语义判别（唯一的错误分类入口，禁各处自行折算）：
/// 中断码 → 可重试中断；其余 → 终态失败且**错误码如实入文案**（不伪装成
/// `unsupportedDevice`，否则「进程被杀/通道异常」被读成「硬件不支持」）。
/// 文案不自带「端侧加载失败」前缀——[HybridCloudEngine] 会再包一层
/// `端侧加载失败：<reason>`，双层前缀对用户是噪音。
OnDeviceLoadException _loadFailureOf(String? code) =>
    kEngineInterruptCodes.contains(code)
        ? const OnDeviceLoadException(
            '引擎进程中断（系统回收或崩溃），请重试',
            retryable: true)
        : OnDeviceLoadException('端侧引擎通道错误（$code）');

class AidlOnDeviceEngine implements OnDeviceEngine {
  AidlOnDeviceEngine({
    OnDeviceEngineBinding? binding,
    EngineCircuitBreaker? breaker,
    Duration? noProgressTimeout,
  })  : _binding = binding ?? OnDeviceEngineBinding(),
        breaker = breaker ?? EngineCircuitBreaker(),
        noProgressTimeout = noProgressTimeout ?? kNoProgressTimeout {
    _binding.onDataBatch = _onDataBatch;
    _binding.onDataEof = _onDataPlaneEof;
    _binding.onIpcDeadlock = _onIpcDeadlock;
    _binding.onGenerateFinished = _onFinished;
    _binding.onEngineDied = _onDied;
    _binding.onProcessDied = _onProcessDied;
    _binding.onEngineEvicted = _onEngineEvicted;
    _binding.onEvictionInterrupted = _onEvictionInterrupted;
  }

  /// 端侧流**无进展看门狗**时长（注入位供单测压缩）：端侧数据面此前**无任何
  /// 超时兜底**——`:engine` 的收尾事件（onGenerateFinished）一旦丢失/迟到，
  /// 活跃流永挂 → 混合引擎的端侧单发聚合 await-for 永挂 → **本轮问答零响应**
  /// （真机实证「第二轮没有任何响应」）。判据取「字节活体」：生成期字节每
  /// ~40ms 一批（§6.1 微批），连续 [noProgressTimeout] 无字节即判数据面失联
  /// → 以 EngineDiedException 收口 → 混合引擎无缝切云（产出优先，绝不静默挂死）。
  ///
  /// 口径对齐云端首 token 超时（30s，degradation_controller.firstTokenTimeout）：
  /// 端侧首 token 受 NPU 预热影响，给足余量。
  static const Duration kNoProgressTimeout = Duration(seconds: 30);

  /// 无进展看门狗时长（可注入，测试用小值）。
  final Duration noProgressTimeout;

  /// 显式加载状态（懒加载兜底：启动 unloaded；首次命中端侧路径经 [enable]
  /// 转 loading→ready；失败转 failed）。UI 据此呈现「端侧模型加载中…」指示。
  final ValueNotifier<OnDeviceLoadState> _loadState =
      ValueNotifier<OnDeviceLoadState>(OnDeviceLoadState.unloaded);

  /// 加载状态可观察面（[OnDeviceEnableCapable]）。
  ValueListenable<OnDeviceLoadState> get loadState => _loadState;

  /// B-2 长时后台装载任务：运行中非 null；收口（ready/failed）经 whenComplete
  /// 置回 null，后续 enable 重新决策。disable 驱逐沿经代次号作废旧任务。
  /// 在途装载任务（单飞；§2.10 I7）与其去重键 = 目标 modelId（身份锚点
  /// dirName）。同键并发 enable 合并等待；键变更 → 代次作废重提交。
  Future<bool>? _loadTask;
  String? _loadTaskModelId;
  int _loadGen = 0;

  /// 后台装载任务的失败原因（终态失败时供 enable 原样上抛）。
  String? _loadTaskError;

  /// 请求侧对装载任务的单次有界等待上限（场景 C 前台冷启动保护，用户裁决
  /// 60~90s）：超时 = 请求侧报错退出、**装载后台继续**（B-2 语义不变）。
  static const Duration _loadWaitPerRequest = Duration(seconds: 90);

  /// 显式加载端侧引擎（懒加载兜底：首次命中端侧路径由 [HybridCloudEngine]
  /// 触发）。装载跑在后台任务 [_runBackgroundLoad] 里（B-2：中断类失败分钟级
  /// 退避持续重试，**不随请求判死**）；本请求仅有界等待，超时抛**可重试**的
  /// 「装载进行中」（q-1：显式报错不切云）。终态失败如实上抛。
  Future<EngineStatus> enable({OnDeviceModelOption? model}) async {
    if (_loadState.value == OnDeviceLoadState.ready) return EngineStatus.ready;
    final target = model ?? await OnDeviceModelSelection.read();
    if (_loadTask != null) {
      // M2 §2.10 I7 装载单飞：去重键 = 目标 modelId（身份锚点 dirName）——
      // 同目标的并发预热/请求/验证装载合并等待同一在途任务；目标变更则
      // 代次作废旧任务重新提交（换模型不复用旧装载）。
      if (_loadTaskModelId != null && _loadTaskModelId == target?.dirName) {
        return _awaitLoadTask();
      }
    }
    final gen = ++_loadGen; // 作废任何旧任务（含目标变更场景）
    _loadTaskModelId = target?.dirName;
    _loadTask = _runBackgroundLoad(target, gen).whenComplete(() {
      if (_loadGen == gen) {
        _loadTask = null;
        _loadTaskModelId = null;
      }
    });
    return _awaitLoadTask();
  }

  /// 有界等待当前装载任务（并发进入复用同一任务）。
  Future<EngineStatus> _awaitLoadTask() async {
    final task = _loadTask;
    if (task == null) return EngineStatus.ready; // 防御：任务已收口未重启
    try {
      final ok = await task.timeout(_loadWaitPerRequest);
      if (ok) return EngineStatus.ready;
      throw OnDeviceLoadException(_loadTaskError ?? '端侧加载失败');
    } on TimeoutException {
      // B-2 核心：请求侧超时 ≠ 装载失败——后台仍在分钟级退避重试。
      // 温控摘除（2026-10-31 用户裁决）：过热分叉随切云沿一并退役。
      throw OnDeviceLoadException(
          '端侧模型装载进行中（后台继续装载；内存紧张可清理后台应用），请稍后重试',
          retryable: true,
          degraded: false);
    }
  }

  /// B-2 后台装载任务：中断类失败按 [backoffs] 分钟级封顶退避无限重试
  /// （ColorOS mem-pressure 击杀装载窗口实证：23s 内三轮退避在算术上赢不了
  /// 持续回收）；终态失败收口 failed 并记录原因。[gen] = 发起代次，disable
  /// 作废旧任务（收口前检查，作废后静默退出不覆盖新状态）。
  ///
  /// 快死棘轮（2026-10-30 真机实证）：4B 装载 5s 内吃掉 ~5.4GB（分片页缓存
  /// + ION 瞬态叠加）触发系统级 OOM——进程死后内核释放内存，availMem 快速
  /// 回升越过普通水位闸 → 无脑重试 = 每 30~90s 撞一次内存墙，LMK 连累其他
  /// 应用被杀（坏公民）。连续 2 次快死（受理后 30s 内中断）后，重试水位抬到
  /// 5GB——等系统真实恢复（用户清后台/大应用退出）才再发起装载。
  Future<bool> _runBackgroundLoad(OnDeviceModelOption? model, int gen) async {
    _loadTaskError = null;
    const backoffs = [3500, 8000, 12000, 30000, 60000]; // 封顶后恒 120s
    var attempt = 0;
    var fastKillStreak = 0;
    while (true) {
      if (gen != _loadGen) return false; // 代次作废（disable/新任务接管）
      final attemptStartedAt = DateTime.now();
      try {
        await _binding.bind();
        final status =
            await _binding.waitReady(timeout: const Duration(seconds: 3));
        if (status == null) {
          // :engine 冷启动/重启中（实测 3~8s）——中断类，交后台退避重试。
          throw const OnDeviceLoadException('端侧引擎未就绪（:engine 连接超时）',
              retryable: true);
        }
      final resolvedModel = model ?? await OnDeviceModelSelection.read();
      final target = await OnDeviceAssetManager.instance
          .ensureAssets(model: resolvedModel);
      if (target == null) {
        throw const OnDeviceLoadException('端侧模型资产缺失或下载失败');
      }
      // M2 §2.5 I3：资产身份由资产面单点计算，随装载入参下发——:engine 票据
      // 回显此值，主进程对账「票据 modelId ≠ 目标」即知资产变更需重装。
      final modelId =
          await OnDeviceAssetManager.instance.modelIdOf(resolvedModel);
      // 装载起跑闸（用户方案 2026-10-30，覆盖首试+重试统一水位）：availMem
      // 不足以容纳一次装载（普通 4.5GB；快死 ≥2 次抬 5GB 防尖峰棘轮）就不
      // 发起，等系统真实恢复（用户清后台）——不硬拒绝，请求侧有界等待呈现
      // 装载中；护栏仍是兜底不是限制（拍板 2026-10-30 口径不变）。
      final retryWatermark = fastKillStreak >= 2
          ? kRetryHighWaterBytes
          : kLoadMinAvailRamBytes;
      // MemGate 可观测化（2026-10-30 步 0）：旧循环 60s 固定轮询且**零日志**
      // → 水位不满足时端侧「看起来在加载」实则从未起跑（排查黑洞）。每轮打印
      // avail / threshold / 已等待时长；退避 15s→30s→60s（别等满 60s 才试）。
      final gateStart = DateTime.now();
      var gateRound = 0;
      var gateBackoffMs = 15000;
      while (gen == _loadGen) {
        final probe = await ChannelLlmEngine().deviceProbe();
        final avail = probe?.availRamBytes;
        final availMb = avail == null ? -1 : avail >> 20;
        gateRound++;
        final waitedSec = DateTime.now().difference(gateStart).inSeconds;
        final decision = decideMemGate(
            availRamBytes: avail, threshold: retryWatermark);
        if (decision == MemGateDecision.go) {
          debugPrint('[MemGate] 起跑通过 avail=${availMb}MB '
              'threshold=${retryWatermark >> 20}MB round=$gateRound '
              'waited=${waitedSec}s');
          break;
        }
        if (decision == MemGateDecision.hardFail) {
          // 硬失败线（场景 C 降级线 0.9GB）：再等也不会满足起跑线，等待只会
          // 让用户干等 → 立即终态失败（终态语义 → 场景 C 显式失败，不切云）。
          debugPrint('[MemGate] 跌破硬失败线 avail=${availMb}MB '
              '< ${kLoadHardFailAvailRamBytes >> 20}MB → 放弃本轮装载');
          throw OnDeviceLoadException(memGateHardFailReason(avail));
        }
        debugPrint('[MemGate] 等待可用内存 avail=${availMb}MB '
            '< threshold=${retryWatermark >> 20}MB round=$gateRound '
            'waited=${waitedSec}s backoff=${gateBackoffMs}ms');
        await Future<void>.delayed(Duration(milliseconds: gateBackoffMs));
        if (gateBackoffMs < 60000) gateBackoffMs *= 2;
      }
      if (gen != _loadGen) return false;
      // 模型装载：loadModel「受理即返回 assetMissing」（AIDL 契约——受理
        // 态轮询见 [_loadAndWaitReady]）。
        final loaded = await _loadAndWaitReady(target.path, modelId: modelId);
        if (loaded != EngineStatus.ready && loaded != EngineStatus.busy) {
          // 终态失败文案白话化（禁把内部枚举名抛给用户——真机曾见
          // 「模型装载失败（circuitBroken）」，用户看不懂也无从行动）。
          throw OnDeviceLoadException(engineStatusFailureReason(loaded));
        }
        // 数据面消费 worker（原在 generate 内惰性启动，现收编进显式加载）：
        // 失败即「端侧加载失败」，对用户可见、不静默切云。
        await _binding.startDataWorker();
        // 装载收尾：归还模型分片页缓存（posix_fadvise DONTNEED，经主进程 native
        // 通道）——加速整机 MemAvailable 回到健康水位；**仅削装载后的稳态恢复，
        // 削不平装载瞬态尖峰**（边界见 native 侧注释）。
        try {
          await _channel.invokeMethod<void>('dropShardCache', target.path);
        } catch (e) {
          debugPrint('[DEGRADE] drop shard page cache: $e');
        }
        _loadState.value = OnDeviceLoadState.ready;
        // M1 影子对账（Expand：只留痕，不参与判定）。
        unawaited(_binding.reconcileTicket(OnDeviceLoadState.ready, 'post-load'));
        return true;
      } on OnDeviceLoadException catch (e) {
        if (!e.retryable || gen != _loadGen) {
          _loadTaskError = e.reason;
          _loadState.value = OnDeviceLoadState.failed;
          return false; // 终态失败 / 代次作废：任务收口，下次 enable 重新决策
        }
        // 中断类（进程被杀/未绑定/连接超时）：分钟级封顶退避后台持续重试
        //（B-2 核心：不随请求判死——23s 内三轮退避赢不过持续 mem-pressure）。
        final livedMs =
            DateTime.now().difference(attemptStartedAt).inMilliseconds;
        fastKillStreak = livedMs < 30000 ? fastKillStreak + 1 : 0;
        final delayMs = attempt < backoffs.length ? backoffs[attempt] : 120000;
        attempt++;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        //（起跑闸已统一覆盖重试水位，此处只做退避节流。）
      } catch (e) {
        // 非装载异常（资产/门禁/通道意外）：终态收口，错误如实带原因。
        _loadTaskError = e is OnDeviceLoadException ? e.reason : '端侧加载失败：$e';
        _loadState.value = OnDeviceLoadState.failed;
        return false;
      }
    }
  }

  /// 单轮装载受理 + 就绪轮询（原 enable 内联逻辑收编，[modelDir] 参数化）。
  /// 轮询状态机委托 [pollLoadReady]（纯逻辑件，可单测）：热降级（设备过热）
  /// **不判死**——继续等热回落。M4：probe 走**票据面**（checkSession），
  /// checkStatus 轮询面已退役；票据取不到 = 未知态按装载中继续轮（M4 受理态
  /// loading 继续轮询，assetMissing 回归终态如实上抛）。
  Future<EngineStatus> _loadAndWaitReady(String modelDir, {String? modelId}) async {
    final loaded = await loadModel(modelDir, modelId: modelId);
    if (loaded != EngineStatus.loading) return loaded;
    return pollLoadReady(probe: () async {
      try {
        final ticket = await _binding.fetchSessionTicket();
        // 票据缺失（超时/通道抖动）= 未知 → 按装载中继续轮（禁猜测终态）。
        return ticket?.status ?? EngineStatus.loading;
      } on PlatformException catch (e) {
        // 未知码 = 终态，如实带上 code 上抛（禁伪装成 unsupportedDevice）。
        throw _loadFailureOf(e.code);
      } on MissingPluginException {
        throw const OnDeviceLoadException(
            '引擎进程中断（系统回收或崩溃），请重试',
            retryable: true);
      }
    });
  }

  /// 卸载释放：停数据面 worker + 释放 :engine 权重内存，退回 unloaded（释放
  /// ~1.9GB 权重驻留，端侧重新回到「未启用」态）。
  Future<void> disable() async {
    try {
      _loadGen++; // 作废在途后台装载任务（B-2 代次沿）：收口前检查即静默退出
      await release();
    } finally {
      _loadState.value = OnDeviceLoadState.unloaded;
    }
  }

  final OnDeviceEngineBinding _binding;

  /// 重启风暴两级熔断 + 500ms 冷却窗口（on-device S1-6，NPU 稿 §6.5）。
  final EngineCircuitBreaker breaker;

  /// 过渡期 identity 字节表：:engine 写侧将文本块转 UTF-8 字节值入环
  ///（id = 字节值 0..255，identity 字节级编码）——本表即其重组映射，跨微批
  /// 的流式 UTF-8 无损重组由 [StreamingDetokenizer] 保证（§6.4）。正式
  /// tokenizer ID-to-Byte 表随 §4.5 OTA 资产（tokenizer.id2byte.bin）落地
  /// 替换（现 GenieX 管线载荷即文本块，identity 表语义无损）。
  late final TokenByteTable _identityTable = _buildIdentityTable();

  final _active = <String, _ActiveGenerate>{};

  @override
  Future<EngineStatus?> authoritativeStatus() =>
      _binding.fetchSessionTicket().then((t) => t?.status);

  @override
  Future<bool> isAvailable() async =>
      (await authoritativeStatus()) == EngineStatus.ready;

  /// 前台态判定（场景 A/B/C 切云语义拆分）：透传桥面 Activity started 计数；
  /// 探测失败按**后台**保守处理（场景 B 不切云、暂存等前台）。
  Future<bool> isForeground() => _binding.isForeground();

  @override
  Future<void> warmup() async {
    // S2 正式接线：bind + 等就绪事件（bind 时序竞态正式收口，取代固定
    // sleep）。超时仅 DEGRADE 留痕（端侧为可选通路；后续 generate 自有
    // 有界等待 + 快速失败，不依赖预热成功）。
    await _binding.bind();
    final status = await _binding.waitReady();
    if (status == null) {
      assert(() {
        // ignore: avoid_print
        print('[DEGRADE] on_device warmup: ready event timeout (10s)');
        return true;
      }());
    }
  }

  /// 模型装载（S2 正式接线）：`:engine` 后台线程创建 Genie 会话（幂等；
  /// 秒级暖机异步进行，返回后 checkStatus 轮转至 ready）。中断码
  /// （[kEngineInterruptCodes]：`not_bound` 未绑定 / `engine_binder_error`
  /// binder 尸体）= `:engine` 进程中断（系统内存压力回收/OOM 崩溃，实测
  /// ColorOS 装载 4B 时静默 SIGKILL）→ 抛 [OnDeviceLoadException] 带可重试
  /// 语义（AMS 会自动重启 :engine 并重连）；其余远端异常 = 终态失败，
  /// **错误码如实入文案**——禁沿用 checkStatus 的 DEGRADE 口径返回
  /// unsupportedDevice（会把通道异常读成「硬件不支持」）。
  Future<EngineStatus> loadModel(String modelDir, {String? modelId}) async {
    try {
      final ordinal = await _channel.invokeMethod<int>('loadModel', {
        'modelDir': modelDir,
        'modelId': ?modelId,
      });
      return engineStatusFromOrdinal(ordinal ?? 5);
    } on PlatformException catch (e) {
      assert(() {
        // ignore: avoid_print
        print('[DEGRADE] on_device loadModel: ${e.code}');
        return true;
      }());
      throw _loadFailureOf(e.code);
    } on MissingPluginException {
      // 桥面未挂载（进程早于 Activity 注册）≠ 设备不支持：如实上抛。
      throw _loadFailureOf('channel_not_registered');
    }
  }

  @override
  Stream<EngineChunk> generate({
    required String requestId,
    required String prompt,
    GenerationConfig config = const GenerationConfig(),
  }) {
    // 同 requestId 重入防御（总纲 §2 流生命周期）：旧流未关即复用属误用。
    if (_active.containsKey(requestId)) {
      throw StateError('generate: requestId $requestId already active');
    }
    final ctrl = StreamController<EngineChunk>(onCancel: () => cancel(requestId));
    // 解码自愈接线：坏字节（字节流错位）会让 utf8 chunked 解码器进入持续失败
    // 态——一次失败后每个后续字节都抛 FormatException（真机 S2-5 实证 78189 条
    // 异常洪泛 → 主进程 136% CPU → ANR 冻结）。detok 侧单字节失败即重建解码器
    // 并继续；此处只做**一次性**留痕（禁逐字节打印 = 洪泛源）。
    late final StreamingDetokenizer detok;
    // 每流字节/字符对账（2026-10-31 真机「第二轮无输出」）：bytesIn（解码器
    // 实收字节）vs charsOut（deltaText 累计字符）vs decodeErrors，收口打点
    // 三值一分——丢失点夹逼在「:engine 投递 / Dart 解码 / 上游归因」之一。
    _ActiveGenerate? self;
    detok = StreamingDetokenizer(
      table: _identityTable,
      onText: (delta) {
        self?.charsOut += delta.length;
        if (!ctrl.isClosed) ctrl.add(EngineChunk(deltaText: delta));
      },
      onDecodeError: (error, id) {
        if (detok.decodeErrors == 1) {
          debugPrint(
              '[DEGRADE] on_device decode error (stream self-healed): $error');
        }
      },
    );
    // §6.5 闸门：熔断期（L1/L2）或 500ms 驱动释放冷却期内，本地路径直接以
    // EngineDiedException 快速失败——调用方（混合引擎）捕获即无缝切云，
    // 冷却窗口内绝不重初始化撞 FastRPC 僵尸通道。（检查在异步体内执行：
    // generate 保持同步签名返回流。）
    final entry = _ActiveGenerate(requestId, ctrl, detok);
    self = entry;
    _active[requestId] = entry;
    Future<void>(() async {
      // 温控摘除（2026-10-31 用户裁决）：热闸前置检查随切云沿一并退役，
      // 极端发热交 OEM 自身限频保护。
      if (await breaker.isBroken || breaker.inCooldown) {
        _active.remove(requestId);
        ctrl.addError(const EngineDiedException('circuit breaker / cooldown active'));
        await ctrl.close();
        return;
      }
      try {
        await _binding.bind(); // 幂等：已绑定 no-op
        // bind 竞态收口（超时 3s 快速失败切云；否则 not_bound 被误判驳回）。
        final status =
            await _binding.waitReady(timeout: const Duration(seconds: 3));
        // 会话闸门（M2 第一刀，设计 §2.3）：**票据未就绪 / 未连接即交装载链路**
        // ——取代「loadState 说 ready 就跳过装载」与「bind 超时即判死」两条
        // 推断口径（2026-10-31 两类真机事故的同源解药：拿不到票据 = 未知）。
        final gate = await ensureSessionReadyForGenerate(
            fetch: _binding.fetchSessionTicket,
            load: enable,
            connected: status != null);
        if (gate != null) {
          _active.remove(requestId);
          ctrl.addError(gate);
          await ctrl.close();
          return;
        }
        // S3-6 数据面 worker：enable() 已收编首次加载的启动，此处幂等兜底；
        // 运行期失联转 EngineDiedException 切云（S1-5），不计熔断（§6.3/§6.5）。
        try {
          await _binding.startDataWorker();
        } on PlatformException catch (e) {
          _active.remove(requestId);
          ctrl.addError(EngineDiedException(
              'data worker start failed: ${e.code} (${e.message})'));
          await ctrl.close();
          return;
        }
        // S3-2 FGS 前台预挂（§6.2 v2.7）：长生成发起时预挂 dataSync FGS
        // （Android 12+ 后台 startForeground 必抛，主进程侧作前台闸）。
        // 失败/后台跳过不阻断生成（DEGRADE：仅损失 OEM 冻结防御强度）。
        if (config.maxTokens >= kFgsPromoteMinTokens) {
          try {
            await _channel.invokeMethod<void>('promoteForeground');
          } on PlatformException catch (e) {
            debugPrint('[DEGRADE] on_device promoteForeground: ${e.code}');
          }
        }
        // M3 原子自证（设计 §2.3 I4）：闸门放行后取**最近见证票据**作 expect
        // epoch 随请求下发——`:engine` 单入口内原子比对，拒绝走 SESSION_* 分码
        //（作废镜像 → 装载 → 重试一次），不再「先查后发」两步裸奔。
        var ticket = await _binding.fetchSessionTicket();
        const maxAcceptAttempts = 2; // 初试 + 分码收敛重试各一次（禁无限循环）
        for (var attempt = 1; attempt <= maxAcceptAttempts; attempt++) {
          try {
            // §2.9 有界超时：进程冻结（假死）下同步 AIDL 调用可能长时间不返回
            // 且无 DeadObject——受理调用 10s 上界（正常 <1s），超时按可自愈中断
            // 切云（禁把异步体挂死、请求侧零响应）。
            await _channel.invokeMethod<void>('startGenerate', {
              'requestId': requestId,
              'promptJson': prompt,
              'maxTokens': config.maxTokens,
              'temperature': config.temperature,
              'topP': config.topP,
              'stopTokenIds': config.stopTokenIds.toList(),
              // 票据缺失（通道异常等）= 未知态：发空 epoch 让 :engine 权威拒绝
              //（禁本地猜测放行——I2）。
              'expectInstanceId': ticket?.instanceId ?? '',
              'expectSeq': ticket?.seq ?? -1,
            }).timeout(const Duration(seconds: 10));
            break; // 受理成功
          } on PlatformException catch (e) {
            final retryable = e.code == 'session_epoch_mismatch' ||
                e.code == 'session_loading';
            if (!retryable || attempt == maxAcceptAttempts) rethrow;
            // 分码收敛（设计 §2.2 拒绝处置表）：作废镜像（置未知，非猜测）
            // → 交装载链路（内含 bind/退避/单飞）→ 复取票据重试一次。
            debugPrint('[on-device] startGenerate ${e.code} @attempt$attempt '
                '→ invalidate mirror + reload + retry once');
            _binding.sessionMirror.invalidate();
            _loadState.value = OnDeviceLoadState.unloaded;
            final st = await enable();
            if (st != EngineStatus.ready && st != EngineStatus.busy) {
              // 装载后仍非就绪：enable 的错误面已把真因带给下一轮请求；
              // 本轮按可自愈中断收口切云（禁挂死）。
              throw OnDeviceLoadException(
                  '重试装载后仍非就绪（${st.name}）', retryable: true);
            }
            ticket = await _binding.fetchSessionTicket();
          }
        }
        // 无进展看门狗（受理即武装）：长期无字节 = 数据面失联 → 切云（禁挂死）。
        _armWatchdog(requestId);
        unawaited(_binding.reconcileTicket(_loadState.value, 'generate'));
      } on PlatformException catch (e) {
        _active.remove(requestId);
        if (e.code == 'service_busy') {
          // S3-3 策略 B（§6.6）：槽被占且不可授予（后台忙驳回/前台抢占超时）
          // → 快速失败，混合引擎捕获即无缝切云（§6.6「冲突时原子抛
          // ServiceBusyException，上层捕获瞬间切云」）。busy 是瞬时槽占用
          // 非引擎故障——EngineDiedException 在此仅作切云信号复用，无任何
          // breaker.report 调用，不进熔断口径。
          ctrl.addError(
              const EngineDiedException('service busy (strategy B) → cloud fallback'));
        } else if (e.code == 'session_epoch_mismatch' ||
            e.code == 'session_loading') {
          // M3 收口（设计 §2.2）：重试一次后仍撞分码 = 权威持续说「不可受理」
          // ——作废镜像（置未知，非猜测复位），按可自愈中断切云完成本轮；
          // 真因已由 :engine 侧 loadError / 票据承载，禁再当用户可见的
          // StateError 裸抛（2026-10-31 start_rejected 事故的退役点）。
          _binding.sessionMirror.invalidate();
          _loadState.value = OnDeviceLoadState.unloaded;
          ctrl.addError(EngineDiedException(
              'session rejected after retry (${e.code}) → cloud fallback'));
        } else {
          // 其余拒绝（数据面未建等）：如实上抛由上层显式报错。
          ctrl.addError(StateError('startGenerate rejected: ${e.code} ${e.message}'));
        }
        await ctrl.close();
      } on TimeoutException catch (e) {
        // §2.9：受理调用 10s 超时 = :engine 冻结/假死（无 DeadObject 同族）
        // ——作废镜像 + 可自愈中断切云完成本轮（禁挂死、禁判死引擎硬件）。
        _active.remove(requestId);
        _binding.sessionMirror.invalidate();
        _loadState.value = OnDeviceLoadState.unloaded;
        ctrl.addError(EngineDiedException('control-plane timeout ($e) → cloud fallback'));
        await ctrl.close();
      }
    });
    return ctrl.stream;
  }

  /// S2-5 熔断全链验证诊断面（PATCH：验证收口后退役）：经 AIDL 触发
  /// `:engine` 模拟驱动 Panic（oneway）——真实信号链 onEngineDied →
  /// [breaker].report(countable:true)，不要求真机炸真实驱动。
  Future<void> diagPanic() async {
    try {
      await _channel.invokeMethod<void>('diagPanic');
    } on PlatformException catch (e) {
      assert(() {
        // ignore: avoid_print
        print('[DEGRADE] on_device diagPanic: ${e.code}');
        return true;
      }());
    }
  }

  /// 熔断器状态观测（诊断用）：isBroken / inCooldown 快照。
  Future<String> diagBreakerState() async =>
      'broken=${await breaker.isBroken} cooldown=${breaker.inCooldown}';

  @override
  Future<void> cancel(String requestId) async {
    // 流取消即订阅死亡（onCancel 透传）：立即移除 _active——否则 onFinished
    // 一旦丢失，stale 条目会持续接收后续批次（§6.6 单执行槽恒 1 被打破），
    // 其解码器先抛异常将中断 _onDataBatch 的 forEach、饿死活流（S2-5 实证）。
    final removed = _active.remove(requestId);
    removed?.watchdog?.cancel();
    try {
      await _channel.invokeMethod<void>('cancelGenerate', requestId);
    } on PlatformException catch (e) {
      // 取消失败不静默——`:engine` 会以 cancelled 收尾兜底（§6.3），此处留痕。
      assert(() {
        // ignore: avoid_print
        print('[DEGRADE] on_device cancel: ${e.code}');
        return true;
      }());
    }
  }

  @override
  Future<void> truncateContext({int keepTokens = 0}) async {
    try {
      await _channel.invokeMethod<void>('truncateContext', keepTokens);
    } on PlatformException catch (e) {
      assert(() {
        // ignore: avoid_print
        print('[DEGRADE] on_device truncateContext: ${e.code}');
        return true;
      }());
    }
  }

  @override
  Future<void> release() async {
    try {
      // S3-6：release 前先停数据面消费 worker（fd/映射属 :engine 数据面，
      // 桥面 unbind 亦收口，此处收 Dart 侧端口）。
      await _binding.stopDataWorker();
      await _channel.invokeMethod<void>('releaseEngine');
    } on PlatformException catch (e) {
      // 释放失败不静默（§4.2 非数据面降级：权重后续仍随 unbind/:engine
      // 进程死亡回收，不丢用户数据，但通道异常须留痕供排查）。
      debugPrint('[DEGRADE] on_device release: ${e.code}');
    } on MissingPluginException catch (e) {
      // 桥面 handler 未挂载（进程早于 Activity 注册桥等时序）；同上，留痕不阻断。
      debugPrint('[DEGRADE] on_device release: ${e.message}');
    } finally {
      await _binding.unbind();
      // 权重释放即端侧回到未启用态（loadModel 须经显式 enable 重新装载）。
      _loadState.value = OnDeviceLoadState.unloaded;
    }
  }

  /// 数据面微批入口（native worker → NativePort，S3-6 §6.4）：单执行槽下
  /// 同刻至多一个活跃生成（§6.6），喂给全部活跃流（幂等防御同旧口径）。
  void handleDataBatch(Uint8List batch) => _onDataBatch(batch);

  final int _batchDiagCount = 0;
  int _recvBytes = 0;
  bool _recvDiagDone = false;

  void _onDataBatch(Uint8List batch) {
    // EOS 流终结帧（§6.1 v3.1）：空批 = 本代生成数据流终——**Dart 流生命
    // 周期唯一事实源 = EOS**，即刻无条件收口（收尾事件仅作控制面通知，不
    // 参与流的开关；跨信道时序同步整体不做，S3-7 修订砍掉 2s 兜底定时器）。
    if (batch.isEmpty) return _onEos();
    _recvBytes += batch.length;
    // 字节活体 → 重置无进展看门狗（生成期字节每 ~40ms 一批；连续无字节 =
    // 数据面失联 → 切云）。
    for (final active in _active.values) {
      _armWatchdog(active.requestId);
    }
    // 诊断打点（S2-5 字节流腐化排查）：批次到达时的活跃流集合——§6.6 单执行
    // 槽下恒应为 1，>1 即 stale 流残留（cancel 未清 _active / onFinished 丢失），
    // stale 解码器先抛异常会中断 forEach 饿死活流。
    if (_batchDiagCount < 6 && _active.length != 1) {
      // ignore: avoid_print
      print('[diag] batch #$_batchDiagCount actives=${_active.keys.toList()} '
          'len=${batch.length} head=${batch.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    }
    for (final active in _active.values) {
      active.bytesIn += batch.length;
      try {
        // 解码自愈在 detok 内闭环（单字节失败即重建解码器并继续）——此处
        // catch 仅作防御：单流解码失败不得中断其余活跃流（stale 流残留时
        // 活流会被饿死）。
        active.detok.addTokens(batch);
      } catch (e) {
        // **catch 面扩到全部异常**：只捕 FormatException 时，其他异常（如
        // 「流已关闭后再投喂」的 StateError）会穿透本循环 → 穿透 ReceivePort
        // 的 listener → **整条数据面投递链就此饿死**（后续轮次永远收不到
        // 字节 = 「没有输出」）。首次失败打对账包：累计接收字节数 + 失败批
        // 前的 48B 现场——与写侧「flushed cum=NB」对账，区分「投递丢字节」
        // 与「解码器状态」。
        if (!_recvDiagDone) {
          _recvDiagDone = true;
          // ignore: avoid_print
          print('[diag] first decode fail recvCum=$_recvBytes B head='
              '${batch.take(48).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} $e');
        }
      }
    }
  }

  void _onIpcDeadlock() {
    // §6.3 IPC 死锁切云沿：:engine 判定消费端失速（ring 写超时 500ms）已
    // abort 在途 + 清空 RingBuffer。消费端失速属环境事件非本端 Bug——
    // 不计熔断（无 breaker.report），活跃流以 EngineDiedException 收口
    // 切云，绝不空转占硬件。
    _failAllActive(
        const EngineDiedException('ipc deadlock (consumer stalled) → cloud fallback'));
  }

  /// EOS 收口（§6.1 v3.1，S3-7 修订单一事实源）：EOS 到达即**无条件收口**
  /// 活跃流（pendingFinishReason 若控制面先到则取之，否则按 stop）——数据
  /// 流生命周期唯一事实源 = EOS，不等待控制面收尾事件。
  void _onEos() {
    for (final id in List.of(_active.keys)) {
      final active = _active.remove(id)!;
      _closeWithFinish(active, active.pendingFinishReason ?? EngineFinishReason.stop);
    }
  }

  /// 数据面 EOF（S3-7 修订）：native worker 读到对端关闭（:engine 数据面
  /// 死亡）即刻上抛——活跃流以 EngineDiedException 收口切云，不经看门狗
  /// 兜底（旧双沿门控的 2s 定时器猜测已整体退役）。
  void _onDataPlaneEof() {
    _failAllActive(const EngineDiedException(
        'data plane EOF (:engine 数据面关闭) → cloud fallback'));
  }

  void _onFinished(String requestId, int finishOrdinal) {
    // 控制面通知：仅记录 reason 供 EOS 收口取用（如控制面罕见先于 EOS 到达），
    // **不参与流的开关**（跨信道时序同步禁做，S3-7 修订）。流已被 EOS 收口
    // 时此处为 no-op。收尾丢失场景由数据面 EOF 信号 + 无进展看门狗双兜底。
    final active = _active[requestId];
    if (active == null) return;
    active.pendingFinishReason = engineFinishReasonFromOrdinal(finishOrdinal);
  }

  void _closeWithFinish(_ActiveGenerate active, EngineFinishReason reason) {
    active.watchdog?.cancel();
    active.watchdog = null;
    // 字节/字符收口对账（取证钉）：bytesIn/charsOut/decodeErrors 三值一分——
    // charsOut 与 bytesIn 不成正常 UTF-8 比例 → 解码层丢字节；bytesIn 本身
    // 偏小 → :engine 侧投递前已丢（sanitizer/im_end 截断）。
    debugPrint('[on_device] stream close accounting requestId=${active.requestId} '
        'bytesIn=${active.bytesIn} charsOut=${active.charsOut} '
        'decodeErrors=${active.detok.decodeErrors}');
    if (!active.ctrl.isClosed) {
      active.ctrl.add(EngineChunk(
        deltaText: '',
        finishReason: reason,
      ));
      active.ctrl.close();
    }
  }

  /// 无进展看门狗（端侧流唯一的超时兜底）：受理后连续 [noProgressTimeout]
  /// 无字节到达 → 判数据面失联 → 以 EngineDiedException 收口 → 混合引擎
  /// 无缝切云。**绝不让端侧流永挂**——永挂即本轮问答零响应（真机实证）。
  void _armWatchdog(String requestId) {
    final active = _active[requestId];
    if (active == null) return;
    active.watchdog?.cancel();
    active.watchdog = Timer(noProgressTimeout, () => _onNoProgress(requestId));
  }

  void _onNoProgress(String requestId) {
    final active = _active.remove(requestId);
    if (active == null) return;
    active.watchdog?.cancel();
    active.watchdog = null;
    debugPrint('[DEGRADE] on_device no progress ${noProgressTimeout.inMilliseconds}ms '
        '→ cloud fallback (requestId=$requestId)');
    if (!active.ctrl.isClosed) {
      active.ctrl.addError(EngineDiedException(
          '端侧数据面无进展（${noProgressTimeout.inMilliseconds}ms 无字节）→ cloud fallback'));
      active.ctrl.close();
    }
  }

  void _onDied() {
    // AIDL onEngineDied = 本端驱动 Panic / 算子越界 abort → 计入 L1/L2（§6.5）。
    unawaited(breaker.report(countable: true));
    _failAllActive(const EngineDiedException());
  }

  void _onProcessDied() {
    // 外部处决（SIGKILL/LMK）→ 不计入熔断，仅维护 500ms 冷却窗口（§6.5 v2.6）。
    unawaited(breaker.report(countable: false));
    // M2 投影作废（设计 §2.4 I2，替代原「事件复位」PATCH）：通道中断 = 票据
    // 不可信 → 镜像置未知（新进程 instanceId 必变，对账天然不命中）。
    _binding.sessionMirror.invalidate();
    _loadState.value = OnDeviceLoadState.unloaded;
    _failAllActive(const EngineDiedException('process killed externally'));
  }

  /// `:engine` **自发**驱逐上行（P0-3）：TTL / onTrimMemory / 内存护栏驱逐
  /// 与主动 release 四条路径均经 AIDL `onEngineEvicted` 汇入此处。
  ///
  /// 仅复位 `loadState`——不动 `_active`：在途生成由 `:engine` 侧 abort 后经
  /// `onGenerateFinished`（cancelled 收尾）收口，进程死亡路径另有
  /// `onProcessDied` 的 `_failAllActive`。此处纠正的是主进程侧「就绪说谎态」：
  /// 此前驱逐后 `loadState` 仍为 ready → `enable()` 幂等 no-op 不重装 →
  /// 下一次端侧请求必撞 `genie session not ready` / `data plane not
  /// initialized`，且错误文案呈现 `assetMissing`（立法语义=模型未下载）
  /// ——把「空闲 5 分钟后模型被正常回收」报成「模型没下载」，补救方向完全误导。
  void _onEngineEvicted(String reason) {
    // M2 投影作废（I2）：镜像已在 binding 事件入口 invalidate——此处仅复位
    // loadState 消费面。
    _loadState.value = OnDeviceLoadState.unloaded;
    debugPrint('[DEGRADE] on_device evicted: $reason'
        '（端侧回到未启用态，下次请求快速暖机重装，资产在盘不重下载）');
  }

  /// §2.8 I6：驱逐**打断了在途生成**（:engine 侧 slot 主 requestId 上行）。
  /// 该流以 SESSION_ABORTED_BY_EVICTION 语义收口——可重试/切云（区别于
  /// 进程死亡的 EngineDied 判死），不再靠数据面 EOF 间接收口（丢归因）。
  void _onEvictionInterrupted(String requestId) {
    final active = _active.remove(requestId);
    if (active == null) return; // 已被看门狗/EOF 收口
    active.watchdog?.cancel();
    debugPrint('[DEGRADE] on_device generation aborted by eviction: $requestId');
    if (!active.ctrl.isClosed) {
      active.ctrl.addError(const EngineDiedException(
          'SESSION_ABORTED_BY_EVICTION: engine evicted during generation'));
      active.ctrl.close();
    }
  }

  void _failAllActive(EngineDiedException error) {
    // 进程死亡：所有活跃流以 EngineDiedException 收口（调用方捕获即切云，
    // 绝不让主进程闪退——总纲 §2）。
    final entries = Map.of(_active);
    _active.clear();
    for (final active in entries.values) {
      active.watchdog?.cancel();
      active.watchdog = null;
      if (!active.ctrl.isClosed) {
        active.ctrl.addError(error);
        active.ctrl.close();
      }
    }
  }

  MethodChannel get _channel => OnDeviceEngineBinding.channel;

  static TokenByteTable _buildIdentityTable() {
    final b = TokenByteTableBuilder();
    for (var i = 0; i < 256; i++) {
      b.add(i, [i]);
    }
    return b.build();
  }
}

class _ActiveGenerate {
  _ActiveGenerate(this.requestId, this.ctrl, this.detok);

  final String requestId;
  final StreamController<EngineChunk> ctrl;
  final StreamingDetokenizer detok;

  /// 每流对账计数（取证钉）：bytesIn = 本流解码器实收字节；charsOut =
  /// deltaText 累计字符。收口打点三值一分定位丢字节环节。
  int bytesIn = 0;
  int charsOut = 0;

  /// 无进展看门狗（数据面失联兜底，见 [AidlOnDeviceEngine.kNoProgressTimeout]）。
  Timer? watchdog;

  /// 收尾事件（控制面）先于 EOS 到达时暂记的 finishReason——EOS 收口时
  /// 取用（S3-7 修订：流开关唯一事实源 = EOS，本字段不参与开关）。
  EngineFinishReason? pendingFinishReason;
}

/// 进程级唯一端侧引擎实例：MethodChannel handler 为进程级单槽
/// （setMethodCallHandler 后写覆盖），多实例将互踩回调（onDataBatch 等
/// 事件只投递给最后注册的 binding）——装配层（hybrid_assembly）与启动
/// 引导（main）共享本件，严禁再 new 第二个。
///
/// 挂进混合引擎的装配适配（`AidlOnDeviceLlmEngineAdapter`）见
/// `on_device_engine_adapter.dart`（2026-10-30 体量收口拆出）。
final AidlOnDeviceEngine sharedOnDeviceEngine = AidlOnDeviceEngine();
