import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';

/// S3-2 FGS 前台预挂时序验证（NPU 稿 §6.2 v2.7）。
///
/// 经 Mock MethodChannel 录制 Dart→平台调用序，验证：
///  1. 长生成（maxTokens ≥ 阈值）：promoteForeground 先于 startGenerate
///     （前台预挂硬时序——Android 12+ 后台 startForeground 必抛）；
///  2. 短生成（maxTokens < 阈值）：不发起 promote（§6.2「判定可能耗时时
///     即附着」，避免短问答通知闪现）。
///
/// 前台态判定在主进程 Kotlin 侧（EngineServiceBridge 前台闸），纯 Dart
/// 测试环境不覆盖（Mock 通道直接受理 promote 调用，仅验发起时序）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, null);
  });

  /// 派发 onEngineReady（模拟 :engine 控制面就绪事件，解除 waitReady 挂起）。
  Future<void> dispatchReady() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      OnDeviceEngineBinding.channel.name,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('onEngineReady', 0)),
      (data) {},
    );
  }

  /// 轮询直至 [method] 出现在调用序（超时 5s 抛错防挂死）。
  Future<void> waitFor(String method) async {
    const tries = 500;
    for (var i = 0; i < tries; i++) {
      if (calls.contains(method)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timeout waiting for $method; calls=$calls');
  }

  test('长生成：promoteForeground 先于 startGenerate（前台预挂硬时序）',
      () async {
    final engine = AidlOnDeviceEngine();
    final sub = engine
        .generate(
          requestId: 'r1',
          prompt: 'p',
          config: const GenerationConfig(maxTokens: 512),
        )
        .listen(null);
    await waitFor('bind');
    await dispatchReady();
    await waitFor('startGenerate');
    await sub.cancel();
    expect(
      calls,
      containsAllInOrder(const ['bind', 'promoteForeground', 'startGenerate']),
    );
    expect(calls.indexOf('promoteForeground'),
        lessThan(calls.indexOf('startGenerate')));
  });

  test('短生成：不发起 promote（阈值下无通知闪现）', () async {
    final engine = AidlOnDeviceEngine();
    final sub = engine
        .generate(
          requestId: 'r2',
          prompt: 'p',
          config: const GenerationConfig(maxTokens: 128),
        )
        .listen(null);
    await waitFor('bind');
    await dispatchReady();
    await waitFor('startGenerate');
    await sub.cancel();
    expect(calls, isNot(contains('promoteForeground')));
    expect(calls, contains('startGenerate'));
  });

  test('阈值常量与 Kotlin 侧锚定一致（256）', () {
    expect(kFgsPromoteMinTokens, 256);
  });
}
