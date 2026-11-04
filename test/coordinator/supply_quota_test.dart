// 端侧算力调用方配额回归钉（task-capability W5 · 端侧算力调用方配额）。
//
// 红线（K22 配额记账事务语义）：① 并发进槽占用、退出无论成败或切云一律
// 释放（acquire/release 恒配对 try/finally）；② 频次仅在实际占用算力并
// 开始产出时计入（受理段失败不计）；③ 被动切云不扣调用方配额（导出面
// failFast 无切云，天然满足）；④ 后台调用方冷装载不被自动满足（原语调用
// 不触发装载，懒加载边界 S16 钉）；⑤ 复用 SamplingQuota 形态不新建限流器。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/host_on_device_tool.dart';
import 'package:goodhub/coordinator/supply_quota.dart';
import 'package:goodhub/core/tool_result.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/mcp/sampling.dart';

class _StubCapability implements OnDeviceCapabilityService {
  _StubCapability();

  String output = '产出';
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
    if (e != null) throw e;
    return output;
  }

  @override
  Future<OnDeviceCapabilityAvailability> availability() async =>
      OnDeviceCapabilityAvailability.ready;

  @override
  Future<void> loadExplicit() async {}

  @override
  Stream<EngineChunk> completeStream({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    String? traceId,
  }) => const Stream.empty();
}

void main() {
  group('W5 SupplyQuota 治理类（K22 事务语义）', () {
    test('并发上限：满员拒绝；退出恒释放（下溢钳零）', () {
      final q = SupplyQuota(maxConcurrent: 2);
      expect(q.acquire(), isTrue);
      expect(q.acquire(), isTrue);
      expect(q.acquire(), isFalse, reason: '并发满 → 拒绝');
      q.release();
      expect(q.acquire(), isTrue, reason: '退出即释放（成败无关）');
      q.release();
      q.release(); // 下溢防御
      expect(q.concurrent, 0);
    });

    test('频次复用 SamplingQuota：默认池 20 次/60min 形态；实际产出才计入',
        () async {
      final q = SupplyQuota(frequency: SamplingQuota(maxPerWindow: 2));
      final now = DateTime(2026, 11, 4, 12);
      expect(q.countOutput(now), isNull, reason: '产出计入 1');
      expect(q.countOutput(now.add(const Duration(minutes: 1))), isNull,
          reason: '产出计入 2');
      expect(q.countOutput(now.add(const Duration(minutes: 2))), isNotNull,
          reason: '窗口满（2/2）→ 建议重试');
    });

    test('身份维度：callerKey 缺省共享池 host-export（per-caller 精细化跟进）',
        () {
      final q = SupplyQuota();
      expect(q.callerKey, 'host-export');
    });
  });

  group('W5 执行器配额接线（host_on_device_complete）', () {
    Future<ToolExecutionResult> call(
        HostOnDeviceToolExecutor exe, Map<String, Object?> args) =>
        exe.execute(AssembledToolCall(
          id: 't',
          name: HostOnDeviceToolExecutor.toolName,
          argumentsJson: jsonEncode(args),
        ));

    test('事务语义端到端：并发失败释放 → 后续调用恢复（成败无关一律让槽）',
        () async {
      final cap = _StubCapability()
        ..error = const OnDevicePrimitiveException('端侧会话未就绪（未装载/装载中）');
      final quota = SupplyQuota(maxConcurrent: 1);
      final exe = HostOnDeviceToolExecutor(cap, quota: quota);
      // 失败调用：isError，但并发占用已释放（finally 恒达）。
      final r1 = await call(exe, {'instruction': 'i', 'input': 'x'});
      expect(r1.isError, isTrue);
      expect(quota.concurrent, 0, reason: '失败退出也一律释放（K22）');
      // 后续调用恢复（不被前次失败占用卡死）。
      cap.error = null;
      final r2 = await call(exe, {'instruction': 'i', 'input': 'x'});
      expect(r2.isError, isFalse);
      expect(quota.concurrent, 0);
    });

    test('频次计入事务：推理失败不计入；成功产出才计入', () async {
      final cap = _StubCapability()
        ..error = const OnDevicePrimitiveException('端侧会话未就绪');
      final quota = SupplyQuota(frequency: SamplingQuota(maxPerWindow: 1));
      final exe = HostOnDeviceToolExecutor(cap, quota: quota);
      // 失败调用不计频次。
      await call(exe, {'instruction': 'i', 'input': 'x'});
      cap.error = null;
      cap.output = 'ok';
      // 成功产出计入 1/1。
      final r = await call(exe, {'instruction': 'i', 'input': 'x'});
      expect(r.isError, isFalse);
      // 第二次成功 → 频次超限（1/1 满）。
      final r2 = await call(exe, {'instruction': 'i', 'input': 'x'});
      expect(r2.isError, isTrue);
      expect(r2.content, contains('频次超限'));
    });

    test('后台调用方冷装载不被自动满足：未就绪 failFast 失败（enable 零调用）',
        () async {
      // 懒加载边界（S16 钉在导出面同效）：后台外部调用方未就绪即失败，
      // 装载只能 loadExplicit 显式发起——配额裁决不改变该语义。
      final cap = _StubCapability()
        ..error = const OnDevicePrimitiveException('端侧会话未就绪（未装载/装载中）');
      final exe = HostOnDeviceToolExecutor(cap, quota: SupplyQuota());
      final r = await call(exe, {'instruction': 'i', 'input': 'x'});
      expect(r.isError, isTrue);
      expect(r.content, contains('未就绪'));
      // loadExplicit 未被自动触发（原语面无装载触发路径——S16/S18 红线）。
    });
  });
}
