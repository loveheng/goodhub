import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/degradation_controller.dart';
import 'package:goodhub/coordinator/hybrid_cloud_engine.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/llm.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';
import 'package:goodhub/llm/on_device_pending_load.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 场景 A/B/C 切云语义拆分回归钉（2026-10-30 用户裁决）。
///
/// - A 已加载但运行期夭折 → EngineDiedException 静默切云（既有 [_deviceSend]）；
/// - B 未加载冷启动 + **后台**触发 → **不切云**，打 PendingForegroundLoad
///   暂存等前台（禁数据外发、禁阻断式通知）；
/// - C 未加载冷启动 + **前台**发起 → 终态失败显式报错；可自愈类（进程被杀 /
///   热降级）按需降级云端。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const request = CloudChatRequest(messages: [UserMessage('u')]);

  late FakeCloud cloud;
  late FakeDevice device;
  late HybridCloudEngine engine;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cloud = FakeCloud();
    device = FakeDevice();
    engine = HybridCloudEngine(
      controller: DegradationController(),
      cloud: cloud,
      onDevice: device,
      preferOnDevice: true,
      isForegroundProbe: () async => true,
    );
  });

  test('场景 B：后台冷装载 → 不切云 + 打 PendingForegroundLoad 暂存标记',
      () async {
    final bg = HybridCloudEngine(
      controller: DegradationController(),
      cloud: cloud,
      onDevice: device,
      preferOnDevice: true,
      isForegroundProbe: () async => false,
    );
    device.enableError =
        const OnDeviceLoadException('端侧模型资产缺失或下载失败');
    await expectLater(
      bg.send(request).toList(),
      throwsA(isA<InferenceException>()),
    );
    expect(cloud.calls, isEmpty, reason: '场景 B 严禁切云（禁数据外发）');
    expect(await OnDevicePendingLoad.hasPending(), isTrue,
        reason: '场景 B 必须打暂存标记，等下次前台');
  });

  test('场景 B：前台态探针缺省 → 保守按后台处理（宁暂存不误切云）', () async {
    final noProbe = HybridCloudEngine(
      controller: DegradationController(),
      cloud: cloud,
      onDevice: device,
      preferOnDevice: true,
    );
    device.enableError =
        const OnDeviceLoadException('端侧模型资产缺失或下载失败');
    await expectLater(
      noProbe.send(request).toList(),
      throwsA(isA<InferenceException>()),
    );
    expect(cloud.calls, isEmpty);
  });

  test('场景 C：终态装载失败 → 显式报错不切云（q-1 保持）', () async {
    device.enableError =
        const OnDeviceLoadException('端侧模型资产缺失或下载失败');
    await expectLater(
      engine.send(request).toList(),
      throwsA(isA<InferenceException>()),
    );
    expect(cloud.calls, isEmpty);
  });

  test('场景 C：可自愈类（进程被杀）→ 按需降级云端完成本轮', () async {
    device.enableError = const OnDeviceLoadException(
      '引擎进程中断（系统回收或崩溃），请重试',
      retryable: true,
    );
    cloud.script.add(() => textStream('云端产出'));
    final events = await engine.send(request).toList();
    expect(cloud.calls, hasLength(1));
    expect(events.whereType<CloudTextDelta>().single.text, '云端产出');
  });

  test('场景 A：已加载（loadState=ready）→ 不触发 enable，直接走端侧', () async {
    device.loadState.value = OnDeviceLoadState.ready;
    device.next = '端侧产出';
    final events = await engine.send(request).toList();
    expect(device.enableCalls, 0);
    expect(cloud.calls, isEmpty);
    expect(events.whereType<CloudTextDelta>().single.text, '端侧产出');
  });

  test('暂存标记 TTL 30min：过期即失效并清标记', () async {
    await OnDevicePendingLoad.mark();
    expect(await OnDevicePendingLoad.hasPending(), isTrue);
    // 人为老化：写入 31 分钟前的时间戳 → 视为过期。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'on_device.pending_foreground_load.at',
      DateTime.now()
          .subtract(const Duration(minutes: 31))
          .toIso8601String(),
    );
    expect(await OnDevicePendingLoad.hasPending(), isFalse);
    expect(await OnDevicePendingLoad.remaining(), isNull);
  });
}

/// 云端 fake。
class FakeCloud implements CloudLlmEngine {
  final List<Stream<CloudStreamEvent> Function()> script = [];
  final List<CloudChatRequest> calls = [];

  @override
  String get name => 'fake-cloud';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) {
    calls.add(request);
    if (calls.length > script.length) {
      return Stream.error(StateError('脚本耗尽'));
    }
    return script[calls.length - 1]();
  }
}

/// 端侧 fake（同时实现显式加载能力面 → 触发混合引擎懒加载兜底）。
class FakeDevice implements OnDeviceLlmEngine, OnDeviceEnableCapable {
  Object? enableError;
  int enableCalls = 0;
  String? next;

  @override
  final ValueNotifier<OnDeviceLoadState> loadState =
      ValueNotifier<OnDeviceLoadState>(OnDeviceLoadState.unloaded);

  @override
  Future<EngineStatus> enable(
          {OnDeviceModelOption? model, String? backendHint}) async {
    enableCalls++;
    final err = enableError;
    if (err != null) throw err;
    loadState.value = OnDeviceLoadState.ready;
    return EngineStatus.ready;
  }

  @override
  Future<void> disable() async {
    loadState.value = OnDeviceLoadState.unloaded;
  }

  @override
  String get name => 'fake-device-scene';

  @override
  Future<bool> get isAvailable async => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<String?> unavailableReasonAsync() async => null;

  @override
  Stream<String> generateStream(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
    double? temperature,
    double? topP,
  }) async* {
    final text = next;
    if (text != null && text.isNotEmpty) yield text;
  }

  @override
  Future<bool> cancelActive() async => true;

  @override
  Future<bool> warmup() async => true;

  @override
  Future<void> release() async {}

  @override
  Future<bool> isWarmed() async => true;
}

Stream<CloudStreamEvent> textStream(String s) async* {
  yield CloudTextDelta(s);
  yield const CloudDone(finishReason: CloudFinishReason.stop);
}
