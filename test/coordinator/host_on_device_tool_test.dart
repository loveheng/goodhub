// 端侧供给面对外导出执行器回归钉（task-capability W5 · 端侧供给面对外导出）。
//
// 红线：① 降级语义显式可知——failFast 失败以 isError 结果返回（content 含
// 原因），宿主侧不自动兜底云端，调用方须自行处置；② 幂等无副作用（K20）；
// ③ schema 单源（toolSchemas/schemaOf 归执行器，Allowlist 不复制文本）；
// ④ 调用方进程死亡联动打断（K17）——协作式打断（订阅取消 → 引擎让槽）+
// 本次调用作废（产出即弃不回程）+ 不计调用方频次。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/caller_death_interrupt.dart';
import 'package:goodhub/coordinator/host_on_device_tool.dart';
import 'package:goodhub/coordinator/supply_quota.dart';
import 'package:goodhub/core/tool_result.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/mcp/sampling.dart';

class _StubCapability implements OnDeviceCapabilityService {
  _StubCapability({this.output = '产出'});

  final String output;
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

/// 挂起不产出的端侧原语桩：模拟长生成在途（打断路径的被测面）。
/// 实现 [OnDeviceInterruptible]——打断经取消钩子下沉（退订 → onCancel）。
class _HangingCapability
    implements OnDeviceCapabilityService, OnDeviceInterruptible {
  final StreamController<EngineChunk> _ctrl = StreamController<EngineChunk>();

  /// 订阅是否被取消（= 引擎 cancel 透传的下沉信号）。
  bool cancelled = false;

  @override
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) async =>
      'unused';

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
  }) {
    _ctrl.onCancel = () {
      cancelled = true;
    };
    return _ctrl.stream;
  }

  @override
  Future<String> completeInterruptible({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
    void Function(Future<void> Function() cancel)? onSubscribed,
  }) async {
    final done = Completer<String>();
    late StreamSubscription<EngineChunk> sub;
    sub = _ctrl.stream.listen(
      (_) {},
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete('');
      },
    );
    _ctrl.onCancel = () {
      cancelled = true;
    };
    onSubscribed?.call(() async {
      await sub.cancel(); // 退订 → onCancel → 引擎让槽信号
      if (!done.isCompleted) {
        done.completeError(const OnDeviceInterruptedException());
      }
    });
    return done.future;
  }
}

void main() {
  Future<ToolExecutionResult> run(HostOnDeviceToolExecutor exe, Map<String, Object?> args) =>
      exe.execute(AssembledToolCall(
        id: 't1',
        name: HostOnDeviceToolExecutor.toolName,
        argumentsJson: jsonEncode(args),
      ));

  tearDown(resetCallerDeathInterruptForTest);

  group('W5 端侧供给面对外导出（on_device_complete）', () {
    test('正常路径：instruction/input 透传，产出透传（isError=false）', () async {
      final exe = HostOnDeviceToolExecutor(_StubCapability(output: '端侧结果'));
      final r = await run(exe, {'instruction': '提取标签', 'input': '原文'});
      expect(r.isError, isFalse);
      expect(r.content, '端侧结果');
    });

    test('降级语义显式可知：未就绪 failFast → isError 且 content 含原因（宿主不兜底云端）',
        () async {
      final cap = _StubCapability()
        ..error = const OnDevicePrimitiveException('端侧会话未就绪（未装载/装载中）');
      final exe = HostOnDeviceToolExecutor(cap);
      final r = await run(exe, {'instruction': 'i', 'input': 'x'});
      expect(r.isError, isTrue, reason: '失败对调用方显式可见（不静默降级）');
      expect(r.content, contains('端侧推理失败'));
      expect(r.content, contains('不兜底云端'),
          reason: '红线：转发方接受降级语义需显式可知');
    });

    test('参数校验：缺 instruction / 缺 input / 非法 JSON → isError', () async {
      final exe = HostOnDeviceToolExecutor(_StubCapability());
      final r1 = await run(exe, {'input': 'x'});
      expect(r1.isError, isTrue);
      expect(r1.content, contains('instruction'));
      final r2 = await run(exe, {'instruction': 'i'});
      expect(r2.isError, isTrue);
      expect(r2.content, contains('input'));
      final r3 = await exe.execute(AssembledToolCall(
          id: 't', name: 'on_device_complete', argumentsJson: '{not json'));
      expect(r3.isError, isTrue);
      expect(r3.content, contains('JSON'));
    });

    test('schema 单源：toolSchemas/schemaOf 同源且 Allowlist 不复制文本', () {
      final schema = HostOnDeviceToolExecutor.schemaOf(
          HostOnDeviceToolExecutor.toolName);
      expect(schema, isNotNull);
      expect(schema['description'],
          HostOnDeviceToolExecutor.toolSchemas().single.description);
      expect(
          schema['inputSchema'],
          HostOnDeviceToolExecutor.toolSchemas().single.parametersSchema);
      // 其他工具名返回空（owner 单源只答自己）。
      expect(HostOnDeviceToolExecutor.schemaOf('other'), isEmpty);
    });
  });

  group('W5 调用方进程死亡联动打断（K17）', () {
    test('调用方死亡 → 协作式打断（订阅取消让槽）+ 本次调用作废 + 不计频次',
        () async {
      final registry = ensureCallerDeathInterruptWired();
      final cap = _HangingCapability();
      // 频次池上限 1：消耗 1 次即超限——用「是否超限」反查是否计过频次。
      final quota = SupplyQuota(frequency: SamplingQuota(maxPerWindow: 1));
      final exe = HostOnDeviceToolExecutor(
        cap,
        quota: quota,
        callerKey: 'com.zzh.goodshare',
      );

      final pending = run(exe, {'instruction': 'i', 'input': 'x'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(registry.activeCount('com.zzh.goodshare'), 1,
          reason: '在途执行已注册打断回调');

      await registry.notifyDeath('com.zzh.goodshare');

      final r = await pending;
      expect(r.isError, isTrue, reason: '调用方已死 → 本次调用作废');
      expect(r.content, contains('作废'));
      expect(cap.cancelled, isTrue,
          reason: '订阅取消 → 透传 cancel(requestId) → 引擎让槽（协作式打断）');
      expect(quota.concurrent, 0, reason: '退出无论成败一律释放执行槽（K22）');
      expect(quota.frequency.peek('host-export', DateTime.now()), isNull,
          reason: '未产出交付 → 不计调用方频次（K22）');
      expect(registry.activeCount('com.zzh.goodshare'), 0,
          reason: '收尾后注销（在途条目清零）');
    });

    test('竞态反向：产出先完成 → 正常返回，不被死亡通知误伤', () async {
      final registry = ensureCallerDeathInterruptWired();
      final exe = HostOnDeviceToolExecutor(
        _StubCapability(output: '端侧结果'),
        callerKey: 'com.zzh.goodshare',
      );
      final r = await run(exe, {'instruction': 'i', 'input': 'x'});
      expect(r.isError, isFalse);
      expect(r.content, '端侧结果');

      // 收尾后再发死亡通知：无在途条目 → 不影响已完成的产出（禁误伤）。
      await registry.notifyDeath('com.zzh.goodshare');
      expect(registry.activeCount('com.zzh.goodshare'), 0);
    });
  });
}
