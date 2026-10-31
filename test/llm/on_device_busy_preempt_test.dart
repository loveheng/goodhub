import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';

/// S3-3 并发原子抢占 Dart 侧分流验证（NPU 稿 §6.6 / 总纲 §2 v2.6）。
///
/// 经 Mock MethodChannel 模拟 `:engine` 拒绝受理，验证错误码 → 切云通道
/// 分流：
///  1. `service_busy`（策略 B 驳回/抢占超时）→ EngineDiedException 快速失败，
///     混合引擎捕获即无缝切云；不进熔断口径（无 breaker.report）；
///  2. `start_rejected`（数据面未建等）→ 维持 StateError 语义（非切云信号）。
///
/// 抢占判定本体（单槽 CAS/等待让槽）为 Kotlin 纯逻辑件 EngineSlot，JVM
/// 单测在 EngineSlotTest 承载；前台态判定在主进程 Bridge（Activity 计数），
/// 均不进入本文件射程。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> dispatchReady() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      OnDeviceEngineBinding.channel.name,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('onEngineReady', 0)),
      (data) {},
    );
  }

  Future<void> waitUntil(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) fail('condition timeout');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> runGenerate({
    required String requestId,
    required String errorCode,
    required Matcher errorMatcher,
  }) async {
    final bound = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
      if (call.method == 'bind') {
        bound.complete();
        return null;
      }
      // M2/M3 闸门：checkSession 须回就绪票据，否则 gate 交装载链路（测试环境
      // 无模型 → enable 终态失败），startGenerate 的拒绝语义到不了。
      if (call.method == 'checkSession') {
        return {'instanceId': 'inst-test', 'seq': 1, 'status': 0};
      }
      if (call.method == 'startGenerate') {
        throw PlatformException(code: errorCode, message: 'mock rejection');
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OnDeviceEngineBinding.channel, null);
    });

    final engine = AidlOnDeviceEngine();
    final errors = <Object>[];
    final sub = engine.generate(requestId: requestId, prompt: 'p').listen(
          null,
          onError: errors.add,
          cancelOnError: true,
        );
    await bound.future;
    await dispatchReady();
    await waitUntil(() => errors.isNotEmpty);
    await sub.cancel();
    expect(errors, contains(errorMatcher));
  }

  test('service_busy（策略 B 驳回）→ EngineDiedException 快速失败切云', () async {
    await runGenerate(
      requestId: 'r-busy',
      errorCode: 'service_busy',
      errorMatcher: isA<EngineDiedException>(),
    );
  });

  test('start_rejected（数据面未建等）→ 非 EngineDiedException 语义', () async {
    await runGenerate(
      requestId: 'r-rejected',
      errorCode: 'start_rejected',
      errorMatcher: isA<StateError>(),
    );
  });
}
