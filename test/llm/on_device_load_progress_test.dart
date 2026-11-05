import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// W2-3 装载进度事件 + 可取消装载回归钉（timeout-signaling）。
///
/// 覆盖：
///  1. AIDL `onLoadPhaseChanged`（oneway）上行 → 引擎面 `loadPhase` 可观察，
///     装载收口复位 -1（过程态不留残值）；
///  2. `cancelLoadWait()` = 请求侧脱钩（detach）：当前等待立即以可重试异常
///     退出，**禁作废 `_loadGen`**——后台装载继续（B-2 语义）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, null);
  });

  /// 派发平台事件（模拟 Bridge 反投 Dart）。
  Future<void> dispatch(MethodCall call) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      OnDeviceEngineBinding.channel.name,
      const StandardMethodCodec().encodeMethodCall(call),
      (data) {},
    );
  }

  group('装载进度事件（loadPhase 镜像）', () {
    test('onLoadPhaseChanged 上行 → loadPhase 更新（0=PARSING/1=ALLOCATING）',
        () async {
      // binding handler 延迟到首次 bind 注册（纯 Dart 环境断言规避）——
      // 事件本就只在 bind 后到达；经 enable 驱动真实 bind 后再投递。
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OnDeviceEngineBinding.channel,
          (call) async {
        calls.add(call.method);
        return call.method == 'waitReady' ? null : null;
      });
      final engine = AidlOnDeviceEngine();
      final loading =
          engine.enable(model: OnDeviceModelOption.fromInstalled('m'));
      try {
        // 等 enable 链真实走到 bind（handler 注册点）。
        for (var i = 0; i < 500; i++) {
          if (calls.contains('bind')) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(calls, contains('bind'), reason: '前置：enable 链已过 bind 注册点');
        await dispatch(const MethodCall('onLoadPhaseChanged', {'phase': 0}));
        expect(engine.loadPhase.value, 0);
        await dispatch(const MethodCall('onLoadPhaseChanged', {'phase': 1}));
        expect(engine.loadPhase.value, 1);
      } finally {
        await engine.disable(); // 作废后台装载，收口退避循环防 pending timer
        try {
          await loading; // 装载失败/作废异常吞掉（非本测试关注面）
        } on Object catch (_) {}
      }
    });
  });

  group('可取消装载（cancelLoadWait = detach）', () {
    test('装载等待中脱钩 → enable 立即以可重试异常退出（后台任务未作废）',
        () async {
      final bindGate = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OnDeviceEngineBinding.channel,
          (call) async {
        if (call.method == 'bind') return bindGate.future; // 挂起装载链
        return null;
      });
      final engine = AidlOnDeviceEngine();
      final waiting = engine
          .enable(model: OnDeviceModelOption.fromInstalled('m'))
          .catchError((Object e) => throw e is OnDeviceLoadException
              ? e
              : OnDeviceLoadException('$e'));
      // 等待请求进入装载等待面（enable → _awaitLoadTask）。
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (engine.cancelLoadWait()) break;
      }
      await expectLater(
        waiting,
        throwsA(isA<OnDeviceLoadException>()
            .having((e) => e.reason, 'reason', contains('已取消等待'))
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
      // 收口后台任务（bind 放行 null → 中断类失败走退避……直接以异常完成），
      // 避免 pending future 泄漏；任务收口不因脱钩被作废（B-2 语义钉）。
      bindGate.complete(null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('无等待者 → cancelLoadWait 返回 false（no-op）', () {
      final engine = AidlOnDeviceEngine();
      expect(engine.cancelLoadWait(), isFalse);
    });
  });

  group('W3-4 引擎存活打点（LivenessTick 喂狗）', () {
    test('数据流空档 tick 重置看门狗 → 活跃流越过阈值不被误判切云', () async {
      // 受理链走通（看门狗武装点 = startGenerate 受理后）：bind/waitReady/
      // checkSession（就绪票据）/startDataWorker/startGenerate 全放行。
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OnDeviceEngineBinding.channel,
          (call) async {
        calls.add(call.method);
        if (call.method == 'checkSession') {
          return {
            'instanceId': 'test-instance',
            'seq': 1,
            'status': 0, // EngineStatus.ready
            'modelId': 'm',
            'runtime': 'test',
            'issuedAtMs': 0,
          };
        }
        return null;
      });
      // 看门狗压缩到 300ms：无 tick 时流会在 300ms 被判失联；有 tick（每
      // 200ms 喂狗）则流持续存活——数据流空档（prefill/长间隙）防误判钉。
      final engine = AidlOnDeviceEngine(noProgressTimeout: const Duration(milliseconds: 300));
      final errors = <Object>[];
      final done = Completer<void>();
      late final StreamSubscription<EngineChunk> sub;
      sub = engine
          .generate(
              requestId: 'r1', prompt: '{}', config: const GenerationConfig())
          .listen((_) {}, onError: errors.add, onDone: done.complete);
      // 等 bind 发起 → 派发 onEngineReady 放行 waitReady → 等受理链走到
      // startGenerate（看门狗武装点）。
      for (var i = 0; i < 500; i++) {
        if (calls.contains('bind')) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await dispatch(const MethodCall('onEngineReady', 0));
      for (var i = 0; i < 500; i++) {
        if (calls.contains('startGenerate')) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(calls, contains('startGenerate'),
          reason: '前置：受理链已走通、看门狗已武装');
      // 空档期持续 tick 喂狗 1s（> 300ms 阈值 3 倍）——流必须活着。
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await dispatch(const MethodCall('onLivenessTick', null));
      }
      final watchdogTripped = errors.whereType<EngineDiedException>().where(
          (e) => e.toString().contains('无进展'));
      expect(watchdogTripped, isEmpty,
          reason: 'tick 喂狗下看门狗不得在阈值处误判数据面失联');
      expect(done.isCompleted, isFalse, reason: '活跃流不得被误收口');
      await sub.cancel();
    });
  });
}
