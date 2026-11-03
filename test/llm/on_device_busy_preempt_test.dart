import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';

/// S3-3 单执行槽 Dart 侧分流验证（NPU 稿 §6.6 / 总纲 §2 v2.6；**打断术语于
/// task-capability S14e 订正**）。
///
/// 经 Mock MethodChannel 模拟 `:engine` 拒绝受理，验证错误码 → 切云通道
/// 分流：
///  1. `service_busy`（策略 B 驳回 / **协作式打断未生效**）→ EngineDiedException
///     快速失败，混合引擎捕获即无缝切云；不进熔断口径（无 breaker.report）；
///     两个子情形按消息标记 `interrupt_not_effective` 区分（S14e：等待窗口耗尽
///     只说明打断未生效，**不得假设算力已腾出**）；
///  2. `start_rejected`（数据面未建等）→ 维持 StateError 语义（非切云信号）。
///
/// 单执行槽判定本体（原子授予 CAS / 协作式打断与等待让槽）为 Kotlin 纯逻辑件
/// EngineSlot，JVM 单测在 EngineSlotTest 承载；前台态判定在主进程 Bridge
/// （Activity 计数），均不进入本文件射程。
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
    String errorMessage = 'mock rejection',
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
        throw PlatformException(code: errorCode, message: errorMessage);
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

  test('service_busy + interrupt_not_effective → 打断未生效独立可辨（S14e：'
      '不得假设算力已腾出）', () async {
    await runGenerate(
      requestId: 'r-interrupt-not-effective',
      errorCode: 'service_busy',
      errorMessage: 'service_busy: interrupt_not_effective '
          '(协作式打断等待窗口耗尽 1500ms；打断未生效)',
      errorMatcher: isA<EngineDiedException>().having(
        (e) => e.reason,
        'reason',
        allOf(
          contains('interrupt not effective'),
          contains('算力仍被占'),
        ),
      ),
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
