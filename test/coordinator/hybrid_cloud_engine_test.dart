import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/degradation_controller.dart';
import 'package:goodhub/coordinator/hybrid_cloud_engine.dart';
import 'package:goodhub/core/errors/cloud_llm_error.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/llm.dart';

/// 可编程云端 fake：按脚本逐次返回流。
class FakeCloudEngine implements CloudLlmEngine {
  final List<Stream<CloudStreamEvent> Function()> script = [];
  final List<CloudChatRequest> calls = [];

  @override
  String get name => 'fake-cloud';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request) {
    calls.add(request);
    if (calls.length > script.length) {
      return Stream.error(StateError('脚本耗尽'));
    }
    return script[calls.length - 1]();
  }
}

/// 端侧 fake。
class FakeDeviceEngine implements OnDeviceLlmEngine {
  String? next;
  final prompts = <String>[];
  final formats = <LlmResponseFormat?>[];

  /// cancelActive 调用计数（断言 §10 ①步联动）。
  int cancelCalls = 0;

  /// 非空时 generate 挂起到此 Completer 完成（模拟长生成，供取消联动测试）。
  Completer<void>? hangUntil;

  @override
  String get name => 'fake-device';

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
  }) async {
    prompts.add(system == null ? prompt : '$system|$prompt');
    formats.add(responseFormat);
    final hang = hangUntil;
    if (hang != null) {
      await hang.future;
      return null; // 被取消/落空后按空产出结束
    }
    return next;
  }

  @override
  Future<bool> cancelActive() async {
    cancelCalls++;
    hangUntil?.complete();
    return true;
  }

  @override
  Future<bool> warmup() async => true;

  @override
  Future<void> release() async {}

  @override
  Future<bool> isWarmed() async => true;
}

Stream<CloudStreamEvent> textStream(String s,
        {CloudFinishReason reason = CloudFinishReason.stop}) async* {
  yield CloudTextDelta(s);
  yield CloudDone(finishReason: reason);
}

Stream<CloudStreamEvent> errorStream(CloudLlmException e) async* {
  throw e;
}

void main() {
  const noTools = CloudChatRequest(messages: [UserMessage('u')]);
  const withTools = CloudChatRequest(
    messages: [UserMessage('u')],
    tools: [CloudToolSchema(name: 'f', description: '', parametersSchema: {})],
  );

  late FakeCloudEngine cloud;
  late FakeDeviceEngine device;
  late DegradationController controller;
  late HybridCloudEngine engine;

  setUp(() {
    cloud = FakeCloudEngine();
    device = FakeDeviceEngine();
    controller = DegradationController();
    engine = HybridCloudEngine(
      controller: controller,
      cloud: cloud,
      onDevice: device,
    );
  });

  test('健康态走云端且整流成功后 reportSuccess', () async {
    cloud.script.add(() => textStream('hi'));
    final events = await engine.send(noTools).toList();
    expect(events.whereType<CloudTextDelta>().single.text, 'hi');
    expect(cloud.calls, hasLength(1));
    expect(controller.health, CloudHealth.healthy);
  });

  test('降级态无工具请求直走端侧（云端零调用），消息压平为单发 prompt', () async {
    controller.reportTransportTimeout();
    device.next = '端侧产出';
    final events = await engine.send(const CloudChatRequest(messages: [
      SystemMessage('sys'),
      UserMessage('u1'),
    ])).toList();
    expect(cloud.calls, isEmpty);
    expect(device.prompts.single, 'sys|u1');
    expect(events.whereType<CloudTextDelta>().single.text, '端侧产出');
    expect(events.whereType<CloudDone>().single.finishReason, CloudFinishReason.stop);
  });

  test('带工具请求降级态仍走云端（§2 端侧不承担通用调度）', () async {
    controller.reportTransportTimeout();
    cloud.script.add(() => textStream('x'));
    await engine.send(withTools).toList();
    expect(cloud.calls, hasLength(1));
    expect(device.prompts, isEmpty);
  });

  test('断网探测命中 → 立即端侧（判据：断网即切）', () async {
    var offline = true;
    final e = HybridCloudEngine(
      controller: controller,
      cloud: cloud,
      onDevice: device,
      isOfflineProbe: () async => offline,
    );
    device.next = 'offline-note';
    final events = await e.send(noTools).toList();
    expect(cloud.calls, isEmpty);
    expect(events.whereType<CloudTextDelta>().single.text, 'offline-note');
    offline = false;
  });

  test('云端 5xx：当次端侧兜底且计数 1（未达阈值不降级）', () async {
    cloud.script.add(() => errorStream(const CloudHttpException('boom', statusCode: 500)));
    device.next = 'fallback';
    final events = await engine.send(noTools).toList();
    expect(events.whereType<CloudTextDelta>().single.text, 'fallback');
    expect(controller.consecutiveServerErrors, 1);
    expect(controller.health, CloudHealth.healthy);
  });

  test('连续两次 5xx 后降级：第三次请求云端零调用', () async {
    cloud.script
      ..add(() => errorStream(const CloudHttpException('e1', statusCode: 500)))
      ..add(() => errorStream(const CloudHttpException('e2', statusCode: 429)));
    device.next = 'fb';
    await engine.send(noTools).toList();
    await engine.send(noTools).toList();
    expect(controller.health, CloudHealth.degraded);
    await engine.send(noTools).toList();
    expect(cloud.calls, hasLength(2));
    expect(controller.shouldUseCloud, isFalse);
  });

  test('端侧也不可用 → 上抛端侧失败（禁静默吞）', () async {
    cloud.script.add(() => errorStream(const CloudHttpException('boom', statusCode: 500)));
    device.next = null;
    await expectLater(
      engine.send(noTools).toList(),
      throwsA(isA<InferenceException>()),
    );
  });

  test('无端侧时云端错误原样上抛', () async {
    final e = HybridCloudEngine(
      controller: controller,
      cloud: cloud,
      onDevice: null,
    );
    cloud.script.add(() => errorStream(const CloudHttpException('boom', statusCode: 500)));
    await expectLater(
      e.send(noTools).toList(),
      throwsA(isA<CloudHttpException>()),
    );
  });

  test('云端未配置且端侧在 → 端侧路径；两者皆无 → InferenceException', () async {
    final deviceOnly = HybridCloudEngine(controller: controller, onDevice: device);
    device.next = 'd';
    final events = await deviceOnly.send(noTools).toList();
    expect(events.whereType<CloudTextDelta>().single.text, 'd');

    final none = HybridCloudEngine(controller: controller);
    await expectLater(
      none.send(noTools).toList(),
      throwsA(isA<InferenceException>()),
    );
  });

  test('首 Token 超时：注入 TimeoutException → 降级 + 当次端侧兜底', () async {
    final slow = DegradationController(firstTokenTimeout: const Duration(milliseconds: 40));
    final hang = StreamController<CloudStreamEvent>(); // 永不产出
    final hangingCloud = FakeCloudEngine()
      ..script.add(() => hang.stream);
    final e = HybridCloudEngine(
      controller: slow,
      cloud: hangingCloud,
      onDevice: device,
    );
    device.next = 'timeout-fb';
    final events = await e.send(noTools).toList();
    expect(events.whereType<CloudTextDelta>().single.text, 'timeout-fb');
    expect(slow.health, CloudHealth.degraded);
    await hang.close();
  });

  test('无端侧首 Token 超时 → 原样上抛 TimeoutException', () async {
    final slow = DegradationController(firstTokenTimeout: const Duration(milliseconds: 40));
    final hang = StreamController<CloudStreamEvent>();
    final hangingCloud = FakeCloudEngine()
      ..script.add(() => hang.stream);
    final e = HybridCloudEngine(
      controller: slow,
      cloud: hangingCloud,
      onDevice: null,
    );
    await expectLater(
      e.send(noTools).toList(),
      throwsA(isA<TimeoutException>()),
    );
    expect(slow.health, CloudHealth.degraded);
    await hang.close();
  });

  test('取消订阅即联动 cancelActive（§10 ①步端侧路径）', () async {
    controller.reportTransportTimeout(); // 降级态：无工具请求直走端侧
    device.hangUntil = Completer<void>();
    final sub = engine.send(noTools).listen(
          (_) {},
          onError: (_) {}, // 取消后挂起生成按空产出落 InferenceException，忽略
        );
    // async* 启动在微任务、端侧 pump 在事件队列——有界轮询等 generate 进场
    for (var i = 0; i < 100 && device.prompts.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(device.prompts, hasLength(1));
    expect(device.cancelCalls, 0);
    await sub.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(device.cancelCalls, 1);
  });

  test('正常完成路径不触发 cancelActive（stream done 退订 ≠ 取消）', () async {
    controller.reportTransportTimeout();
    device.next = '产出';
    await engine.send(noTools).toList();
    await Future<void>.delayed(Duration.zero); // 留出 pump finally 收尾
    expect(device.cancelCalls, 0);
  });

  test('设备门禁关闸：降级态也走云端（关闸 ≡ 端侧不可用）', () async {
    controller.reportTransportTimeout();
    var checked = false;
    final gated = HybridCloudEngine(
      controller: controller,
      cloud: cloud,
      onDevice: device,
      deviceTierGate: () async {
        checked = true;
        return (pass: false, reason: '电量 10% < 15%（未充电）');
      },
    );
    cloud.script.add(() => textStream('云端接管'));
    final events = await gated.send(noTools).toList();
    expect(checked, isTrue);
    expect(device.prompts, isEmpty); // 端侧零调用
    expect(events.whereType<CloudTextDelta>().single.text, '云端接管');
  });

  test('设备门禁放行：端侧路径照常', () async {
    controller.reportTransportTimeout();
    device.next = '端侧产出';
    final gated = HybridCloudEngine(
      controller: controller,
      cloud: cloud,
      onDevice: device,
      deviceTierGate: () async => (pass: true, reason: 'ok'),
    );
    final events = await gated.send(noTools).toList();
    expect(device.prompts, hasLength(1));
    expect(events.whereType<CloudTextDelta>().single.text, '端侧产出');
  });

  test('设备门禁关闸且无云端 → 可观测上抛（禁静默吞）', () async {
    controller.reportTransportTimeout();
    final gated = HybridCloudEngine(
      controller: controller,
      cloud: null,
      onDevice: device,
      deviceTierGate: () async => (pass: false, reason: '省电模式'),
    );
    await expectLater(
      gated.send(noTools).toList(),
      throwsA(isA<InferenceException>()),
    );
    expect(device.prompts, isEmpty);
  });

  group('云端空产出兜底（T7 实测：推理型模型烧光 max_tokens 零可见内容）', () {
    Stream<CloudStreamEvent> doneOnly() async* {
      yield const CloudDone(finishReason: CloudFinishReason.stop);
    }

    test('干净空流（仅 Done）→ 当次端侧兜底，产出优先', () async {
      cloud.script.add(doneOnly);
      device.next = '端侧兜底产出';
      final events = await engine.send(noTools).toList();
      expect(device.prompts, hasLength(1), reason: '空产出即当次兜底');
      expect(events.whereType<CloudTextDelta>().single.text, '端侧兜底产出');
    });

    test('带工具请求空产出（无端侧兜底位）→ 显式上抛 InferenceException', () async {
      cloud.script.add(doneOnly);
      await expectLater(
        engine.send(withTools).toList(),
        throwsA(isA<InferenceException>()),
      );
      expect(device.prompts, isEmpty);
    });

    test('有可见产出不误兜底（正常云端流直达）', () async {
      cloud.script.add(() => textStream('云端正文'));
      final events = await engine.send(noTools).toList();
      expect(device.prompts, isEmpty);
      expect(events.whereType<CloudTextDelta>().single.text, '云端正文');
    });
  });
}
