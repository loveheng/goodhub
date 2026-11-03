import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'on_device_engine.dart';
import 'on_device_ready_gate.dart';
import 'on_device_session_ticket.dart';

/// 数据面帧类型（§6.1 v3.1 TLV，S02 常量单源）：与 C++ 侧
/// `engine_data_worker.cpp` 的 `kTypeToken=0x0001` / `kTypeEos=0x000F`、
/// Kotlin 侧 `SocketTokenWriter.FrameType` 三端同一字面量；Dart 消费点
/// 禁再写裸字面量（drift-registry CONST 行机械护栏）。
const int kDataPlaneFrameTokenChunk = 0x0001;
const int kDataPlaneFrameEos = 0x000F;

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

  /// 会话票据镜像（M1 Expand：仅见证 / 作废，**不参与判定**——判定切换归 M2）。
  final SessionMirror sessionMirror = SessionMirror();

  /// 就绪闸：onEngineReady / 死亡事件驱动（S2 正式接线）。
  final EngineReadyGate readyGate = EngineReadyGate();

  /// Hexagon 架构代际（73/75/79/81；null = 非高通/不支持，2026-11-02 三下载点
  /// 拍板的通道键）：导入面 NPU 包 arch 校验 / 增配通道键的 Dart 侧取用点。
  Future<int?> hexagonArch() async {
    try {
      return await channel.invokeMethod<int>('hexagonArch');
    } catch (e) {
      debugPrint('[DEGRADE] hexagonArch: $e');
      return null; // 未知 = 放行语义（与 deviceFingerprint 同口径）
    }
  }

  /// 会话票据查询（M1 Expand；设计 §2.2）：一次取回权威状态 + 代次 + 资产身份。
  /// 通道不可达抛 PlatformException 由调用方（影子对账）留痕，不静默造票据。
  ///
  /// §2.9 有界超时：进程冻结（假死，非杀死）下同步 AIDL 调用可能长时间不
  /// 返回且**没有** DeadObject——3s 超时按 null（未知态）收口，交装载链路
  /// 重新对账，禁把主进程挂死成 ANR。
  Future<SessionTicket?> fetchSessionTicket() async {
    try {
      return SessionTicket.tryParse(
          await channel.invokeMethod<Object?>('checkSession').timeout(
              const Duration(seconds: 3)));
    } on TimeoutException {
      debugPrint('[DEGRADE] checkSession timeout (3s, frozen?) → unknown');
      return null;
    }
  }

  /// M1 影子对账：取票据 → 见证 → 与调用方本地态对账 → 漂移留痕。
  ///
  /// **不阻断、不改判定**（Expand 阶段铁律：只让漂移可见可统计，M2 才切换
  /// 消费侧）。挂点 = 装载收尾与生成受理后（覆盖本次事故的两个观测面）。
  Future<void> reconcileTicket(OnDeviceLoadState localState, String where) async {
    try {
      final ticket = await fetchSessionTicket();
      sessionMirror.witness(ticket);
      final drift = sessionMirrorDrift(ticket, localState);
      if (drift != null) {
        debugPrint('[DEGRADE] session-mirror drift @$where: $drift '
            '(ticket=$ticket)');
      }
    } catch (e) {
      debugPrint('[DEGRADE] session-mirror reconcile @$where: $e');
    }
  }

  /// token 微批投递已随 S3-6 收编 native 数据面：:engine 写 Ashmem
  /// RingBuffer + pipe 唤醒，主进程 native worker（libgdw）经
  /// Dart_PostCObject_DL 直投本进程 [onDataBatch]（§6.1/§6.4）。
  /// startDataWorker/stopDataWorker 见同名方法；Binder onTokens 过渡通道
  /// 同轮退役（:engine 侧 AIDL Listener 已删该方法，禁双路）。
  ///
  /// S3-6 IPC 死锁切云沿（§6.3）：:engine 判定消费端失速（ring 写超时 500ms）
  /// 已 abort 在途 + 清空在途——按 EngineDiedException 切云（不计熔断）。
  void Function()? onIpcDeadlock;

  /// 数据面微批接收（S3-6，§6.4 TLV 化）：native worker 经 Dart_PostCObject_DL
  /// 投 kArray `[Int32 type, Uint8List payload]`（复制语义）。载荷语义：
  /// TOKEN_CHUNK（0x0001）→ [onDataBatch]（UTF-8 字节，identity 编码）；
  /// EOS（0x000F，payload 恒空）→ [onDataBatch] 收空批（流生命周期唯一事实
  /// 源）；IMAGE_META/PROGRESS 为协议留位（多模态 epic 启用），native 侧
  /// 已按未知类型 skip，此处不会到达；**null = EOF 信号**（对端关闭）。
  void Function(Uint8List batch)? onDataBatch;

  /// 数据面 EOF 信号（S3-7 修订）：native worker 读到 `read()==0`（对端关闭
  /// = :engine 数据面死亡）后投 Dart `null`（Dart_CObject_kNull）——接收方
  /// 即刻以 EngineDiedException 收口活跃流，不经看门狗兜底。
  void Function()? onDataEof;

  /// 生成收尾回调（finishReason 0=stop / 1=cancelled）。
  void Function(String requestId, int finishReason)? onGenerateFinished;

  /// `:engine` 驱动 Panic / 算子越界 abort（AIDL onEngineDied，计入熔断 §6.5）。
  void Function()? onEngineDied;

  /// `:engine` 进程外部处决（ServiceDisconnected：OEM SIGKILL / LMK，不计入
  /// 熔断但维护冷却窗口 §6.5 v2.6）。
  void Function()? onProcessDied;

  /// `:engine` **自发**状态变更上行（P0-3）：TTL 驱逐 / onTrimMemory 驱逐 /
  /// 内存护栏驱逐 / 主动 release 后由主进程桥投递（对应 AIDL
  /// `IOnDeviceEngineListener.onEngineEvicted`）。
  ///
  /// 此前双端状态机（Dart `loadState` × Kotlin `EngineLifecycle`/
  /// `session.ready`）只有 Dart→Kotlin 单向通道，:engine 自发驱逐后主进程
  /// 仍持 ready 说谎态：`enable()` 判 ready 而 no-op 不重装 → 下一次端侧
  /// 请求必撞 `genie session not ready` / `data plane not initialized`，
  /// 且错误文案呈现 `assetMissing`（立法语义=模型未下载）→ 补救方向被误导。
  /// 消费方据此复位 loadState，令下一次 enable 走「快速暖机」再入
  /// （资产在盘不重下载，NPU 稿 §4.1 COLD-EVICTED 立法意图）。
  void Function(String reason)? onEngineEvicted;

  /// §2.8 I6：驱逐**打断了在途生成**（evictingRequestId 非空）——消费方对该
  /// 流以 SESSION_ABORTED_BY_EVICTION 语义收口（可重试/切云），区别于
  /// EngineDied（进程死亡），归因不丢、切云决策可分。
  void Function(String requestId)? onEvictionInterrupted;

  /// F4 装载阶段活体打点（AIDL onLoadPhaseChanged）：阶段推进 = 活体信号
  /// （0=PARSING / 1=ALLOCATING，常量见 listener 契约）。诊断面，不参与路由。
  void Function(int phase)? onLoadPhaseChanged;

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
        case 'onIpcDeadlock':
          onIpcDeadlock?.call();
        case 'onLoadPhaseChanged':
          final phase = (call.arguments as Map<Object?, Object?>?)?['phase'];
          if (phase is int) {
            debugPrint('[on-device] load phase -> $phase');
            onLoadPhaseChanged?.call(phase);
          }
        case 'onGenerateFinished':
          final args = call.arguments as Map;
          onGenerateFinished?.call(
            args['requestId'] as String? ?? '',
            args['finishReason'] as int? ?? 0,
          );
        case 'onEngineReady':
          readyGate.noteReady((call.arguments as int?) ?? 5);
        case 'onEngineEvicted':
          // :engine 自发驱逐：消费方复位 loadState（见 [onEngineEvicted] 注释）。
          // M2 §2.8：args 携带 {reason, evictingRequestId}——requestId 非空 =
          // 驱逐打断了在途生成，aidl 层对该流 SESSION_ABORTED_BY_EVICTION 收口。
          final args = call.arguments;
          final reason = args is Map ? args['reason'] as String? ?? 'unknown' : 'unknown';
          final evicting = args is Map ? args['evictingRequestId'] as String? : null;
          // 投影作废（I2：失效=未知，禁猜测复位）+ 既有 loadState 复位消费面。
          sessionMirror.invalidate();
          onEngineEvicted?.call(reason);
          if (evicting != null) onEvictionInterrupted?.call(evicting);
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

  /// 前台态判定（场景 A/B/C 切云语义拆分用）：桥面 Activity started 计数
  /// >0 即前台。探测失败按**后台**保守处理（场景 B 不切云、暂存等前台）。
  Future<bool> isForeground() async {
    try {
      return await channel.invokeMethod<bool>('isForeground') ?? false;
    } catch (_) {
      return false;
    }
  }

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

  /// 数据面帧/字节计数（诊断面）：「第二轮没有输出」时用于区分
  /// **字节没到 Dart**（计数不动）与**字节到了但解码丢了**（计数在涨）。
  int _dataFrames = 0;
  int _dataBytes = 0;

  /// 每代生成复位帧/字节计数（诊断面）：计数是绑定级累加器，不复位会把
  /// 上一代的 `frames/bytes` 残留进下一代的 EOS 打点（2026-11-02 真机误导：
  /// 第二代零产出却打出第一代的 76/245），在 generate 入口复位。
  void resetDataCounters() {
    _dataFrames = 0;
    _dataBytes = 0;
  }

  /// 启动数据面消费 worker：经 MethodChannel 将 NativePort +
  /// `NativeApi.initializeApiDLData` 指针传主进程桥面——Kotlin 侧经 JNI 驱动
  /// libgdw（epoll 等待数据面 socket 读端可读 + 长度前缀成帧重组
  /// `[4B 大端 len][payload]` + `Dart_PostCObject_DL` 逐帧投递 [onDataBatch]）。
  ///
  /// 幂等：本侧 ReceivePort 单实例复用；桥面已运行时 no-op。失败抛
  /// PlatformException 由调用方决策（generate 路径快速失败切云——数据面
  /// 缺失即无产出，禁静默降级为空流）。
  ///
  /// 载荷语义（§6.1 v3.1）：非空 Uint8List = 生成文本块（identity 字节级）；
  /// **空 Uint8List = EOS 流终结帧**（本代生成收尾凭据，尾批必先于 EOS 到达）。
  Future<void> startDataWorker() async {
    _ensureDataPort();
    await channel.invokeMethod<void>('startDataWorker', {
      'port': _dataPort!.sendPort.nativePort,
      'api': NativeApi.initializeApiDLData.address,
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
      if (message == null) {
        debugPrint('[on_device] data plane EOF signal (frames=$_dataFrames '
            'bytes=$_dataBytes)');
        onDataEof?.call(); // native worker EOF 信号（Dart_CObject_kNull）
        return;
      }
      // TLV 帧（kArray [Int32 type, Uint8List payload]，§6.1 v3.1）。
      if (message is List && message.length >= 2) {
        final type = message[0] as int?;
        final payload = message[1] as Uint8List?;
        if (type == kDataPlaneFrameTokenChunk || type == kDataPlaneFrameEos) {
          // 数据面帧计数（诊断面，2026-10-30 真机实证「第二轮没有输出」）：
          // 首帧/EOS 各留一条——「字节没到 Dart」与「字节到了但解码丢了」在
          // 这两个计数上一眼可分（帧数不动 = 数据面没产字节）。
          if (type == kDataPlaneFrameTokenChunk) {
            _dataFrames++;
            _dataBytes += payload?.length ?? 0;
            if (_dataFrames == 1) {
              debugPrint('[on_device] first data frame arrived '
                  '(bytes=${payload?.length ?? 0})');
            }
          } else {
            debugPrint('[on_device] EOS frame arrived '
                '(frames=$_dataFrames bytes=$_dataBytes)');
          }
          onDataBatch?.call(payload ?? Uint8List(0));
        }
        // 其余类型（IMAGE_META/PROGRESS/未来新增）：native 侧已 skip，此处
        // 防御性忽略（协议留位，多模态 epic 启用时在同位替换分发分支）。
      }
    });
  }
}
