import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/degradation_controller.dart';
import 'package:goodhub/coordinator/hybrid_cloud_engine.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/llm.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// S3 特征 golden（extensibility-hardening）：引擎 send() 拆分前的行为锚——
/// 拆分（collectRouteProbes / DeviceLoadCoordinator / CloudLeg / DeviceLeg）
/// 前后必须逐钉等价。本文件补既有 hybrid_cloud_engine_test /
/// hybrid_scene_split_test 未覆盖的三组：D3 装载等待期取消（K 红线：中止装载
/// = 进程自杀重启）、EngineDied 归因过滤（eviction 分码不记坏后端记忆）、
/// I6 非就绪零产出 → EngineDied 无缝切云。
class _FakeCloud implements CloudLlmEngine {
  final List<Stream<CloudStreamEvent> Function()> script = [];
  final calls = <CloudChatRequest>[];

  @override
  String get name => 'fake-cloud';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request,
      {void Function()? onActivity}) {
    calls.add(request);
    if (calls.length > script.length) return Stream.error(StateError('脚本耗尽'));
    return script[calls.length - 1]();
  }
}

/// 可装载端侧 fake：enable 挂起可控（D3 装载等待期取消）/ 零产出 +
/// 非就绪归因可控（I6）。
class _EnableCapableDevice
    implements OnDeviceLlmEngine, OnDeviceEnableCapable, OnDeviceFailureReasonAware {
  final ValueNotifier<OnDeviceLoadState> loadStateNotifier =
      ValueNotifier(OnDeviceLoadState.unloaded);
  final ValueNotifier<int> loadPhaseNotifier = ValueNotifier(-1);

  /// 非空时 enable 挂起至此 Completer 完成（模拟冷装载进行中）。
  Completer<void>? hangEnable;

  /// 非空 = 引擎非就绪归因（I6：零产出归因读数）。
  String? _unavailableReason;

  int enableCalls = 0;
  int disableCalls = 0;

  /// 注入非就绪归因（I6 场景）。
  set unavailableReason(String? value) => _unavailableReason = value;

  @override
  ValueListenable<OnDeviceLoadState> get loadState => loadStateNotifier;

  @override
  ValueListenable<int> get loadPhase => loadPhaseNotifier;

  @override
  Future<EngineStatus> enable(
      {OnDeviceModelOption? model, String? backendHint}) async {
    enableCalls++;
    final hang = hangEnable;
    if (hang != null) await hang.future; // 装载挂起（不可被外部中止）
    loadStateNotifier.value = OnDeviceLoadState.ready;
    return EngineStatus.ready;
  }

  @override
  Future<void> disable() async {
    disableCalls++;
    loadStateNotifier.value = OnDeviceLoadState.unloaded;
  }

  @override
  String get name => 'fake-device-enable';

  @override
  Future<bool> get isAvailable async => true;

  @override
  Stream<String> generateStream(String prompt,
      {String? system,
      int maxTokens = 512,
      LlmResponseFormat? responseFormat,
      double? temperature,
      double? topP}) async* {
    // 零产出：不 yield（I6 归因路径）
  }

  @override
  Future<bool> cancelActive() async => true;

  @override
  Future<bool> warmup() async => true;

  @override
  Future<void> release() async {}

  @override
  Future<bool> isWarmed() async => true;

  @override
  String? get unavailableReason => _unavailableReason;

  @override
  Future<String?> unavailableReasonAsync() async => _unavailableReason;

  @override
  String? get lastFailureReason => null;
}

Stream<CloudStreamEvent> _textStream(String s) async* {
  yield CloudTextDelta(s);
  yield const CloudDone(finishReason: CloudFinishReason.stop);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('D3：装载等待期取消 = 放弃本轮等待，绝不中止装载（disable 零调用）',
      () async {
    final device = _EnableCapableDevice();
    final enableDone = Completer<void>();
    device.hangEnable = enableDone; // 装载挂起中
    final cloud = _FakeCloud()..script.add(() => _textStream('cloud'));
    final engine = HybridCloudEngine(
      controller: DegradationController(),
      cloud: cloud,
      onDevice: device,
      preferOnDevice: true, // 偏好端侧 → 直入端侧路径（场景 C 前台冷装载）
      isForegroundProbe: () async => true,
    );
    final sub = engine
        .send(const CloudChatRequest(messages: [UserMessage('u')]))
        .listen(null, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50)); // 进入装载等待
    expect(device.enableCalls, 1, reason: '已进入装载等待窗口');
    // D3 语义自身在此显形：退订收尾要等生成器走到 await 检查点（enable 不可
    // 中断）——cancel 的 Future 在装载完成后才完成，本轮静默退出、无产出投递。
    final cancelDone = sub.cancel();
    enableDone.complete(); // 装载在后台继续完成（不可中止）
    await cancelDone;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(device.disableCalls, 0,
        reason: 'D3 红线：中止装载 = 单进程单装载纪律下进程自杀重启，禁');
    expect(cloud.calls, isEmpty, reason: '装载等待期取消本轮不切云（无产出投递）');
  });

  test('I6：非就绪零产出 → EngineDied 语义无缝切云（产出优先，禁静默）', () async {
    final device = _EnableCapableDevice()
      ..loadStateNotifier.value = OnDeviceLoadState.ready // 旁路冷装载
      ..unavailableReason = 'engine evicted'; // 非就绪归因（驱逐）
    final cloud = _FakeCloud()..script.add(() => _textStream('cloud'));
    final engine = HybridCloudEngine(
      controller: DegradationController(),
      cloud: cloud,
      onDevice: device,
      preferOnDevice: true, // 用户偏好端侧 → 直接走端侧路径
    );
    final out = <String>[];
    await for (final e in engine
        .send(const CloudChatRequest(messages: [UserMessage('u')]))) {
      if (e is CloudTextDelta) out.add(e.text);
    }
    expect(out, ['cloud'], reason: '零产出且引擎非就绪 = 会话死亡语义 → 无缝切云');
  });

  group('EngineDied 归因过滤（eviction 生命周期分码不记坏后端记忆）', () {
    test('eviction/EOF/装载类可重试分码 → 不记 crash（防持久化成坏后端记忆）', () {
      expect(evictionLifecycleDied('session_aborted_by_eviction'), isTrue);
      expect(evictionLifecycleDied('SESSION_ABORTED_BY_EVICTION'), isTrue,
          reason: '大小写不敏感（Kotlin 侧分码原样透传）');
      expect(evictionLifecycleDied('data plane eof'), isTrue);
      expect(evictionLifecycleDied('session_loading'), isTrue);
      expect(evictionLifecycleDied('session_epoch_mismatch'), isTrue);
      expect(evictionLifecycleDied('session_model_mismatch'), isTrue);
    });
    test('真死亡类照记 crash（进程死亡/看门狗/死锁）', () {
      expect(evictionLifecycleDied('native crash SIGSEGV'), isFalse);
      expect(evictionLifecycleDied('watchdog timeout'), isFalse);
      expect(evictionLifecycleDied('ipc deadlock'), isFalse);
    });
  });
}
