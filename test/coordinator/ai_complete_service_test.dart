// ai/complete 统一受理链验收钉（ai-capability-export M-B）。
//
// 覆盖设计稿 §6 M-B 验收单：路由三态 / 隔离断言（prompt 不入 transcript）/
// 取消幂等 / 死亡清理（K17）/ 状态预判 fast-fail / 保活释放三钥匙 /
// 温控低电量熔断 / 宿主自用抢占外部任务（含打断未让出路径）；
// 附：预算线 / 配额 RESOURCE_BUSY·RATE_LIMIT / AiWire 跨语言冻结 /
// 归因过滤四码（§6.3 风险钉 #2）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart' show ToolExecutor, ToolExecutionResult;
import 'package:goodhub/coordinator/ai_complete_service.dart';
import 'package:goodhub/coordinator/caller_death_interrupt.dart';
import 'package:goodhub/coordinator/host_ai_complete_tool.dart';
import 'package:goodhub/coordinator/supply_task_pool.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:goodhub/coordinator/hybrid_device_leg.dart' show evictionLifecycleDied;
import 'package:goodhub/coordinator/supply_quota.dart';
import 'package:goodhub/core/chat_message_data.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart' show AssembledToolCall;
import 'package:goodhub/llm/device_tier.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/mcp/sampling.dart';

// ---- 桩件 ----

/// 端侧原语桩：可编排 ready/cold/unavailable 三态、产出/挂起、显式失败。
class _StubDevice
    implements OnDeviceCapabilityService, OnDeviceInterruptible {
  _StubDevice();

  OnDeviceCapabilityAvailability state = OnDeviceCapabilityAvailability.ready;
  String output = '端侧产出';
  Object? primitiveError;
  bool loadCalled = false;
  bool cancelled = false;

  /// 挂起模式：completeInterruptible 悬停直到打断（生效路径）或 [release]
  /// （未让出路径的迟到产出）。
  bool hanging = false;

  /// false = 未让出路径（K11）：cancel 只翻旗标不生效，生成照常完成。
  bool interruptThrows = true;
  Completer<String>? _hangGate;
  final Completer<void> _hangStarted = Completer<void>();

  Future<void> waitStarted() => _hangStarted.future;

  /// 未让出路径的迟到产出解除（interruptThrows=false 时才有意义）。
  void release() {
    if (!(_hangGate?.isCompleted ?? true)) _hangGate!.complete(output);
  }

  @override
  Future<OnDeviceCapabilityAvailability> availability() async => state;

  @override
  Future<void> loadExplicit() async => loadCalled = true;

  @override
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) async =>
      await completeInterruptible(
          instruction: instruction, input: input, config: config);

  @override
  Future<String> completeInterruptible({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
    void Function(Future<void> Function() cancel)? onSubscribed,
  }) async {
    lastInstruction = instruction;
    lastInput = input;
    lastConfig = config;
    if (hanging) {
      if (!_hangStarted.isCompleted) _hangStarted.complete();
      final gate = Completer<String>();
      _hangGate = gate;
      onSubscribed?.call(() async {
        cancelled = true;
        if (interruptThrows && !gate.isCompleted) {
          gate.completeError(const OnDeviceInterruptedException());
        }
        // 未让出路径：不抛——打断未生效，生成照常（迟到产出由 release 驱动）。
      });
      return gate.future;
    }
    final e = primitiveError;
    if (e != null) throw e as Exception;
    return output;
  }

  @override
  Stream<EngineChunk> completeStream({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    String? traceId,
  }) => const Stream.empty();

  String? lastInstruction;
  String? lastInput;
  OnDevicePrimitiveConfig? lastConfig;
}

/// 云腿桩（SamplingEngine 端口）：捕获请求形状（隔离断言被测面）。
class _StubCloud implements SamplingEngine {
  List<ChatMessageData>? lastMessages;
  int? lastMaxTokens;
  String output = '云端产出';

  @override
  String get name => 'goodhub-cloud';

  @override
  Stream<String> sendText({
    required List<ChatMessageData> messages,
    required int maxTokens,
  }) async* {
    lastMessages = messages;
    lastMaxTokens = maxTokens;
    yield output;
  }
}

void main() {
  setUp(AiCompleteService.resetForTest);

  Future<List<Map<String, Object?>>> accept(
    AiCompleteService svc,
    Map<String, Object?> params, {
    Object id = 'srv_1',
    String callerKey = 'com.t.app',
  }) async {
    final frames = <Map<String, Object?>>[];
    await svc.handleAiMethod(
      method: AiWire.methodComplete,
      id: id,
      params: params,
      caller: null,
      callerKeyFallback: callerKey,
      emit: frames.add,
    );
    return frames;
  }

  Map<String, Object?> params({
    String instruction = '提取关键词',
    String input = '原文内容',
    Object? config,
    Object? progressToken,
  }) =>
      {
        'instruction': instruction,
        'input': input,
        'config': ?config,
        if (progressToken != null)
          '_meta': {'progressToken': progressToken},
      };

  Map<String, Object?>? errorFrameOf(List<Map<String, Object?>> frames) =>
      frames.where((f) => f['error'] != null).isEmpty
          ? null
          : frames.firstWhere((f) => f['error'] != null);

  test('AiWire 跨语言冻结：与契约仓 McpContract.AI_* 字面量逐值一致', () {
    // 契约 0.4.0（goodhub-mcp-sdk :contract）十二码 + method + phase；
    // 任一漂移 = 调用方升阶分流契约破坏（Dart 侧字面量单点 = AiWire）。
    expect(AiWire.methodComplete, 'ai/complete');
    expect(AiWire.methodCancel, 'ai/cancel');
    expect(AiWire.failureRpcCode, -32000);
    expect(AiWire.keyRetryAfterMs, 'retry_after_ms');
    expect(AiWire.keyCancelId, 'cancel_id');
    expect(AiWire.progressMetaPhase, 'phase');
    expect(
      {
        AiWire.failModelCold, AiWire.failResourceBusy, AiWire.failHostOffline,
        AiWire.failHostTerminated, AiWire.failBudgetExceeded,
        AiWire.failUnauthorized, AiWire.failRateLimit,
        AiWire.failCallerNotInForeground, AiWire.failUserRejected,
        AiWire.failEngineFailed, AiWire.failDeviceThrottled,
        AiWire.failPreemptedByHost,
      },
      {
        'MODEL_COLD', 'RESOURCE_BUSY', 'HOST_OFFLINE', 'HOST_TERMINATED',
        'BUDGET_EXCEEDED', 'UNAUTHORIZED', 'RATE_LIMIT',
        'CALLER_NOT_IN_FOREGROUND', 'USER_REJECTED', 'ENGINE_FAILED',
        'DEVICE_THROTTLED', 'PREEMPTED_BY_HOST',
      },
      reason: '十二码线级取值（含 DEVICE_THROTTLED / PREEMPTED_BY_HOST）',
    );
  });

  test('路由三态：端侧直出 / 云腿裁决 / 双腿缺 HOST_OFFLINE', () async {
    // ① 端侧（缺省路由 = 端侧优先）。
    AiCompleteService.configure(onDevice: _StubDevice());
    var frames = await accept(AiCompleteService.instance, params());
    final result = frames.singleWhere((f) => f['result'] != null);
    expect((result['result'] as Map)['model'], 'goodhub-on-device');

    // ② 云腿（routeResolver 裁决 = cloud）。
    final cloud = _StubCloud();
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      cloudEngine: cloud,
      routeResolver: () async => AiRouteLeg.cloud,
    );
    frames = await accept(AiCompleteService.instance, params());
    expect((frames.singleWhere((f) => f['result'] != null)['result']
        as Map)['model'], 'goodhub-cloud');

    // ③ 双腿皆缺 = 宿主不可达（禁伪造能力）。
    AiCompleteService.resetForTest();
    frames = await accept(AiCompleteService.instance, params());
    final err = errorFrameOf(frames)!;
    expect((((err['error'] as Map)['data']) as Map)['status'], 'HOST_OFFLINE');
  });

  test('隔离断言：两腿只收请求自带内容（prompt 不入 transcript / 无历史注入）',
      () async {
    final device = _StubDevice();
    final cloud = _StubCloud();
    AiCompleteService.configure(
      onDevice: device,
      cloudEngine: cloud,
      routeResolver: () async => AiRouteLeg.cloud,
    );
    await accept(AiCompleteService.instance,
        params(instruction: '摘要', input: '正文甲'));
    // 云腿请求形状 = [System(instruction), User(input)] 单对——无历史轮、
    // 无记忆沙盒注入、无 workspace 上下文（K20 临时会话语义的行为钉）。
    final msgs = cloud.lastMessages!;
    expect(msgs.length, 2);
    expect(msgs[0], isA<SystemChatMessage>());
    expect((msgs[0] as SystemChatMessage).content, '摘要');
    expect(msgs[1], isA<UserChatMessage>());
    expect((msgs[1] as UserChatMessage).content, '正文甲');

    AiCompleteService.resetForTest();
    AiCompleteService.configure(onDevice: device);
    await accept(AiCompleteService.instance,
        params(instruction: '提取', input: '正文乙'));
    expect(device.lastInstruction, '提取');
    expect(device.lastInput, '正文乙');
  });

  test('状态预判 fast-fail：零等待 + 冷态 → MODEL_COLD 一 RTT（不装载）', () async {
    final device = _StubDevice()
      ..state = OnDeviceCapabilityAvailability.cold;
    AiCompleteService.configure(onDevice: device);
    final frames = await accept(AiCompleteService.instance, params());
    final err = errorFrameOf(frames)!;
    expect(((err['error'] as Map)['data']) as Map, containsPair('status', 'MODEL_COLD'));
    expect(device.loadCalled, isFalse,
        reason: '零等待通道不触发装载（S16 懒加载边界）');
  });

  test('异步可等冷启动：progressToken → LOADING_MODEL → loadExplicit → 产出',
      () async {
    final device = _StubDevice()
      ..state = OnDeviceCapabilityAvailability.cold;
    AiCompleteService.configure(onDevice: device);
    final frames = await accept(
      AiCompleteService.instance,
      params(progressToken: 'tok_1'),
    );
    final phases = frames
        .where((f) => f['method'] == 'notifications/progress')
        .map((f) =>
            ((((f['params'] as Map)['_meta']) as Map)['phase']) as String)
        .toList();
    expect(phases, contains('LOADING_MODEL'));
    expect(phases, contains('GENERATING'));
    expect(device.loadCalled, isTrue, reason: '异步受理 = 显式调用方任务，冷装载合法');
    final result = frames.singleWhere((f) => f['result'] != null);
    expect((result['result'] as Map)['model'], 'goodhub-on-device');
  });

  group('受理期保活（三钥匙释放）', () {
    test('冷装载持有 → 任务终态释放（防抖：热态零保活）', () async {
      final device = _StubDevice()
        ..state = OnDeviceCapabilityAvailability.cold;
      final ka = SupplyKeepalive();
      AiCompleteService.configure(onDevice: device, keepalive: ka);
      await accept(AiCompleteService.instance,
          params(progressToken: 'tok_ka'));
      expect(ka.heldCount, 0, reason: '任务终态 = 钥匙 1 释放');
    });

    test('cancel 释放（钥匙 2）', () async {
      final device = _StubDevice()
        ..state = OnDeviceCapabilityAvailability.cold
        ..hanging = true;
      final ka = SupplyKeepalive();
      AiCompleteService.configure(onDevice: device, keepalive: ka);
      final done = accept(AiCompleteService.instance,
          params(progressToken: 'tok_c'));
      await device.waitStarted();
      await AiCompleteService.instance.handleAiMethod(
        method: AiWire.methodCancel,
        id: 'srv_cancel',
        params: {'cancel_id': 'srv_1'},
        caller: null,
        callerKeyFallback: 'com.t.app',
        emit: (_) {},
      );
      await done;
      expect(device.cancelled, isTrue);
      expect(ka.heldCount, 0, reason: 'cancel = 钥匙 2 释放');
    });

    test('调用方死亡释放（钥匙 3，K17 同一注册表）', () async {
      final registry = CallerDeathInterrupt();
      callerDeathInterruptSingleton = registry;
      addTearDown(() => callerDeathInterruptSingleton = null);
      final device = _StubDevice()
        ..state = OnDeviceCapabilityAvailability.cold
        ..hanging = true;
      final ka = SupplyKeepalive();
      AiCompleteService.configure(onDevice: device, keepalive: ka);
      final done = accept(AiCompleteService.instance,
          params(progressToken: 'tok_d'), callerKey: 'com.t.dead');
      await device.waitStarted();
      expect(ka.heldCount, 1, reason: '冷装载窗口保活在持');
      await registry.notifyDeath('com.t.dead');
      await done;
      expect(device.cancelled, isTrue);
      expect(ka.heldCount, 0, reason: '死亡 = 钥匙 3 释放（不常驻）');
    });
  });

  test('ai/cancel 幂等：命中摘除 + 未命中/重复静默确认；被取消请求零终帧',
      () async {
    final device = _StubDevice()..hanging = true;
    AiCompleteService.configure(onDevice: device);
    final frames = <Map<String, Object?>>[];
    final done = AiCompleteService.instance.handleAiMethod(
      method: AiWire.methodComplete,
      id: 'srv_9',
      params: params(progressToken: 'tok_x'),
      caller: null,
      callerKeyFallback: 'com.t.app',
      emit: frames.add,
    );
    await device.waitStarted();

    Future<List<Map<String, Object?>>> cancel(String cancelId) async {
      final ack = <Map<String, Object?>>[];
      await AiCompleteService.instance.handleAiMethod(
        method: AiWire.methodCancel,
        id: 'srv_ack',
        params: {AiWire.keyCancelId: cancelId},
        caller: null,
        callerKeyFallback: 'com.t.app',
        emit: ack.add,
      );
      return ack;
    }

    final first = await cancel('srv_9');
    expect(first.single['result'], <String, Object?>{},
        reason: '命中 → 空 result 确认');
    final again = await cancel('srv_9');
    expect(again.single['result'], <String, Object?>{},
        reason: '重复/已完成 → 幂等静默确认');
    final ghost = await cancel('srv_never');
    expect(ghost.single['result'], <String, Object?>{});

    await done;
    expect(frames.where((f) => f['id'] == 'srv_9' && f['error'] != null),
        isEmpty, reason: '被取消请求不发终帧（调用方以 cancel ack 本地收口）');
  });

  test('HardwareGuard：温控 ≥SEVERE / 低电量未充电 → DEVICE_THROTTLED（云腿不拦）',
      () async {
    // ① 温控 SEVERE（status=3）。
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      probe: () async => const DeviceProbe(thermalStatus: 3),
    );
    var frames = await accept(AiCompleteService.instance, params());
    expect(((errorFrameOf(frames)!.clone()['error'] as Map)['data']
        as Map)['status'], 'DEVICE_THROTTLED');

    // ② 低电量且未充电。
    AiCompleteService.resetForTest();
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      probe: () async => const DeviceProbe(batteryPct: 10, isCharging: false),
    );
    frames = await accept(AiCompleteService.instance, params());
    expect(((errorFrameOf(frames)!.clone()['error'] as Map)['data']
        as Map)['status'], 'DEVICE_THROTTLED');

    // ③ 探针未知（null/-1）= 放行（未知 ≠ 已知有害）。
    AiCompleteService.resetForTest();
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      probe: () async => const DeviceProbe(thermalStatus: -1),
    );
    frames = await accept(AiCompleteService.instance, params());
    expect(errorFrameOf(frames), isNull);

    // ④ 同探针 + 云腿路由 → 不拦（硬件自保只断端侧）。
    AiCompleteService.resetForTest();
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      cloudEngine: _StubCloud(),
      routeResolver: () async => AiRouteLeg.cloud,
      probe: () async => const DeviceProbe(thermalStatus: 3),
    );
    frames = await accept(AiCompleteService.instance, params());
    expect(errorFrameOf(frames), isNull, reason: '云腿不受设备温控熔断约束');
  });

  test('QoS 抢占：宿主自用进入 → 在途外部任务收 PREEMPTED_BY_HOST + 建议退避；'
      '打断未让出路径迟到产出丢弃', () async {
    final device = _StubDevice()
      ..hanging = true
      ..interruptThrows = false; // 未让出路径（K11）：cancel 不生效
    AiCompleteService.configure(onDevice: device);
    final frames = <Map<String, Object?>>[];
    final done = AiCompleteService.instance.handleAiMethod(
      method: AiWire.methodComplete,
      id: 'srv_p',
      params: params(),
      caller: null,
      callerKeyFallback: 'com.t.app',
      emit: frames.add,
    );
    await device.waitStarted();
    expect(AiCompleteService.instance.inflightCount, 1);

    await AiCompleteService.preemptAllForHostUse();
    final err = errorFrameOf(frames)!;
    final data = (err['error'] as Map)['data'] as Map;
    expect(data['status'], 'PREEMPTED_BY_HOST');
    expect(data[AiWire.keyRetryAfterMs], isA<int>(),
        reason: 'retry_after_ms 仅提示非承诺');

    // 打断未让出路径（K11）：桩 cancel 不抛中断异常、生成照常「完成」——
    // 迟到产出必须丢弃（终帧已在抢占时刻发出，禁二次回写）。
    device.release();
    await done;
    expect(frames.where((f) => f['result'] != null), isEmpty,
        reason: '迟到产出丢弃（PREEMPTED_BY_HOST 已终态）');
  });

  test('预算线：输入超 128KB（UTF-8 字节）→ BUDGET_EXCEEDED 诚实降级', () async {
    AiCompleteService.configure(onDevice: _StubDevice());
    final big = '汉' * (kAiInputMaxBytes ~/ 3 + 100); // 每字 3 字节
    final frames = await accept(
        AiCompleteService.instance, params(input: big));
    expect(((errorFrameOf(frames)!.clone()['error'] as Map)['data']
        as Map)['status'], 'BUDGET_EXCEEDED');
  });

  test('K22 配额：并发满 → RESOURCE_BUSY；频次产出计入超限 → RATE_LIMIT',
      () async {
    // ① 并发满（上限 1，外部占住槽）。
    final quota = SupplyQuota(maxConcurrent: 1)..acquire();
    AiCompleteService.configure(onDevice: _StubDevice(), quota: quota);
    var frames = await accept(AiCompleteService.instance, params());
    var data =
        (errorFrameOf(frames)!.clone()['error'] as Map)['data'] as Map;
    expect(data['status'], 'RESOURCE_BUSY');
    expect(data[AiWire.keyRetryAfterMs], isA<int>());

    // ② 频次：上限 1，首请求成功产出计入 → 第二请求 RATE_LIMIT（K22
    // 「产出才计」的行为钉：若受理段误计或漏计，此例必红）。
    AiCompleteService.resetForTest();
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      quota: SupplyQuota(frequency: SamplingQuota(maxPerWindow: 1)),
    );
    frames = await accept(AiCompleteService.instance, params());
    expect(errorFrameOf(frames), isNull, reason: '首请求产出成功');
    frames = await accept(AiCompleteService.instance,
        params(input: '第二笔'), id: 'srv_2');
    data = (errorFrameOf(frames)!.clone()['error'] as Map)['data'] as Map;
    expect(data['status'], 'RATE_LIMIT');
    expect(data[AiWire.keyRetryAfterMs], isA<int>());
  });

  test('云腿 responseFormat 显式拒服务（S17b：结构化场景禁无约束降级）', () async {
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      cloudEngine: _StubCloud(),
      routeResolver: () async => AiRouteLeg.cloud,
    );
    final frames = await accept(
      AiCompleteService.instance,
      params(config: {
        'responseFormat': {'type': 'json', 'value': '{}'}
      }),
    );
    expect(((errorFrameOf(frames)!.clone()['error'] as Map)['data']
        as Map)['status'], 'ENGINE_FAILED');
  });

  test('归因过滤四码（§6.3 风险钉 #2）：外部终止码不入端侧性能画像（单源扩展）',
      () {
    for (final code in [
      'preempted_by_host',
      'device_throttled',
      'caller_cancelled',
      'caller_died',
    ]) {
      expect(evictionLifecycleDied('engine aborted: $code'), isTrue,
          reason: '$code 采样在过滤单源丢弃（0 token 采样禁折算端侧劣化）');
    }
    // 既有分码不回归。
    expect(evictionLifecycleDied('SESSION_ABORTED_BY_EVICTION'), isTrue);
    expect(evictionLifecycleDied('data plane EOF'), isTrue);
    // 真死亡类照记（返回 false = 记 crash）。
    expect(evictionLifecycleDied('SIGSEGV at null'), isFalse);
  });

  group('host__ai__complete 网关投影（M-D §3.3）', () {
    test('语义同源：经 completeCore 受理链（配额/路由/隔离单源）+ 结构化失败透出',
        () async {
      final device = _StubDevice()..output = '投影产出';
      AiCompleteService.configure(onDevice: device);
      final executor =
          HostAiCompleteExecutor(inner: const _PassthroughExecutor());

      // ① 成功路径：受理链产出（model 标记随附）。
      final ok = await executor.execute(_call(jsonEncode({
        'instruction': '提取',
        'input': '原文',
      })));
      expect(ok.isError, isFalse);
      final out = jsonDecode(ok.content) as Map;
      expect(out['text'], '投影产出');
      expect(out['model'], 'goodhub-on-device');

      // ② 结构化失败透出（十二码 + retry_after_ms）。
      final busy = SupplyQuota(maxConcurrent: 1)..acquire();
      AiCompleteService.resetForTest();
      AiCompleteService.configure(onDevice: device, quota: busy);
      final fail = await executor.execute(_call(jsonEncode({
        'instruction': '提取',
        'input': '原文',
      })));
      expect(fail.isError, isTrue);
      final err = jsonDecode(fail.content) as Map;
      expect(err['status'], 'RESOURCE_BUSY');
      expect(err['retry_after_ms'], isA<int>());

      // ③ 参数校验（缺 instruction）。
      final bad = await executor.execute(_call(jsonEncode({'input': 'x'})));
      expect(bad.isError, isTrue);
      expect(bad.content, contains('instruction'));
    });

    test('schema 单源 + 非本名透传（链语义：兜底层可达）', () {
      final schema = HostAiCompleteExecutor.schemaOf('ai_complete');
      expect(schema, isNotNull);
      expect(
          (schema['inputSchema'] as Map)['required'], contains('instruction'));
      expect(HostAiCompleteExecutor.schemaOf('other'), isEmpty);
    });
  });
  group('联合态收编（契约 0.5.0 §8.7：allow_deferred）', () {
    late Directory poolDir;
    late SupplyTaskPool pool;
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      AiCompleteService.resetForTest();
      poolDir = await Directory.systemTemp.createTemp('ai-deferred-test');
      pool = SupplyTaskPool(dirResolver: () async => poolDir);
    });
    tearDown(() async {
      if (await poolDir.exists()) await poolDir.delete(recursive: true);
    });
  
    test('冷态 + allow_deferred → 原子入池回执（先于 fast-fail，不等装载）',
        () async {
      final device = _StubDevice()
        ..state = OnDeviceCapabilityAvailability.cold;
      AiCompleteService.configure(
        onDevice: device,
        taskPool: pool,
      );
      final frames = await accept(
        AiCompleteService.instance,
        {
          'instruction': '分析',
          'input': '原文',
          'allow_deferred': true,
        },
        id: 'srv_def1',
      );
      final result = frames.singleWhere((f) => f['result'] != null);
      final out =
          ((result['result'] as Map)['content'] as Map)['text'] as String;
      final j = jsonDecode(out) as Map;
      expect(j['execution_mode'], 'deferred',
          reason: '冷态 + 显式 opt-in → 联合态回执（契约 §8.7）');
      expect((j['task_id'] as String), isNotEmpty);
      expect(j['status'], 'queued');
      expect((j['expiry_ms'] as num), greaterThan(0));
      expect(device.loadCalled, isFalse, reason: '入池即回，不触发装载');
    });
  
    test('冷态缺省（无 allow_deferred）→ MODEL_COLD fast-fail（存量零变化）',
        () async {
      final device = _StubDevice()
        ..state = OnDeviceCapabilityAvailability.cold;
      AiCompleteService.configure(
        onDevice: device,
        taskPool: pool,
      );
      final frames = await accept(
        AiCompleteService.instance,
        {'instruction': '分析', 'input': '原文'},
        id: 'srv_def2',
      );
      final err = frames.firstWhere((f) => f['error'] != null);
      expect(((err['error'] as Map)['data'] as Map)['status'], 'MODEL_COLD',
          reason: '缺省 false = 冷态同步 failFast（0.4.0 存量语义）');
    });
  
    test('入池配额满 → 回落同步错误语义（显式可知，禁静默）', () async {
      final device = _StubDevice()
        ..state = OnDeviceCapabilityAvailability.cold;
      AiCompleteService.configure(
        onDevice: device,
        taskPool: pool,
      );
      // 填满 per-caller 队列（W6 配额：per-caller 8 条）。
      for (var i = 0; i < 8; i++) {
        await pool.submit(
          callerKey: 'com.t.app',
          instruction: 'i$i',
          input: 'x',
        );
      }
      final frames = await accept(
        AiCompleteService.instance,
        {
          'instruction': '分析',
          'input': '原文',
          'allow_deferred': true,
        },
        id: 'srv_def3',
      );
      final err = frames.firstWhere((f) => f['error'] != null);
      expect(
          ((err['error'] as Map)['data'] as Map)['status'], 'MODEL_COLD',
          reason: '入池失败回落同步 failFast（调用方自处）');
    });
  });

}

/// 链尾桩（透传语义的可达性验证用）。
class _PassthroughExecutor implements ToolExecutor {
  const _PassthroughExecutor();

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async =>
      const ToolExecutionResult(content: 'passed-through');
}

AssembledToolCall _call(String json) => AssembledToolCall(
    id: 't', name: HostAiCompleteExecutor.toolName, argumentsJson: json);

extension on Map<String, Object?> {
  // 测试辅助：防 singleWhere 后原地改写（纯拷贝语义）。
  Map<String, Object?> clone() => Map<String, Object?>.of(this);
}
