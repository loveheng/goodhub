import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'llm.dart';
import 'on_device_asset_manager.dart';
import 'on_device_circuit_breaker.dart';
import 'on_device_detokenizer.dart';
import 'on_device_engine.dart';
import 'on_device_engine_binding.dart';
import 'on_device_model_catalog.dart';
import 'on_device_thermal_gate.dart';

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

/// 装载时刻可用 RAM 门槛（S2-5 实测）：4B@W4A16 装载峰值 HWM ~3.2GB + 运行时
/// 余量——低于此值装载大概率被系统 mem-pressure 击杀（04:23 实证），显式报
/// 「内存不足」引导清后台，不白跑一趟。
const int kLoadMinAvailRamBytes = 3584 << 20; // 3.5GB

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
  AidlOnDeviceEngine({OnDeviceEngineBinding? binding, EngineCircuitBreaker? breaker})
      : _binding = binding ?? OnDeviceEngineBinding(),
        breaker = breaker ?? EngineCircuitBreaker() {
    _binding.onDataBatch = _onDataBatch;
    _binding.onIpcDeadlock = _onIpcDeadlock;
    _binding.onGenerateFinished = _onFinished;
    _binding.onEngineDied = _onDied;
    _binding.onProcessDied = _onProcessDied;
    _binding.onThermalCutover = (active) => thermalGate.setCutoff(active: active);
  }

  /// 显式加载状态（懒加载兜底：启动 unloaded；首次命中端侧路径经 [enable]
  /// 转 loading→ready；失败转 failed）。UI 据此呈现「端侧模型加载中…」指示。
  final ValueNotifier<OnDeviceLoadState> _loadState =
      ValueNotifier<OnDeviceLoadState>(OnDeviceLoadState.unloaded);

  /// 加载状态可观察面（[OnDeviceEnableCapable]）。
  ValueListenable<OnDeviceLoadState> get loadState => _loadState;

  /// 显式加载端侧引擎（懒加载兜底：首次命中端侧路径由 [HybridCloudEngine]
  /// 触发）。bind→就绪→资产→loadModel→数据面 worker 串成可见加载过程；任一
  /// 环节失败抛 [OnDeviceLoadException]（带原因），**不静默切云**——失败对用户
  /// 可见。幂等：ready 后 no-op；loading 并发进入复用同一轮加载。
  Future<EngineStatus> enable({OnDeviceModelOption? model}) async {
    if (_loadState.value == OnDeviceLoadState.ready) return EngineStatus.ready;
    if (_loadState.value == OnDeviceLoadState.loading) {
      // 并发进入：等当前轮加载收口（Dart 单线程下极少触发）。
      while (_loadState.value == OnDeviceLoadState.loading) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_loadState.value == OnDeviceLoadState.ready) return EngineStatus.ready;
      // 已 failed：让调用方重新决策（或重新抛其携带原因）。
    }
    _loadState.value = OnDeviceLoadState.loading;
    try {
      await _binding.bind();
      final status =
          await _binding.waitReady(timeout: const Duration(seconds: 3));
      if (status == null) {
        throw const OnDeviceLoadException('端侧引擎未就绪（:engine 连接超时）');
      }
      final target = await OnDeviceAssetManager.instance
          .ensureAssets(model: model ?? await OnDeviceModelSelection.read());
      if (target == null) {
        throw const OnDeviceLoadException('端侧模型资产缺失或下载失败');
      }
      // 装载时刻内存门禁（S2-5 实测补充）：4B@W4A16 装载峰值 HWM ~3.2GB，
      // 门禁的 2.5GB 门槛在「探针时刻通过、装载时刻被系统杀」的时间窗下失义
      // （04:23 实证：mem-pressure-event 连环杀）。装载前再查一次可用 RAM。
      final probe = await ChannelLlmEngine().deviceProbe();
      final avail = probe?.availRamBytes;
      if (avail != null && avail < kLoadMinAvailRamBytes) {
        throw OnDeviceLoadException(
            '系统可用内存不足（${avail >> 20}MB < ${kLoadMinAvailRamBytes >> 20}MB），'
            '请清理后台应用后重试');
      }
      // 模型装载：loadModel「受理即返回 assetMissing」（AIDL 契约——:engine
      // 后台线程异步创建 Genie 会话，S2-1 实测暖机 ~2.7s）→ 轮询 checkStatus
      // 等 ready，绝不能把受理态误判为装载失败；上限 60s 兜底暖机抖动。
      // 进程中断（[kEngineInterruptCodes]，系统内存压力回收/OOM）自动重试：
      // AMS 会自动重启 :engine 并重连（实测 ~3s）——三轮递增退避（3.5s/8s/
      // 12s），首次装载撞杀不直接判死。**仅中断码重试**：终态失败（未知
      // 错误码 / 真 unsupportedDevice）立即如实上抛，不白等 23s。
      Future<EngineStatus> loadAndWaitReady() async {
        var loaded = await loadModel(target.path);
        if (loaded == EngineStatus.assetMissing) {
          final deadline = DateTime.now().add(const Duration(seconds: 60));
          while (loaded == EngineStatus.assetMissing &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            // 轮询期 :engine 进程可能被系统杀（实测装载中静默 SIGKILL）——
            // 直查通道分辨中断码（可重试），严禁走 checkStatus 的「异常折算
            // unsupportedDevice」口径（会把中断误报成不支持）。
            try {
              final ordinal = await _channel.invokeMethod<int>('checkStatus');
              loaded = engineStatusFromOrdinal(ordinal ?? 5);
            } on PlatformException catch (e) {
              // 未知码 = 终态，如实带上 code 上抛（禁伪装成 unsupportedDevice）。
              throw _loadFailureOf(e.code);
            } on MissingPluginException {
              throw const OnDeviceLoadException(
                  '引擎进程中断（系统回收或崩溃），请重试',
                  retryable: true);
            }
          }
        }
        return loaded;
      }

      EngineStatus loaded;
      const backoffs = [3500, 8000, 12000]; // 引擎重启重连实测 ~3s，逐轮放宽
      var attempt = 0;
      while (true) {
        try {
          loaded = await loadAndWaitReady();
          break;
        } on OnDeviceLoadException catch (e) {
          if (!e.retryable || attempt >= backoffs.length) {
            rethrow; // 终态失败 / 三轮仍中断，如实上抛
          }
          // 等引擎进程重启重连后重试（仍中断则继续退避）。
          await Future<void>.delayed(Duration(milliseconds: backoffs[attempt]));
          attempt++;
          await _binding.bind();
        }
      }
      if (loaded != EngineStatus.ready && loaded != EngineStatus.busy) {
        throw OnDeviceLoadException('模型装载失败（${loaded.name}）');
      }
      // 数据面消费 worker（原在 generate 内惰性启动，现收编进显式加载）：
      // 失败即「端侧加载失败」，对用户可见、不静默切云。
      await _binding.startDataWorker();
      _loadState.value = OnDeviceLoadState.ready;
      return EngineStatus.ready;
    } catch (e) {
      final reason = e is OnDeviceLoadException
          ? e.reason
          : '端侧加载失败：$e';
      _loadState.value = OnDeviceLoadState.failed;
      throw OnDeviceLoadException(reason);
    }
  }

  /// 卸载释放：停数据面 worker + 释放 :engine 权重内存，退回 unloaded（释放
  /// ~1.9GB 权重驻留，端侧重新回到「未启用」态）。
  Future<void> disable() async {
    try {
      await release();
    } finally {
      _loadState.value = OnDeviceLoadState.unloaded;
    }
  }

  final OnDeviceEngineBinding _binding;

  /// 重启风暴两级熔断 + 500ms 冷却窗口（on-device S1-6，NPU 稿 §6.5）。
  final EngineCircuitBreaker breaker;

  /// 热切云闸门（on-device S3-1，NPU 稿 §5.2/§5.3）：热状态 ≥ SEVERE 时
  /// generate 快速失败切云；环境降级语义——不计熔断、无冷却窗口、热回落
  /// 自然恢复（状态权威在 :engine，AIDL onThermalCutover 驱动）。
  final EngineThermalGate thermalGate = EngineThermalGate();

  /// 过渡期 identity 字节表：:engine 写侧将文本块转 UTF-8 字节值入环
  ///（id = 字节值 0..255，identity 字节级编码）——本表即其重组映射，跨微批
  /// 的流式 UTF-8 无损重组由 [StreamingDetokenizer] 保证（§6.4）。正式
  /// tokenizer ID-to-Byte 表随 §4.5 OTA 资产（tokenizer.id2byte.bin）落地
  /// 替换（现 GenieX 管线载荷即文本块，identity 表语义无损）。
  late final TokenByteTable _identityTable = _buildIdentityTable();

  final _active = <String, _ActiveGenerate>{};

  @override
  Future<EngineStatus> checkStatus() async {
    try {
      final ordinal = await _channel.invokeMethod<int>('checkStatus');
      return engineStatusFromOrdinal(ordinal ?? 5);
    } on MissingPluginException catch (e) {
      // 通道 handler 未挂载（进程早于 Activity 注册桥等时序）= 本轮端侧不可用，
      // 与 PlatformException 同口径收口——严禁穿透：门禁闭包 fail-closed 会把
      // 可用设备误关成「无可用推理引擎」。
      assert(() {
        // ignore: avoid_print
        print('[DEGRADE] on_device checkStatus: ${e.message}');
        return true;
      }());
      return EngineStatus.unsupportedDevice;
    } on PlatformException catch (e) {
      // 未绑定/远端异常 = 本轮端侧不可用（非熔断口径，DEGRADE 语义）。
      assert(() {
        // ignore: avoid_print
        print('[DEGRADE] on_device checkStatus: ${e.code}');
        return true;
      }());
      return EngineStatus.unsupportedDevice;
    }
  }

  @override
  Future<bool> isAvailable() async => (await checkStatus()) == EngineStatus.ready;

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
  Future<EngineStatus> loadModel(String modelDir) async {
    try {
      final ordinal = await _channel.invokeMethod<int>('loadModel', modelDir);
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
    final detok = StreamingDetokenizer(
      table: _identityTable,
      onText: (delta) {
        if (!ctrl.isClosed) ctrl.add(EngineChunk(deltaText: delta));
      },
    );
    // §6.5 闸门：熔断期（L1/L2）或 500ms 驱动释放冷却期内，本地路径直接以
    // EngineDiedException 快速失败——调用方（混合引擎）捕获即无缝切云，
    // 冷却窗口内绝不重初始化撞 FastRPC 僵尸通道。（检查在异步体内执行：
    // generate 保持同步签名返回流。）
    _active[requestId] = _ActiveGenerate(ctrl, detok);
    Future<void>(() async {
      // S3-1 热闸（§5.2 Thermal→Cloud）：SEVERE 及以上快速失败切云（禁
      // CPU 分流）。置于熔断检查之前——环境降级是最外层判据，与 :engine
      // 侧 startGenerate 拒绝互为冗余（回调丢失的单点保险）。
      if (thermalGate.cutoffActive) {
        _active.remove(requestId);
        ctrl.addError(const EngineDiedException('thermal cutoff active (SEVERE+)'));
        await ctrl.close();
        return;
      }
      if (await breaker.isBroken || breaker.inCooldown) {
        _active.remove(requestId);
        ctrl.addError(const EngineDiedException('circuit breaker / cooldown active'));
        await ctrl.close();
        return;
      }
      try {
        await _binding.bind(); // 幂等：已绑定 no-op
        // S2 正式接线：startGenerate 前等就绪（bind 竞态正式收口——否则
        // not_bound 被折算为快速失败误判驳回；超时 3s 快速失败切云）。
        final status =
            await _binding.waitReady(timeout: const Duration(seconds: 3));
        if (status == null) {
          _active.remove(requestId);
          ctrl.addError(StateError('engine not ready (bind 3s 未连接)'));
          await ctrl.close();
          return;
        }
        // S3-6 数据面消费 worker：显式 enable() 已收编「首次加载」的 worker 启动
        // （加载中可见、失败抛 OnDeviceLoadException 显式报错、不静默切云）。此处
        // 仅做幂等兜底（enable 已建则在位 no-op；:engine 死亡重建后由下次
        // enable 重跑）。运行期数据面失联（worker 启动失败）属引擎死亡类事件——仍
        // 转 EngineDiedException 由混合引擎无缝切云（S1-5），不计熔断（§6.3/§6.5）。
        try {
          await _binding.startDataWorker();
        } on PlatformException catch (e) {
          _active.remove(requestId);
          ctrl.addError(EngineDiedException(
              'data worker start failed: ${e.code} (${e.message})'));
          await ctrl.close();
          return;
        }
        // S3-2 FGS 前台预挂（NPU 稿 §6.2 v2.7）：长生成发起时于前台预挂
        // dataSync FGS（Android 12+ 后台 startForeground 必抛——主进程侧
        // 前台态判定作闸，此处仅请求）。失败/后台跳过均不阻断生成（DEGRADE：
        // 仅损失 OEM 冻结防御强度）。阈值口径见 EngineService.FGS_PROMOTE_MIN_MAX_TOKENS。
        if (config.maxTokens >= kFgsPromoteMinTokens) {
          try {
            await _channel.invokeMethod<void>('promoteForeground');
          } on PlatformException catch (e) {
            assert(() {
              // ignore: avoid_print
              print('[DEGRADE] on_device promoteForeground: ${e.code}');
              return true;
            }());
          }
        }
        await _channel.invokeMethod<void>('startGenerate', {
          'requestId': requestId,
          'promptJson': prompt,
          'maxTokens': config.maxTokens,
          'temperature': config.temperature,
          'topP': config.topP,
          'stopTokenIds': config.stopTokenIds.toList(),
        });
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
        } else {
          // 快速失败上抛（数据面未建等），调用方按 §6.6 捕获切云。
          ctrl.addError(StateError('startGenerate rejected: ${e.code} ${e.message}'));
        }
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
    _active.remove(requestId);
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
    if (batch.isEmpty) return;
    _recvBytes += batch.length;
    // 诊断打点（S2-5 字节流腐化排查）：批次到达时的活跃流集合——§6.6 单执行
    // 槽下恒应为 1，>1 即 stale 流残留（cancel 未清 _active / onFinished 丢失），
    // stale 解码器先抛异常会中断 forEach 饿死活流。
    if (_batchDiagCount < 6 && _active.length != 1) {
      // ignore: avoid_print
      print('[diag] batch #$_batchDiagCount actives=${_active.keys.toList()} '
          'len=${batch.length} head=${batch.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    }
    for (final active in _active.values) {
      try {
        active.detok.addTokens(batch);
      } on FormatException catch (e) {
        // 单流解码失败不得中断其余活跃流（stale 流残留时活流会被饿死）。
        // 首次失败打对账包：累计接收字节数 + 失败批前的 48B 现场——与写侧
        // 「flushed cum=NB」对账，区分「ring/投递丢字节」与「解码器状态」。
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

  void _onFinished(String requestId, int finishOrdinal) {
    final active = _active.remove(requestId);
    if (active == null) return;
    final reason = engineFinishReasonFromOrdinal(finishOrdinal);
    if (!active.ctrl.isClosed) {
      active.ctrl.add(EngineChunk(
        deltaText: '',
        finishReason: reason,
      ));
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
    _failAllActive(const EngineDiedException('process killed externally'));
  }

  void _failAllActive(EngineDiedException error) {
    // 进程死亡：所有活跃流以 EngineDiedException 收口（调用方捕获即切云，
    // 绝不让主进程闪退——总纲 §2）。
    final entries = Map.of(_active);
    _active.clear();
    for (final active in entries.values) {
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
  _ActiveGenerate(this.ctrl, this.detok);

  final StreamController<EngineChunk> ctrl;
  final StreamingDetokenizer detok;
}

/// 适配件：把总纲 §2 的 [OnDeviceEngine] 挂进既有 `HybridCloudEngine` 的
/// 端侧槽（`OnDeviceLlmEngine`，单发聚合语义——hybrid 只做单发提取）。
///
/// `EngineDiedException` 不在此吞：原样上抛给混合引擎的死亡兜底
/// （`_deviceSendWithDiedFallback`，S1-5），由其无缝切云。
class AidlOnDeviceLlmEngineAdapter
    implements OnDeviceLlmEngine, OnDeviceEnableCapable {
  AidlOnDeviceLlmEngineAdapter(this._inner);

  final AidlOnDeviceEngine _inner;
  String? _currentRequestId;

  @override
  String get name => '端侧引擎（:engine Genie）';

  @override
  Future<bool> get isAvailable => _inner.isAvailable();

  @override
  String? get unavailableReason => null;

  @override
  Future<String?> unavailableReasonAsync() async {
    final s = await _inner.checkStatus();
    return s == EngineStatus.ready ? null : '端侧引擎状态：${s.name}';
  }

  // ---- OnDeviceEnableCapable（显式加载）----

  @override
  ValueListenable<OnDeviceLoadState> get loadState => _inner.loadState;

  @override
  Future<EngineStatus> enable({OnDeviceModelOption? model}) =>
      _inner.enable(model: model);

  @override
  Future<void> disable() => _inner.disable();

  @override
  Future<String?> generate(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
  }) async {
    final requestId = 'aidl-${DateTime.now().microsecondsSinceEpoch}';
    _currentRequestId = requestId;
    try {
      final buf = StringBuffer();
      await for (final chunk in _inner.generate(
        requestId: requestId,
        prompt: system == null ? prompt : '$system\n\n$prompt',
        config: GenerationConfig(maxTokens: maxTokens),
      )) {
        buf.write(chunk.deltaText);
      }
      final text = buf.toString();
      return text.isEmpty ? null : text;
    } on EngineDiedException {
      rethrow; // 死亡兜底契约（S1-5）：原样上抛给混合引擎捕获切云，禁在此吞。
    } catch (e) {
      // OnDeviceLlmEngine 契约：生成失败返回 null（翻译式降级）——上层发
      // 「端侧生成失败」可观测报错（unavailableReasonAsync 带真值），
      // 不再让裸 StateError 穿透成错误卡。
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

/// 进程级唯一端侧引擎实例：MethodChannel handler 为进程级单槽
/// （setMethodCallHandler 后写覆盖），多实例将互踩回调（onDataBatch 等
/// 事件只投递给最后注册的 binding）——装配层（hybrid_assembly）与启动
/// 引导（main）共享本件，严禁再 new 第二个。
final AidlOnDeviceEngine sharedOnDeviceEngine = AidlOnDeviceEngine();
