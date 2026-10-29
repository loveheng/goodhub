import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'on_device_engine.dart';
import 'on_device_ready_gate.dart';

/// 端侧引擎绑定面（on-device epic S1-1 骨架，S2 正式接线扩展）。
///
/// Dart 侧对 `:engine` 独立进程的生命周期入口：经 MethodChannel
/// `goodhub/on_device_engine` 触发主进程侧 `EngineServiceBridge` 的
/// bind/unbind——主进程以 `BIND_AUTO_CREATE | BIND_IMPORTANT` 绑定
/// `:engine`（on-device-npu-deployment.md §6.2，oom_adj 与主应用同梯队）。
///
/// S2 正式接线：`readyGate`（[EngineReadyGate]）承接主进程 `onEngineReady`
/// 事件——bind 时序竞态（bind 返回 ≠ 已连接）的正式收口点，取代冒烟期
/// 固定 sleep。
class OnDeviceEngineBinding {
  /// 与 EngineServiceBridge.kt（Kotlin）对齐的唯一通道名。
  static const MethodChannel channel = MethodChannel('goodhub/on_device_engine');

  /// 就绪闸：onEngineReady / 死亡事件驱动（S2 正式接线）。
  final EngineReadyGate readyGate = EngineReadyGate();

  /// token 微批投递已随 S3-6 收编 native 数据面：:engine 写 Ashmem
  /// RingBuffer + pipe 唤醒，主进程 native worker（libgdw）经
  /// Dart_PostCObject_DL 直投本进程 [onDataBatch]（§6.1/§6.4）。
  /// startDataWorker/stopDataWorker 见同名方法；Binder onTokens 过渡通道
  /// 同轮退役（:engine 侧 AIDL Listener 已删该方法，禁双路）。
  ///
  /// S3-6 IPC 死锁切云沿（§6.3）：:engine 判定消费端失速（ring 写超时 500ms）
  /// 已 abort 在途 + 清空在途——按 EngineDiedException 切云（不计熔断）。
  void Function()? onIpcDeadlock;

  /// 数据面微批接收（S3-6，§6.4）：native worker 经 Dart_PostCObject_DL 投
  /// Uint8List（Dart_CObject_kTypedData 复制语义），载荷 = UTF-8 字节值
  ///（identity 字节级编码，与 Kotlin 写侧契约对齐）。仅在 worker 运行期到达。
  void Function(Uint8List batch)? onDataBatch;

  /// 生成收尾回调（finishReason 0=stop / 1=cancelled）。
  void Function(String requestId, int finishReason)? onGenerateFinished;

  /// `:engine` 驱动 Panic / 算子越界 abort（AIDL onEngineDied，计入熔断 §6.5）。
  void Function()? onEngineDied;

  /// `:engine` 进程外部处决（ServiceDisconnected：OEM SIGKILL / LMK，不计入
  /// 熔断但维护冷却窗口 §6.5 v2.6）。
  void Function()? onProcessDied;

  /// S3-1 热切云沿（:engine thermal listener 权威，NPU 稿 §5.2/§5.3）：
  /// true = 热状态 ≥ SEVERE 全量切云；false = 回落 MODERATE 及以下端侧恢复。
  void Function(bool active)? onThermalCutover;

  OnDeviceEngineBinding() {
    // handler 注册不在此处：纯 Dart 测试环境（无 WidgetsFlutterBinding）构造
    // 即触发 setMethodCallHandler 断言。延迟到首次 [bind]（见 _ensureHandler）
    // ——所有事件（onIpcDeadlock/onEngineReady…）本就只在 bind 后到达，语义无损。
  }

  /// 事件回调注册（幂等）：首次 bind 时挂接。
  void _ensureHandler() {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onEngineDied':
          // 致命事件作废就绪态（后续 waitReady 须等新事件，禁以过期态放行）。
          readyGate.noteGone();
          onEngineDied?.call();
        case 'onProcessDied':
          readyGate.noteGone();
          onProcessDied?.call();
        case 'onThermalCutover':
          onThermalCutover?.call(call.arguments as bool? ?? false);
        case 'onIpcDeadlock':
          onIpcDeadlock?.call();
        case 'onGenerateFinished':
          final args = call.arguments as Map;
          onGenerateFinished?.call(
            args['requestId'] as String? ?? '',
            args['finishReason'] as int? ?? 0,
          );
        case 'onEngineReady':
          readyGate.noteReady((call.arguments as int?) ?? 5);
      }
      return null;
    });
  }

  /// 等待 `:engine` 控制面就绪（S2 正式接线）。
  ///
  /// 已就绪即时返回记录态；未就绪挂起至 [timeout]——超时返回 null，调用方
  /// 按不可用快速失败（warmup 留 DEGRADE 痕；generate 以 StateError 切云）。
  Future<EngineStatus?> waitReady({
    Duration timeout = const Duration(seconds: 10),
  }) =>
      readyGate.waitReady(timeout: timeout);

  /// 绑定 `:engine` 独立进程（幂等：已绑定时为 no-op）。
  ///
  /// 失败不抛——端侧为可选加速路径，调用方（`HybridCloudEngine` 路由）
  /// 以云端为默认通路，绑定失败仅意味着端侧本轮不可用（DEGRADE 语义）。
  Future<void> bind() async {
    _ensureHandler();
    try {
      await channel.invokeMethod<void>('bind');
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[DEGRADE] on_device_engine bind: $e');
    }
  }

  /// 解绑 `:engine`（未绑定时 no-op）。
  Future<void> unbind() async {
    try {
      await channel.invokeMethod<void>('unbind');
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[DEGRADE] on_device_engine unbind: $e');
    }
  }

  // ---- 数据面消费 worker（S3-6，NPU 稿 §6.4）----

  ReceivePort? _dataPort;
  StreamSubscription<dynamic>? _dataSubscription;

  /// 启动数据面消费 worker：经 MethodChannel 将 NativePort +
  /// `NativeApi.initializeApiDLData` 指针 + RingBuffer 容量传主进程桥面——
  /// Kotlin 侧经 JNI 驱动 libgdw（epoll 等待 pipe 唤醒 + 只读映射 Ashmem
  /// RingBuffer + `Dart_PostCObject_DL` 微批投递 [onDataBatch]）。
  ///
  /// 幂等：本侧 ReceivePort 单实例复用；桥面已运行时 no-op。失败抛
  /// PlatformException 由调用方决策（generate 路径快速失败切云——数据面
  /// 缺失即无产出，禁静默降级为空流）。
  ///
  /// [capacity] 须与 `TokenRingBuffer.DEFAULT_CAPACITY`（1024）一致：native
  /// 侧寻址掩码与 :engine 写侧共用同一容量，错配 = 载荷错乱。
  Future<void> startDataWorker({int capacity = 1024}) async {
    _ensureDataPort();
    await channel.invokeMethod<void>('startDataWorker', {
      'port': _dataPort!.sendPort.nativePort,
      'api': NativeApi.initializeApiDLData.address,
      'capacity': capacity,
    });
  }

  /// 停止数据面消费 worker（release/unbind 前置；幂等）：关闭本侧端口 +
  /// 透传桥面（停线程、释放映射与 fd）。
  Future<void> stopDataWorker() async {
    await _dataSubscription?.cancel();
    _dataSubscription = null;
    _dataPort?.close();
    _dataPort = null;
    try {
      await channel.invokeMethod<void>('stopDataWorker');
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[DEGRADE] on_device_engine stopDataWorker: $e');
    }
  }

  void _ensureDataPort() {
    if (_dataPort != null) return;
    final port = ReceivePort();
    _dataPort = port;
    _dataSubscription = port.listen((message) {
      if (message is Uint8List) onDataBatch?.call(message);
    });
  }
}
