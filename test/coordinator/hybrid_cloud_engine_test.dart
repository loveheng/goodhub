import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/degradation_controller.dart';
import 'package:goodhub/coordinator/hybrid_cloud_engine.dart';
import 'package:goodhub/core/errors/cloud_llm_error.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/llm.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/device_tier.dart';
import 'package:http/http.dart' as http;

/// 可编程云端 fake：按脚本逐次返回流。
class FakeCloudEngine implements CloudLlmEngine {
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

/// 端侧 fake。
class FakeDeviceEngine implements OnDeviceLlmEngine, OnDeviceFailureReasonAware {
  String? next;
  final prompts = <String>[];
  final formats = <LlmResponseFormat?>[];

  /// 失败真因（可注入）：端侧失败时上层据此把真因带进错误文案（禁笼统
  /// 「空产出」）。
  String? failureReason;

  @override
  String? get lastFailureReason => failureReason;

  /// cancelActive 调用计数（断言 §10 ①步联动）。
  int cancelCalls = 0;

  /// 非空时 generate 挂起到此 Completer 完成（模拟长生成，供取消联动测试）。
  Completer<void>? hangUntil;

  /// 置位时 generate 抛 EngineDiedException（on-device S1-5 切云联调）。
  bool dieOnGenerate = false;

  @override
  String get name => 'fake-device';

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
  }) async* {
    prompts.add(system == null ? prompt : '$system|$prompt');
    formats.add(responseFormat);
    if (dieOnGenerate) {
      throw const EngineDiedException('mock :engine died');
    }
    final hang = hangUntil;
    if (hang != null) {
      await hang.future;
      return; // 被取消/落空后按零产出结束（无事件 close）
    }
    final text = next;
    if (text != null && text.isNotEmpty) yield text;
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

Stream<CloudStreamEvent> textStream(
  String s, {
  CloudFinishReason reason = CloudFinishReason.stop,
}) async* {
  yield CloudTextDelta(s);
  yield CloudDone(finishReason: reason);
}

Stream<CloudStreamEvent> errorStream(CloudLlmException e) async* {
  throw e;
}

/// 首 delta 立即可达、间隔 [gap] 后给第二个 delta——用于流内事件间隙阈值测试。
Stream<CloudStreamEvent> gapStream(Duration gap, String second) async* {
  yield CloudTextDelta('a');
  await Future<void>.delayed(gap);
  yield CloudTextDelta(second);
  yield const CloudDone(finishReason: CloudFinishReason.stop);
}

void main() {
  const noTools = CloudChatRequest(messages: [UserMessage('u')]);

  /// 宿主本地元工具面（S2 纯聊天收口测试夹具）：AgentLoop 实际恒发的形态。
  const localMetaToolsOnly = CloudChatRequest(
    messages: [UserMessage('u')],
    tools: [
      CloudToolSchema(name: 'get_connected_apps', description: '', parametersSchema: {}),
      CloudToolSchema(name: 'update_memory', description: '', parametersSchema: {}),
    ],
  );

  /// 含 MCP 服务端工具（本地元工具 + 服务端工具混合，判据须拒绝）。
  const withServerTool = CloudChatRequest(
    messages: [UserMessage('u')],
    tools: [
      CloudToolSchema(name: 'get_connected_apps', description: '', parametersSchema: {}),
      CloudToolSchema(name: 'server__query', description: '', parametersSchema: {}),
    ],
  );
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

  test('降级态无工具请求直走端侧（云端零调用），消息序列 JSON 跨 AIDL', () async {
    controller.reportTransportTimeout();
    device.next = '端侧产出';
    final events = await engine
        .send(
          const CloudChatRequest(
            messages: [SystemMessage('sys'), UserMessage('u1')],
          ),
        )
        .toList();
    expect(cloud.calls, isEmpty);
    // 2026-10-31 设计修正：prompt = 消息序列 JSON（多轮 ChatML 由 :engine
    // 模板承载角色；旧单发压平 + 文字标注因复读环退役）。
    final turns =
        (jsonDecode(device.prompts.single) as List).cast<Map<String, dynamic>>();
    expect(turns.map((m) => m['role']).toList(), ['system', 'user']);
    expect(turns[0]['content'], 'sys');
    expect(turns[1]['content'], 'u1');
    expect(events.whereType<CloudTextDelta>().single.text, '端侧产出');
    expect(
      events.whereType<CloudDone>().single.finishReason,
      CloudFinishReason.stop,
    );
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
    cloud.script.add(
      () => errorStream(const CloudHttpException('boom', statusCode: 500)),
    );
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
    cloud.script.add(
      () => errorStream(const CloudHttpException('boom', statusCode: 500)),
    );
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
    cloud.script.add(
      () => errorStream(const CloudHttpException('boom', statusCode: 500)),
    );
    await expectLater(
      e.send(noTools).toList(),
      throwsA(isA<CloudHttpException>()),
    );
  });

  test('云端未配置且端侧在 → 端侧路径；两者皆无 → InferenceException', () async {
    final deviceOnly = HybridCloudEngine(
      controller: controller,
      onDevice: device,
    );
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
    final slow = DegradationController(
      firstTokenTimeout: const Duration(milliseconds: 40),
    );
    final hang = StreamController<CloudStreamEvent>(); // 永不产出
    final hangingCloud = FakeCloudEngine()..script.add(() => hang.stream);
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
    final slow = DegradationController(
      firstTokenTimeout: const Duration(milliseconds: 40),
    );
    final hang = StreamController<CloudStreamEvent>();
    final hangingCloud = FakeCloudEngine()..script.add(() => hang.stream);
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

  test('流内事件间隙走 interEventGapTimeout（超阈值→降级+端侧兜底）', () async {
    final c = DegradationController(
      firstTokenTimeout: const Duration(milliseconds: 500),
      interEventGapTimeout: const Duration(milliseconds: 30),
    );
    final e = HybridCloudEngine(
      controller: c,
      cloud: FakeCloudEngine()
        ..script.add(() => gapStream(const Duration(milliseconds: 100), 'b')),
      onDevice: device,
    );
    device.next = 'gap-fb';
    final events = await e.send(noTools).toList();
    // 引擎语义「产出优先」：间隙超时前已达的 'a' 照常透传，端侧兜底产出追加在后。
    expect(events.whereType<CloudTextDelta>().map((d) => d.text).toList(), [
      'a',
      'gap-fb',
    ]);
    expect(c.health, CloudHealth.degraded);
  });

  test('流内事件间隙在预算内不误杀（合法长停顿照常完成）', () async {
    final c = DegradationController(
      firstTokenTimeout: const Duration(milliseconds: 500),
      interEventGapTimeout: const Duration(milliseconds: 300),
    );
    final e = HybridCloudEngine(
      controller: c,
      cloud: FakeCloudEngine()
        ..script.add(() => gapStream(const Duration(milliseconds: 100), 'b')),
      onDevice: device,
    );
    final events = await e.send(noTools).toList();
    expect(events.whereType<CloudTextDelta>().map((d) => d.text).toList(), [
      'a',
      'b',
    ]);
    expect(c.health, CloudHealth.healthy);
  });

  test('取消订阅即联动 cancelActive（§10 ①步端侧路径）', () async {
    controller.reportTransportTimeout(); // 降级态：无工具请求直走端侧
    device.hangUntil = Completer<void>();
    final sub = engine
        .send(noTools)
        .listen(
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

  test('门禁不达标（advisory）：降级态端侧照走，不拦路由（2026-10-31 裁决）', () async {
    controller.reportTransportTimeout();
    device.next = '端侧产出';
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
    final events = await gated.send(noTools).toList();
    expect(checked, isTrue, reason: 'advisory 判定仍执行（留痕可观测）');
    expect(device.prompts, hasLength(1), reason: '门禁只留痕，不拦路由');
    expect(events.whereType<CloudTextDelta>().single.text, '端侧产出');
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

  test('门禁不达标 + 无云端 → 端侧照走（advisory 不构成挡点）', () async {
    controller.reportTransportTimeout();
    device.next = 'advisory 无云端侧';
    final gated = HybridCloudEngine(
      controller: controller,
      cloud: null,
      onDevice: device,
      preferOnDevice: true,
      deviceTierGate: () async => (pass: false, reason: '省电模式'),
    );
    final events = await gated.send(noTools).toList();
    expect(events.whereType<CloudTextDelta>().single.text, 'advisory 无云端侧');
  });

  test('门禁探测异常 → 重探后仍失败仅 advisory 留痕，不拦路由', () async {
    controller.reportTransportTimeout();
    device.next = '端侧产出';
    final gated = HybridCloudEngine(
      controller: controller,
      cloud: cloud,
      onDevice: device,
      preferOnDevice: true,
      deviceTierGate: () async {
        throw Exception('探针通道不可用');
      },
    );
    final events = await gated.send(noTools).toList();
    expect(device.prompts, hasLength(1),
        reason: '探测异常 = 未知态，advisory 层如实留痕不拦截');
    expect(events.whereType<CloudTextDelta>().single.text, '端侧产出');
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

  group('流内裸异常兜底（2026-10-21 真机实测：SiliconFlow 中途关连接）', () {
    // 首 delta 后抛裸 ClientException——package:http 对「响应体读到一半被
    // 对端关闭」的呈现路径（io_client.dart stream onError：HttpException →
    // ClientException 塞进流），不经 send 时 try；旧行为穿透到 UI 错误卡
    // 炸整轮会话（Binder 会话里云端 SSE 是唯一 HTTP 面的实证场景）。
    Stream<CloudStreamEvent> midStreamClientError() async* {
      yield const CloudTextDelta('半句');
      throw http.ClientException(
        'Connection closed while receiving data, '
        'uri=https://api.siliconflow.cn/v1/chat/completions',
      );
    }

    test('带工具请求（无兜底位）→ CloudNetworkException 包装上抛 + 计入降级', () async {
      cloud.script.add(midStreamClientError);
      await expectLater(
        engine.send(withTools).toList(),
        throwsA(isA<CloudNetworkException>().having(
          (e) => e.message,
          'message',
          contains('Connection closed'),
        )),
      );
      expect(controller.health, CloudHealth.degraded);
      expect(device.prompts, isEmpty);
    });

    test('无工具请求（有兜底位）→ 已达 delta 透传 + 端侧兜底产出', () async {
      cloud.script.add(midStreamClientError);
      device.next = '断流兜底';
      final events = await engine.send(noTools).toList();
      // 引擎语义「产出优先」：断流前已达的 '半句' 照常透传，端侧兜底追加在后。
      expect(
        events.whereType<CloudTextDelta>().map((d) => d.text).toList(),
        ['半句', '断流兜底'],
      );
      expect(controller.health, CloudHealth.degraded);
    });

    test('语义排除：InferenceException 直露不进兜底（空产出口径不劣化）', () async {
      cloud.script.add(
        () => Stream<CloudStreamEvent>.error(
          const InferenceException('云端空产出（流完成但零可见内容/工具调用）'),
        ),
      );
      await expectLater(
        engine.send(withTools).toList(),
        throwsA(isA<InferenceException>()),
      );
      expect(controller.health, CloudHealth.healthy);
    });

    test('语义排除：CloudProtocolException 直露（协议违规各有白话文案）', () async {
      cloud.script.add(
        () => errorStream(const CloudProtocolException('流终止未交付 stop_reason')),
      );
      await expectLater(
        engine.send(withTools).toList(),
        throwsA(isA<CloudProtocolException>()),
      );
      expect(controller.health, CloudHealth.healthy);
    });
  });

  group('思考流（2026-10-21 M1，展示 only）', () {
    Stream<CloudStreamEvent> thinkingOnly() async* {
      yield const CloudThinkingDelta('思维链烧光预算');
      yield const CloudDone(finishReason: CloudFinishReason.stop);
    }

    test('思考事件透传（与正文事件保序）', () async {
      cloud.script.add(() async* {
        yield const CloudThinkingDelta('想');
        yield const CloudTextDelta('答');
        yield const CloudDone(finishReason: CloudFinishReason.stop);
      });
      final events = await engine.send(noTools).toList();
      expect(events.whereType<CloudThinkingDelta>().single.text, '想');
      expect(events.whereType<CloudTextDelta>().single.text, '答');
    });

    test('仅思考无正文 → 仍判空产出（sawOutput 排除思考，兜底不被打穿）', () async {
      cloud.script.add(thinkingOnly);
      device.next = '端侧兜底';
      final events = await engine.send(noTools).toList();
      expect(events.whereType<CloudTextDelta>().single.text, '端侧兜底',
          reason: '思考不计入可见产出——T7 空产出口径照常触发');
    });

    test('仅思考无正文 + 带工具（无兜底位）→ 显式 InferenceException', () async {
      cloud.script.add(thinkingOnly);
      await expectLater(
        engine.send(withTools).toList(),
        throwsA(isA<InferenceException>()),
      );
      expect(device.prompts, isEmpty);
    });
  });

  group('端侧引擎死亡无缝切云（on-device S1-5，总纲 §2）', () {
    test('降级态端侧路径 EngineDiedException → 无缝切云产出', () async {
      controller.reportTransportTimeout(); // 进入降级态 → 主入口走端侧
      device.dieOnGenerate = true;
      cloud.script.add(() => textStream('云端接管'));
      final events = await engine.send(noTools).toList();
      expect(events.whereType<CloudTextDelta>().single.text, '云端接管');
      expect(cloud.calls, hasLength(1), reason: '死亡即切云，一次直达');
    });

    test('云端未配置态端侧死亡 → 白话 InferenceException（禁裸抛内部切云信号）', () async {
      final bare = HybridCloudEngine(
        controller: controller,
        cloud: null,
        onDevice: device,
      );
      device.dieOnGenerate = true;
      // 2026-10-31 契约修订：EngineDiedException 是内部切云信号，无云可切时
      // 翻译成白话报错（出路提示），不再裸抛 'EngineDiedException: ...' 上墙。
      await expectLater(
        bare.send(noTools).toList(),
        throwsA(
          isA<InferenceException>().having(
            (e) => e.message,
            'message',
            contains('端侧已中断且未配置云端兜底'),
          ),
        ),
      );
    });

    test('端侧正常产出不经死亡兜底（云端零调用）', () async {
      controller.reportTransportTimeout();
      device.next = '端侧产出';
      final events = await engine.send(noTools).toList();
      expect(events.whereType<CloudTextDelta>().single.text, '端侧产出');
      expect(cloud.calls, isEmpty);
    });
  });

  group('deviceToolPolicy 端侧工具面判据（S2 纯聊天收口）', () {
    test('全为宿主本地元工具 → 端侧放行（降级态云端零调用）', () async {
      controller.reportTransportTimeout();
      device.next = '端侧答复';
      final policyEngine = HybridCloudEngine(
        controller: controller,
        cloud: cloud,
        onDevice: device,
        deviceToolPolicy: (tools) => tools.every(
          (t) => const {'get_connected_apps', 'update_memory'}.contains(t.name),
        ),
      );
      final events = await policyEngine.send(localMetaToolsOnly).toList();
      expect(events.whereType<CloudTextDelta>().single.text, '端侧答复');
      expect(cloud.calls, isEmpty);
    });

    test('含 MCP 服务端工具 → 不放行，走云端（§2 编排约束不变）', () async {
      controller.reportTransportTimeout();
      cloud.script.add(() => textStream('云端编排'));
      final policyEngine = HybridCloudEngine(
        controller: controller,
        cloud: cloud,
        onDevice: device,
        deviceToolPolicy: (tools) =>
            tools.every((t) => t.name == 'get_connected_apps'),
      );
      final events = await policyEngine.send(withServerTool).toList();
      expect(events.whereType<CloudTextDelta>().single.text, '云端编排');
      expect(device.prompts, isEmpty);
    });

    test('未注入判据 → 保守默认：带工具不放行（既有语义回归钉）', () async {
      controller.reportTransportTimeout();
      cloud.script.add(() => textStream('云端'));
      final events = await engine.send(localMetaToolsOnly).toList();
      expect(events.whereType<CloudTextDelta>().single.text, '云端');
      expect(device.prompts, isEmpty);
    });
  });

  group('端侧启用用户覆盖（§16 用户授权覆盖层）', () {
    test('偏好优先端侧：云端健康态也走端侧（云端零调用）', () async {
      device.next = '偏好端侧';
      final e = HybridCloudEngine(
        controller: controller,
        cloud: cloud,
        onDevice: device,
        preferOnDevice: true,
      );
      final events = await e.send(noTools).toList();
      expect(cloud.calls, isEmpty);
      expect(events.whereType<CloudTextDelta>().single.text, '偏好端侧');
    });

    test('门禁不达标 → advisory 留痕不拦截，端侧照走（2026-10-31 裁决）', () async {
      device.next = '门禁放行端侧';
      final e = HybridCloudEngine(
        controller: controller,
        cloud: cloud,
        onDevice: device,
        preferOnDevice: true,
        deviceTierGate: () async => (pass: false, reason: '省电模式'),
      );
      final events = await e.send(noTools).toList();
      expect(device.prompts, hasLength(1), reason: '门禁只留痕，不拦路由');
      expect(cloud.calls, isEmpty);
      expect(events.whereType<CloudTextDelta>().single.text, '门禁放行端侧');
    });

    test('门禁不达标 + 无云端 → 端侧路径（不报错）', () async {
      device.next = 'advisory 端侧无云';
      final e = HybridCloudEngine(
        controller: controller,
        cloud: null,
        onDevice: device,
        preferOnDevice: true,
        deviceTierGate: () async => (pass: false, reason: 'RAM 不足'),
      );
      final events = await e.send(noTools).toList();
      expect(events.whereType<CloudTextDelta>().single.text, 'advisory 端侧无云');
    });

    test('§2 工具面不可被偏好绕过（带 MCP 工具仍走云端）', () async {
      device.next = '不应到达';
      final e = HybridCloudEngine(
        controller: controller,
        cloud: cloud,
        onDevice: device,
        preferOnDevice: true,
        deviceToolPolicy: (tools) => tools.every((t) => t.name == 'get_connected_apps'),
      );
      cloud.script.add(() => textStream('云端编排'));
      final events = await e.send(withServerTool).toList();
      expect(device.prompts, isEmpty, reason: '§2 工具面不受偏好影响');
      expect(events.whereType<CloudTextDelta>().single.text, '云端编排');
    });
  });

  group('DeviceTierGate.ignore 维度放宽（设置页门禁覆盖）', () {
    const bigRam = 12 << 30;
    const bigAvail = 6 << 30;

    test('ignoreAvailRam：可用 RAM 不足但忽略 → 放行（解 12GB 痛点）', () {
      final probe = DeviceProbe(totalRamBytes: bigRam, availRamBytes: 1 << 30);
      expect(DeviceTierGate.check(probe).pass, isFalse);
      expect(DeviceTierGate.check(probe, ignoreAvailRam: true).pass, isTrue);
    });

    test('ignoreBattery：低电量但忽略 → 放行', () {
      final probe = DeviceProbe(
        totalRamBytes: bigRam,
        availRamBytes: bigAvail,
        batteryPct: 5,
      );
      expect(DeviceTierGate.check(probe).pass, isFalse);
      expect(DeviceTierGate.check(probe, ignoreBattery: true).pass, isTrue);
    });

    test('ignoreThermal：过热但忽略 → 放行', () {
      final probe = DeviceProbe(
        totalRamBytes: bigRam,
        availRamBytes: bigAvail,
        thermalStatus: 4,
      );
      expect(DeviceTierGate.check(probe).pass, isFalse);
      expect(DeviceTierGate.check(probe, ignoreThermal: true).pass, isTrue);
    });

    test('RAM 总量 6GB 硬件准入不受 ignoreAvailRam 影响（advisory 层保留判据）', () {
      final weak = DeviceProbe(totalRamBytes: 4 << 30, availRamBytes: bigAvail);
      expect(DeviceTierGate.check(weak, ignoreAvailRam: true).pass, isFalse);
    });
  });

  group('端侧多轮输入面与零产出归因（2026-10-30 真机「第二轮没有输出」）', () {
    test('第二轮（带历史）→ 端侧 prompt 为消息序列 JSON（角色由模板承载）', () async {
      controller.reportTransportTimeout(); // 降级态 → 走端侧
      device.next = '端侧产出';
      await engine
          .send(
            const CloudChatRequest(
              messages: [
                SystemMessage('sys'),
                UserMessage('u1'),
                AssistantMessage(content: 'a1'),
                UserMessage('u2'),
              ],
            ),
          )
          .toList();
      // 2026-10-31 设计修正：单发压平 + 文字标注因复读环退役——prompt =
      // messages JSON，assistant 回答以 assistant 角色独立成轮。
      final turns =
          (jsonDecode(device.prompts.single) as List).cast<Map<String, dynamic>>();
      expect(turns.map((m) => m['role']).toList(),
          ['system', 'user', 'assistant', 'user']);
      expect(turns[1]['content'], 'u1');
      expect(turns[2]['role'], 'assistant', reason: '历史回答独立成 assistant 轮');
      expect(turns[2]['content'], 'a1');
      expect(turns[3]['content'], 'u2');
    });

    test('端侧零产出 → 显式上抛并带真因（禁笼统「空产出」）', () async {
      controller.reportTransportTimeout();
      device.next = null; // 端侧零产出
      device.failureReason = '会话重置失败（reset status=1）';
      await expectLater(
        engine.send(noTools).toList(),
        throwsA(
          isA<InferenceException>().having(
            (e) => e.message,
            'message',
            allOf(contains('端侧生成失败'), contains('会话重置失败')),
          ),
        ),
      );
    });
  });
}
