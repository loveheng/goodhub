// AppCapabilityProfile 处理模型验收钉（ai-capability-export M-C，设计稿 §4/§5）。
//
// 覆盖：信任三档各一例（§4.1 分档配额/前台约束）/ per-caller 超限拒绝话术 /
// lifecyclePolicy 前台探针三态（拒/未知放行/同签名不探）/ 违规 3 次冻结与
// 用户面板解冻（含持久化恢复）/ ops 审计写达。
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/ai_complete_service.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubDevice
    implements OnDeviceCapabilityService, OnDeviceInterruptible {
  String? output = '端侧产出';
  Object? error;

  @override
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) async {
    final e = error;
    if (e != null) throw e as Exception;
    return output!;
  }

  @override
  Future<OnDeviceCapabilityAvailability> availability() async =>
      OnDeviceCapabilityAvailability.ready;

  @override
  Future<void> loadExplicit() async {}

  @override
  Future<String> completeInterruptible({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
    void Function(Future<void> Function() cancel)? onSubscribed,
  }) =>
      complete(
          instruction: instruction,
          input: input,
          config: config,
          fallback: fallback,
          traceId: traceId);

  @override
  Stream<EngineChunk> completeStream({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    String? traceId,
  }) =>
      const Stream.empty();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AiCompleteService.resetForTest();
  });

  group('信任三档（§4.1 分档）', () {
    test('同签名生态：并发 2 + 后台放行（不探前台）', () async {
      final registry = AppCapabilityRegistry(isSameSignature: (_) => true);
      final p = await registry.profileFor('com.zzh.goodshare');
      expect(p.tier, AiTrustTier.sameSignature);
      expect(p.quota.maxConcurrent, 2);
      expect(p.requiresForeground, isFalse);
      // 同签名档不挂前台探针也不拦（探针在场也跳过——档案 requiresForeground=false）。
      var probed = false;
      AiCompleteService.configure(
        onDevice: _StubDevice(),
        capabilityRegistry: registry,
        foregroundProbe: (_) async {
          probed = true;
          return false; // 即便在后台
        },
      );
      final frames = <Map<String, Object?>>[];
      await AiCompleteService.instance.handleAiMethod(
        method: AiWire.methodComplete,
        id: 'srv_t1',
        params: {'instruction': 'i', 'input': 'x'},
        caller: null,
        callerKeyFallback: 'com.zzh.goodshare',
        emit: frames.add,
      );
      expect(probed, isFalse, reason: '同签名档后台放行（lifecyclePolicy 不探）');
      expect(frames.where((f) => f['result'] != null), isNotEmpty);
    });

    test('已信任第三方：并发 1 + 仅前台（探针 false → CALLER_NOT_IN_FOREGROUND）',
        () async {
      final registry = AppCapabilityRegistry();
      final p = await registry.profileFor('com.third.app');
      expect(p.tier, AiTrustTier.trustedThirdParty);
      expect(p.quota.maxConcurrent, 1);
      expect(p.requiresForeground, isTrue);
      AiCompleteService.configure(
        onDevice: _StubDevice(),
        capabilityRegistry: registry,
        foregroundProbe: (_) async => false,
      );
      final frames = <Map<String, Object?>>[];
      await AiCompleteService.instance.handleAiMethod(
        method: AiWire.methodComplete,
        id: 'srv_t2',
        params: {'instruction': 'i', 'input': 'x'},
        caller: null,
        callerKeyFallback: 'com.third.app',
        emit: frames.add,
      );
      final err = frames.firstWhere((f) => f['error'] != null);
      expect(((err['error'] as Map)['data'] as Map)['status'],
          'CALLER_NOT_IN_FOREGROUND');
      expect((err['error'] as Map)['message'], contains('前台'));
    });

    test('探针未知（null）= 放行；远程会话档（retier）不要求前台', () async {
      final registry = AppCapabilityRegistry();
      await registry.profileFor('com.third.app2');
      registry.retier('com.third.app2', AiTrustTier.remoteSession);
      AiCompleteService.configure(
        onDevice: _StubDevice(),
        capabilityRegistry: registry,
        foregroundProbe: (_) async => null, // 未知（特权未接通）= 放行
      );
      final frames = <Map<String, Object?>>[];
      await AiCompleteService.instance.handleAiMethod(
        method: AiWire.methodComplete,
        id: 'srv_t3',
        params: {'instruction': 'i', 'input': 'x'},
        caller: null,
        callerKeyFallback: 'com.third.app2',
        emit: frames.add,
      );
      expect(frames.where((f) => f['result'] != null), isNotEmpty,
          reason: '未知 ≠ 已知有害（DeviceTierGate 同款口径）');
    });
  });

  test('per-caller 超限拒绝话术：并发满 RESOURCE_BUSY（档案配额生效）', () async {
    final registry = AppCapabilityRegistry(); // 第三方档：并发 1
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      capabilityRegistry: registry,
    );
    // 占住档案配额（模拟另一在途请求）。
    (await registry.profileFor('com.third.app3')).quota.acquire();
    final frames = <Map<String, Object?>>[];
    await AiCompleteService.instance.handleAiMethod(
      method: AiWire.methodComplete,
      id: 'srv_q',
      params: {'instruction': 'i', 'input': 'x'},
      caller: null,
      callerKeyFallback: 'com.third.app3',
      emit: frames.add,
    );
    final err = frames.firstWhere((f) => f['error'] != null);
    final data = (err['error'] as Map)['data'] as Map;
    expect(data['status'], 'RESOURCE_BUSY');
    expect(data[AiWire.keyRetryAfterMs], isA<int>());
    expect((err['error'] as Map)['message'], contains('受理槽占满'));
  });

  group('违规冻结与解冻（§5 安全防火墙）', () {
    test('连续 3 次内容违规 → 冻结（UNAUTHORIZED）→ 用户面板解冻恢复', () async {
      final registry = AppCapabilityRegistry();
      final device =
          _StubDevice()..error = const OnDevicePrimitiveException('PII 拦截（fail-closed）');
      AiCompleteService.configure(
          onDevice: device, capabilityRegistry: registry);

      Future<List<Map<String, Object?>>> call(String id) async {
        final frames = <Map<String, Object?>>[];
        await AiCompleteService.instance.handleAiMethod(
          method: AiWire.methodComplete,
          id: id,
          params: {'instruction': 'i', 'input': 'x'},
          caller: null,
          callerKeyFallback: 'com.bad.app',
          emit: frames.add,
        );
        return frames;
      }

      for (var i = 1; i <= 3; i++) {
        final frames = await call('srv_v$i');
        expect(
            ((frames.firstWhere((f) => f['error'] != null)['error'] as Map)
                ['data'] as Map)['status'],
            'USER_REJECTED',
            reason: '第 $i 次违规（PII → USER_REJECTED）');
      }
      expect(registry.isRevoked('com.bad.app'), isTrue, reason: '3 次连续违规 → 冻结');
      // 冻结后受理段拒绝（scope 撤销）。
      final frozen = await call('srv_v4');
      final err = frozen.firstWhere((f) => f['error'] != null);
      expect(((err['error'] as Map)['data'] as Map)['status'], 'UNAUTHORIZED');
      expect((err['error'] as Map)['message'], contains('冻结'));

      // 用户面板解冻 → 恢复受理（违规计数归零）。
      await registry.unfreeze('com.bad.app');
      expect(registry.isRevoked('com.bad.app'), isFalse);
      device.error = null; // 清桩错误——验「冻结解除」而非「原语恢复」
      final after = await call('srv_v5');
      expect(after.where((f) => f['result'] != null), isNotEmpty,
          reason: '解冻后恢复受理');
    });

    test('冻结集合持久化：新注册表（模拟重启）恢复冻结态', () async {
      final registry = AppCapabilityRegistry();
      await registry.reportViolation('com.bad.app2', 'content_filter 拒绝');
      await registry.reportViolation('com.bad.app2', 'content_filter 拒绝');
      expect(await registry.reportViolation('com.bad.app2', 'content_filter 拒绝'),
          isTrue, reason: '第三次触发冻结');
      // 模拟进程重启：新注册表实例从 prefs 恢复。
      final registry2 = AppCapabilityRegistry();
      final p2 = await registry2.profileFor('com.bad.app2');
      expect(p2.revoked, isTrue, reason: '冻结是治理终态（持久化），重启不清');
    });

    test('受理成功复位连续计数：2 次违规 + 成功 + 2 次违规 = 不足冻结', () async {
      final registry = AppCapabilityRegistry();
      final device = _StubDevice();
      AiCompleteService.configure(onDevice: device, capabilityRegistry: registry);

      Future<void> fail(String id) async {
        device.error = const OnDevicePrimitiveException('PII 拦截（fail-closed）');
        final frames = <Map<String, Object?>>[];
        await AiCompleteService.instance.handleAiMethod(
          method: AiWire.methodComplete, id: id,
          params: {'instruction': 'i', 'input': 'x'},
          caller: null, callerKeyFallback: 'com.r.app', emit: frames.add);
        device.error = null; // 下一轮成功
      }

      Future<void> ok(String id) async {
        final frames = <Map<String, Object?>>[];
        await AiCompleteService.instance.handleAiMethod(
          method: AiWire.methodComplete, id: id,
          params: {'instruction': 'i', 'input': 'x'},
          caller: null, callerKeyFallback: 'com.r.app', emit: frames.add);
      }

      await fail('r1');
      await fail('r2');
      await ok('r3'); // 成功复位
      await fail('r4');
      await fail('r5');
      expect(registry.isRevoked('com.r.app'), isFalse,
          reason: '「连续触发」语义：成功复位计数（2+2 不足 3）');
    });
  });

  test('ops 审计：受理/路由全记（route 带 leg、ok 布尔、耗时）', () async {
    final audits = <Map<String, Object?>>[];
    AiCompleteService.configure(
      onDevice: _StubDevice(),
      auditSink: ({required caller, required method, required route,
          required ok, required durationMs, note}) async {
        audits.add({'caller': caller, 'method': method, 'route': route,
            'ok': ok, 'ms': durationMs, 'note': note});
      },
    );
    final frames = <Map<String, Object?>>[];
    await AiCompleteService.instance.handleAiMethod(
      method: AiWire.methodComplete,
      id: 'srv_a',
      params: {'instruction': 'i', 'input': 'x'},
      caller: null,
      callerKeyFallback: 'com.a.app',
      emit: frames.add,
    );
    expect(audits, hasLength(1));
    expect(audits.single['caller'], 'com.a.app');
    expect(audits.single['route'], 'goodhub-on-device');
    expect(audits.single['ok'], isTrue);
  });
}
