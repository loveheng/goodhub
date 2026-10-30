import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';

/// S3-6 数据面消费链验证（NPU 稿 §6.1/§6.4，S3-7 UDS 化）。
///
/// Binder onTokens 过渡通道退役后，token 微批唯一通路 = 主进程 native worker
/// （libgdw）经 NativePort 投 Uint8List → [AidlOnDeviceEngine.handleDataBatch]
/// 喂活跃流。纯 Dart 测试环境无法起真 native 线程——本测试经 Mock
/// MethodChannel：
///  1. 验证 startDataWorker 请求载荷（NativePort + DL API 指针）；
///  2. 验证 handleDataBatch（native 端口直投入口）喂活跃流的文本产出
///     （跨帧 UTF-8 重组 §6.4）；
///  3. 验证 EOS（空批）/onGenerateFinished 双沿收口（§6.1 v3.1）；
///  4. 验证 onIpcDeadlock 切云沿：活跃流 EngineDiedException 收口 + 不进熔断
///     （§6.3/§6.5 口径：消费端失速属环境事件，仅冷却窗口）；
///  5. 验证 release 时 stopDataWorker 先于 releaseEngine（数据面 fd
///     属 :engine，解绑前必须先停消费端）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, null);
  });

  /// 派发平台事件（模拟 :engine / Bridge 反投 Dart）。
  Future<void> dispatch(MethodCall call) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      OnDeviceEngineBinding.channel.name,
      const StandardMethodCodec().encodeMethodCall(call),
      (data) {},
    );
  }

  /// 轮询直至谓词满足（超时 5s 抛错防挂死）。
  Future<void> waitFor(bool Function() cond) async {
    for (var i = 0; i < 500; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timeout; calls=${calls.map((c) => c.method).toList()}');
  }

  /// 发起活跃流并驱动至 startGenerate 已发起：先等 bind 完成（handler 注册
  /// 就绪，防 onEngineReady 派发跑赢注册被丢弃），再派发就绪事件。
  Future<({List<EngineChunk> chunks, List<Object> errors, Completer<void> done})>
      reachStartGenerate(AidlOnDeviceEngine engine) async {
    final chunks = <EngineChunk>[];
    final errors = <Object>[];
    final done = Completer<void>();
    engine
        .generate(
            requestId: 'r1',
            prompt: '{}',
            config: const GenerationConfig())
        .listen(chunks.add, onError: errors.add, onDone: done.complete);
    await waitFor(() => calls.any((c) => c.method == 'bind'));
    await dispatch(const MethodCall('onEngineReady', 0));
    await waitFor(() => calls.any((c) => c.method == 'startGenerate'));
    return (chunks: chunks, errors: errors, done: done);
  }

  test('startDataWorker 载荷：NativePort + DL API 指针（容量随 RingBuffer 退役）', () async {
    final binding = OnDeviceEngineBinding();
    await binding.startDataWorker();
    final call = calls.lastWhere((c) => c.method == 'startDataWorker');
    final args = call.arguments as Map;
    expect(args['port'], isPositive);
    expect(args['api'], isPositive); // NativeApi.initializeApiDLData 指针
    expect(args.containsKey('capacity'), isFalse); // 游标/容量随 UDS 化退役
    await binding.stopDataWorker();
    expect(calls.any((c) => c.method == 'stopDataWorker'), isTrue);
  });

  test('handleDataBatch 喂活跃流：跨微批 UTF-8 重组产出 deltaText', () async {
    final engine = AidlOnDeviceEngine();
    final s = await reachStartGenerate(engine);

    // 模拟 native worker 两批投递：'好' 的 UTF-8 三字节跨批边界切开。
    final goodBytes = utf8.encode('好');
    engine.handleDataBatch(Uint8List.fromList(goodBytes.sublist(0, 2)));
    engine.handleDataBatch(
        Uint8List.fromList(goodBytes.sublist(2) + utf8.encode('的世界')));
    engine.handleDataBatch(Uint8List(0)); // EOS 流终结帧（§6.1 v3.1）
    await dispatch(const MethodCall(
        'onGenerateFinished', {'requestId': 'r1', 'finishReason': 0}));
    await s.done.future;

    expect(s.errors, isEmpty);
    expect(s.chunks.map((c) => c.deltaText).join(), '好的世界');
  });

  test('EOS 单源收口：空批即关流，不依赖收尾事件（S3-7 修订）', () async {
    final engine = AidlOnDeviceEngine();
    final s = await reachStartGenerate(engine);

    engine.handleDataBatch(Uint8List.fromList(utf8.encode('好')));
    // **仅派发 EOS，不派发 onGenerateFinished**——流生命周期唯一事实源 = EOS，
    // 必须立即收口（旧双沿门控的 2s 定时器已退役）。
    engine.handleDataBatch(Uint8List(0));
    await s.done.future.timeout(const Duration(seconds: 2));

    expect(s.errors, isEmpty);
    expect(s.chunks.map((c) => c.deltaText).join(), '好');
  });

  test('onIpcDeadlock：活跃流 EngineDiedException 收口 + 不计熔断', () async {
    final engine = AidlOnDeviceEngine();
    final s = await reachStartGenerate(engine);

    await dispatch(const MethodCall('onIpcDeadlock'));
    await s.done.future;

    expect(s.errors.single, isA<EngineDiedException>());
    // 无任何 breaker.report(countable:true) 触发（onEngineDied 才计数）。
    expect(await engine.diagBreakerState(), 'broken=false cooldown=false');
  });

  test('startDataWorker 先于 startGenerate（消费端先于生产端，防丢 token）', () async {
    final engine = AidlOnDeviceEngine();
    await reachStartGenerate(engine);
    final order = calls.map((c) => c.method).toList();
    expect(order.indexOf('startDataWorker'), isNot(-1));
    expect(order.indexOf('startGenerate'),
        greaterThan(order.indexOf('startDataWorker')));
  });

  test('worker 启动失败：EngineDiedException 快速失败切云（禁静默空流）', () async {
    final engine = AidlOnDeviceEngine();
    // 覆写 mock：startDataWorker 报 worker_start_failed（桥面 native 起
    // 线程失败等），其余照常受理。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
      if (call.method == 'startDataWorker') {
        throw PlatformException(code: 'worker_start_failed', message: 'handle=-6');
      }
      calls.add(call);
      return null;
    });
    final errors = <Object>[];
    final done = Completer<void>();
    engine
        .generate(
            requestId: 'r1',
            prompt: '{}',
            config: const GenerationConfig())
        .listen((_) {}, onError: errors.add, onDone: done.complete);
    await waitFor(() => calls.any((c) => c.method == 'bind'));
    await dispatch(const MethodCall('onEngineReady', 0));
    await done.future;

    expect(errors.single, isA<EngineDiedException>());
    // 数据面缺失属引擎死亡类环境事件：不计熔断。
    expect(await engine.diagBreakerState(), 'broken=false cooldown=false');
  });

  test('release：stopDataWorker 先于 releaseEngine（数据面先行收口）', () async {
    final engine = AidlOnDeviceEngine();
    await engine.release();
    final order = calls.map((c) => c.method).toList();
    expect(order.indexOf('stopDataWorker'), isNot(-1));
    expect(order.indexOf('releaseEngine'),
        greaterThan(order.indexOf('stopDataWorker')));
  });

  test('数据面坏字节自愈：流不中断、后续文本正常产出（无异常洪泛）', () async {
    final engine = AidlOnDeviceEngine();
    final s = await reachStartGenerate(engine);

    // 坏字节（UTF-8 延续字节单独出现）→ 解码失败 → detok 重建解码器自愈。
    engine.handleDataBatch(Uint8List.fromList([0x80, 0x80]));
    engine.handleDataBatch(Uint8List.fromList(utf8.encode('OK')));
    engine.handleDataBatch(Uint8List(0)); // EOS 流终结帧（§6.1 v3.1）
    await dispatch(const MethodCall(
        'onGenerateFinished', {'requestId': 'r1', 'finishReason': 0}));
    await s.done.future;

    expect(s.errors, isEmpty, reason: '坏字节不得废掉整条流（真机曾异常洪泛致 ANR）');
    expect(s.chunks.map((c) => c.deltaText).join(), 'OK');
  });

  test('端侧流无进展看门狗：收尾事件丢失 → 快速失败切云（禁永挂零响应）', () async {
    final engine =
        AidlOnDeviceEngine(noProgressTimeout: const Duration(milliseconds: 200));
    final errors = <Object>[];
    final done = Completer<void>();
    engine
        .generate(requestId: 'r1', prompt: '{}')
        .listen((_) {}, onError: errors.add, onDone: done.complete);
    await waitFor(() => calls.any((c) => c.method == 'bind'));
    await dispatch(const MethodCall('onEngineReady', 0));
    await waitFor(() => calls.any((c) => c.method == 'startGenerate'));
    // **不派发 onGenerateFinished**（模拟 :engine 收尾事件丢失）→ 看门狗兜底：
    // 流必须自行收口（EngineDiedException → 混合引擎切云），绝不能永挂。
    await done.future.timeout(const Duration(seconds: 5));
    expect(errors.single, isA<EngineDiedException>());
    expect(await engine.diagBreakerState(), 'broken=false cooldown=false');
  });

  test('端侧流看门狗：字节到达即重置（长生成不被误杀）', () async {
    final engine =
        AidlOnDeviceEngine(noProgressTimeout: const Duration(milliseconds: 300));
    final errors = <Object>[];
    final done = Completer<void>();
    final chunks = <EngineChunk>[];
    engine
        .generate(requestId: 'r1', prompt: '{}')
        .listen(chunks.add, onError: errors.add, onDone: done.complete);
    await waitFor(() => calls.any((c) => c.method == 'bind'));
    await dispatch(const MethodCall('onEngineReady', 0));
    await waitFor(() => calls.any((c) => c.method == 'startGenerate'));
    // 每 120ms 一批字节（< 看门狗 300ms）→ 看门狗持续重置，不误杀。
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      engine.handleDataBatch(Uint8List.fromList(utf8.encode('a')));
    }
    engine.handleDataBatch(Uint8List(0)); // EOS 流终结帧（§6.1 v3.1）
    await dispatch(const MethodCall(
        'onGenerateFinished', {'requestId': 'r1', 'finishReason': 0}));
    await done.future.timeout(const Duration(seconds: 5));
    expect(errors, isEmpty);
    expect(chunks.map((c) => c.deltaText).join(), 'aaaa');
  });
}
