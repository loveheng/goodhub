import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/degradation_controller.dart';
import 'package:goodhub/coordinator/hybrid_cloud_engine.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/llm.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_load_poll.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// 端侧热降级（设备过热）回归钉（2026-10-30 真机实证）。
///
/// 真机报错「InferenceException: 端侧加载失败：模型装载失败（circuitBroken）」——
/// 根因：`:engine` 侧 `checkStatus` 在**热切云期**（thermal ≥ SEVERE）复用了
/// **熔断**序数 `circuitBroken`，而 Dart 装载轮询把该序数当**终态装载失败**
/// 判死 → 环境性可自愈的降级被报成引擎故障并终止装载。
///
/// 三钉：①契约解耦（热降级独立序数 `thermalCutoff` = 6，双端同轮）；
/// ②装载路径热降级**不判死**（容忍窗内继续轮询等热回落）；
/// ③上层遇热降级按 §5.2 Thermal→Cloud **切云完成本轮**（不套 q-1 显式失败
/// 不切云——q-1 针对端侧能力失败，热降级是调度降级）。
void main() {
  group('契约：热降级与熔断解耦', () {
    test('thermalCutoff 序数 = 6（末尾追加位，不破既有序数映射）', () {
      expect(EngineStatus.thermalCutoff.index, 6);
      expect(EngineStatus.circuitBroken.index, 4);
      expect(engineStatusFromOrdinal(6), EngineStatus.thermalCutoff);
      expect(engineStatusFromOrdinal(4), EngineStatus.circuitBroken);
    });

    test('Dart 枚举顺序与 :engine Kotlin 枚举逐项对齐（禁调序漂移）', () {
      final kotlin = File(
        'android/app/src/main/kotlin/com/zzh/goodhub/EngineStatus.kt',
      ).readAsStringSync();
      final names = RegExp(r'^\s{4}(\w+),', multiLine: true)
          .allMatches(kotlin)
          .map((m) => m.group(1)!)
          .toList();
      expect(names, EngineStatus.values.map((e) => e.name).toList());
      expect(names.last, 'thermalCutoff');
    });

    test('面向用户的失败文案禁泄漏内部枚举名', () {
      for (final status in EngineStatus.values) {
        final reason = engineStatusFailureReason(status);
        expect(reason, isNot(contains(status.name)),
            reason: '状态 ${status.name} 的文案泄漏了内部枚举名');
      }
    });
  });

  group('装载轮询：热降级不判死', () {
    /// 虚拟时钟（注入 sleep/clock → 单测不真等）。
    var virtual = DateTime(2026, 1, 1);
    Future<void> tick(Duration d) async => virtual = virtual.add(d);
    DateTime clock() => virtual;

    test('热降级后温度回落 → 装载就绪（不抛异常）', () async {
      final seq = <EngineStatus>[
        EngineStatus.thermalCutoff,
        EngineStatus.thermalCutoff,
        EngineStatus.ready,
      ];
      final result = await pollLoadReady(
        probe: () async => seq.removeAt(0),
        budget: const Duration(seconds: 10),
        thermalTolerance: const Duration(seconds: 5),
        tick: const Duration(milliseconds: 100),
        sleep: tick,
        clock: clock,
      );
      expect(result, EngineStatus.ready);
    });

    test('热降级超出容忍窗 → 抛「可自愈降级」异常（非终态失败）', () async {
      await expectLater(
        pollLoadReady(
          probe: () async => EngineStatus.thermalCutoff,
          budget: const Duration(seconds: 10),
          thermalTolerance: const Duration(seconds: 1),
          tick: const Duration(milliseconds: 100),
          sleep: tick,
          clock: clock,
        ),
        throwsA(
          isA<OnDeviceLoadException>()
              .having((e) => e.degraded, 'degraded', isTrue)
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.reason, 'reason', contains('过热')),
        ),
      );
    });

    test('终态失败状态如实上抛（内存不足 ≠ 热降级）', () async {
      final result = await pollLoadReady(
        probe: () async => EngineStatus.insufficientMemory,
        budget: const Duration(seconds: 10),
        tick: const Duration(milliseconds: 100),
        sleep: tick,
        clock: clock,
      );
      expect(result, EngineStatus.insufficientMemory);
    });
  });

  group('混合引擎：热降级切云完成本轮', () {
    const request = CloudChatRequest(messages: [UserMessage('u')]);

    late FakeCloud cloud;
    late FakeDevice device;
    late HybridCloudEngine engine;

    setUp(() {
      cloud = FakeCloud();
      device = FakeDevice();
      engine = HybridCloudEngine(
        controller: DegradationController(),
        cloud: cloud,
        onDevice: device,
        preferOnDevice: true,
        // 场景 C 口径：前台用户发起 → 终态显式失败 / 可自愈类降级云端。
        isForegroundProbe: () async => true,
      );
    });

    test('热降级（degraded）→ 切云，云端产出即本轮结果', () async {
      device.enableError = const OnDeviceLoadException(
        '设备过热，端侧已暂停（温度回落后可重试）',
        retryable: true,
        degraded: true,
      );
      cloud.script.add(() => textStream('云端产出'));
      final events = await engine.send(request).toList();
      expect(device.enableCalls, 1);
      expect(cloud.calls, hasLength(1));
      expect(events.whereType<CloudTextDelta>().single.text, '云端产出');
    });

    test('进程被杀类（retryable）→ 切云完成本轮（不等端侧自愈 2 分钟）', () async {
      device.enableError = const OnDeviceLoadException(
        '引擎进程中断（系统回收或崩溃），请重试',
        retryable: true,
      );
      cloud.script.add(() => textStream('云端产出'));
      final events = await engine.send(request).toList();
      expect(cloud.calls, hasLength(1));
      expect(events.whereType<CloudTextDelta>().single.text, '云端产出');
    });

    test('终态装载失败（q-1）→ 显式报错不切云', () async {
      device.enableError =
          const OnDeviceLoadException('端侧模型资产缺失或下载失败');
      await expectLater(
        engine.send(request).toList(),
        throwsA(isA<InferenceException>()),
      );
      expect(cloud.calls, isEmpty);
    });
  });
}

/// 云端 fake（记录调用 + 脚本化产出）。
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

/// 端侧 fake（同时实现显式加载能力面，触发混合引擎的懒加载兜底）。
class FakeDevice implements OnDeviceLlmEngine, OnDeviceEnableCapable {
  Object? enableError;
  int enableCalls = 0;

  final ValueNotifier<OnDeviceLoadState> _loadState =
      ValueNotifier<OnDeviceLoadState>(OnDeviceLoadState.unloaded);

  @override
  ValueListenable<OnDeviceLoadState> get loadState => _loadState;

  @override
  Future<EngineStatus> enable({OnDeviceModelOption? model}) async {
    enableCalls++;
    final err = enableError;
    if (err != null) throw err;
    _loadState.value = OnDeviceLoadState.ready;
    return EngineStatus.ready;
  }

  @override
  Future<void> disable() async {
    _loadState.value = OnDeviceLoadState.unloaded;
  }

  @override
  String get name => 'fake-device-load';

  @override
  Future<bool> get isAvailable async => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<String?> unavailableReasonAsync() async => null;

  @override
  Future<String?> generate(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
  }) async =>
      '端侧产出';

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
