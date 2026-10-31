import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';

/// 端侧引擎生命周期仲裁回归钉（**路线 B**：端侧必须服务「后台任务」）。
///
/// 背景：`:engine` 与主进程**同 UID** —— 进程隔离只切断崩溃传播，**切不断 App
/// 前后台状态**：主进程退后台即整个 UID 进 CACHED，:engine 随之落入 OEM 冻结 /
/// mem-pressure 回收射程。真机实证 =
/// `freezing <pid> com.zzh.goodhub:engine` +
/// `Rescheduling restart of crashed service ... for mem-pressure-event`。
///
/// 两条钉子（撤修复即红）：
///  1. `release()` 通道异常**就地收口**为 DEGRADE，禁止穿透 finally 上抛到
///     `main.dart` 的 `unawaited()` 无人监听 future（该组合 = 静默 root zone
///     未捕获异常：无崩溃、无 stack 上报）；
///  2. `onEngineEvicted` 上行后 `loadState` 复位 unloaded —— 消除「驱逐后仍
///     ready 说谎 → `enable()` no-op 不重装 → 请求必败且文案误导为
///     assetMissing」；配合 `hybrid_cloud_engine` 的懒加载检查，令下一次请求
///     走「快速暖机」再入（资产在盘不重下载）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  final logs = <String>[];

  setUp(() {
    calls.clear();
    logs.clear();
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

  /// 发起活跃流并驱动至 startGenerate 已发起（先等 bind 完成以防
  /// onEngineReady 派发跑赢 handler 注册被丢弃）。
  Future<({List<Object> errors, Completer<void> done})> reachStartGenerate(
      AidlOnDeviceEngine engine) async {
    final errors = <Object>[];
    final done = Completer<void>();
    engine
        .generate(
            requestId: 'r1',
            prompt: '{}',
            config: const GenerationConfig())
        .listen((_) {}, onError: errors.add, onDone: done.complete);
    for (var i = 0; i < 500; i++) {
      if (calls.any((c) => c.method == 'bind')) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await dispatch(const MethodCall('onEngineReady', 0));
    for (var i = 0; i < 500; i++) {
      if (calls.any((c) => c.method == 'startGenerate')) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return (errors: errors, done: done);
  }

  /// 捕获 debugPrint（验证驱逐事件确实被适配件接住——桥面漏接时无留痕）。
  Future<List<String>> captureLogs(Future<void> Function() body) async {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      logs.add(message ?? '');
    };
    try {
      await body();
    } finally {
      debugPrint = original;
    }
    return logs;
  }

  test('release：releaseEngine 通道异常就地收口（禁穿透到无人监听的 future）',
      () async {
    final engine = AidlOnDeviceEngine();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
      calls.add(call);
      if (call.method == 'releaseEngine') throw PlatformException(code: 'boom');
      return null;
    });

    // 不抛即通过：异常须在 release() 内 catch 收口为 DEGRADE 留痕。
    final captured = await captureLogs(engine.release);

    expect(captured.any((l) => l.contains('on_device release: boom')), isTrue);
    // 收口后仍须走 unbind（数据面 fd/映射随之释放）。
    expect(calls.any((c) => c.method == 'unbind'), isTrue);
    expect(engine.loadState.value, OnDeviceLoadState.unloaded);
  });

  test('onEngineEvicted：:engine 自发驱逐 → loadState 复位 unloaded', () async {
    final engine = AidlOnDeviceEngine();
    await reachStartGenerate(engine);

    // :engine 侧 TTL / 护栏 / trim 驱逐上行（桥面投递；M2 §2.8 新参形状）。
    final captured = await captureLogs(() => dispatch(const MethodCall(
        'onEngineEvicted',
        {'reason': 'ttl-elapsed(300000ms)', 'evictingRequestId': null})));

    // 复位后下一次 enable 不会因「ready 说谎」而 no-op 跳过重装。
    expect(engine.loadState.value, OnDeviceLoadState.unloaded);
    // 适配件确实接住了该事件（未接线时无此留痕）。
    expect(captured.any((l) => l.contains('on_device evicted: ttl-elapsed')),
        isTrue);
  });
}
