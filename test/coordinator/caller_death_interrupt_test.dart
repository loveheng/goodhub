// W5 调用方进程死亡联动打断回归钉。
//
// 红线：① 新增链路——既有死亡代理（binderDied 收敛宿主 client 在途）不覆盖
// 反向路径；② 协作式打断：completeStream 订阅取消 → 透传 cancel(requestId)
// 引擎让槽；③ 作废本次调用：产出即弃不回程、不扣频次（K22）；④ mcp 层钩子
// 由装配层桥接（mcp 不反向依赖 coordinator）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/caller_death_interrupt.dart';
import 'package:goodhub/coordinator/host_on_device_tool.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';

class _StubCapability implements OnDeviceCapabilityService {
  _StubCapability({this.onStream});

  /// 流建立回调（测试在订阅建立后触发死亡打断）。
  final void Function()? onStream;

  @override
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) async => '聚合产出';

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
    onStream?.call();
    // 慢流：首块后长时间不再产出（模拟在途执行被死亡打断）。
    Future<EngineChunk> delayed() => Future<EngineChunk>.delayed(
        const Duration(milliseconds: 10),
        () => const EngineChunk(deltaText: '半截'));
    return () async* {
      yield await delayed();
      await Future<void>.delayed(const Duration(minutes: 5)); // 长挂：等打断
    }();
  }
}

/// 桩的可中断面（W5 死亡联动承接）：completeInterruptible 慢执行 +
/// onSubscribed 交出幂等取消钩子；打断触发 → OnDeviceInterruptedException。
class _InterruptibleStub extends _StubCapability
    implements OnDeviceInterruptible {
  _InterruptibleStub({super.onStream});

  @override
  Future<String> completeInterruptible({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
    void Function(Future<void> Function() cancel)? onSubscribed,
  }) async {
    onStream?.call(); // 订阅建立信号（流已建立、打断注册窗口开启）
    // 慢执行：模拟在途推理，等待取消钩子或产出完成。
    final cancelled = Completer<void>();
    onSubscribed?.call(() async {
      if (!cancelled.isCompleted) cancelled.complete(); // 幂等取消钩子
    });
    final first = await Future.any<String>([
      Future<String>.delayed(const Duration(milliseconds: 20),
          () => '完整产出'),
      cancelled.future.then<String>((_) => '__CANCELLED__'),
    ]);
    if (first == '__CANCELLED__') {
      throw const OnDeviceInterruptedException();
    }
    return first;
  }
}

void main() {
  test('注册表：注册 → 死亡通知打断 → 自动注销；幂等注销/未知 callerKey 无操作',
      () async {
    final registry = CallerDeathInterrupt();
    var interrupted = 0;
    final unregister = registry.register('com.a', () async => interrupted++);
    expect(registry.activeCount('com.a'), 1);
    await registry.notifyDeath('com.a');
    expect(interrupted, 1);
    expect(registry.activeCount('com.a'), 0, reason: '死亡通知后自动注销');
    await registry.notifyDeath('com.a'); // 重复通知：无在途，无操作
    expect(interrupted, 1);
    unregister(); // 幂等注销（已由死亡清场）
    await registry.notifyDeath('com.unknown'); // 未知 callerKey：无操作
  });

  test('执行器死亡联动：注册表触发 → 订阅取消 → 调用作废（返回 isError）',
      () async {
    final registry = CallerDeathInterrupt();
    callerDeathInterruptSingleton = registry;
    addTearDown(() => callerDeathInterruptSingleton = null);
    final streamEstablished = Completer<void>();
    final cap =
        _InterruptibleStub(onStream: () => streamEstablished.complete());
    final exe = HostOnDeviceToolExecutor(cap,
        quota: null, callerKey: 'com.a');
    final future = exe.execute(_call());
    await streamEstablished.future; // 流已建立（在途执行中）
    await registry.notifyDeath('com.a'); // 调用方进程死亡
    final r = await future;
    expect(r.isError, isTrue, reason: '作废本次调用');
    expect(r.content, contains('已作废'));
  });

  test('未接线注册表：退化为无死亡联动聚合（保守可运行，零行为变化）', () async {
    callerDeathInterruptSingleton = null;
    final exe = HostOnDeviceToolExecutor(_StubCapability(), callerKey: 'com.a');
    final r = await exe.execute(_call());
    expect(r.isError, isFalse, reason: '注册表缺位 → 退化为普通聚合');
    expect(r.content, '聚合产出');
  });
}

AssembledToolCall _call() => const AssembledToolCall(
      id: 't1',
      name: HostOnDeviceToolExecutor.toolName,
      argumentsJson: '{"instruction":"i","input":"x"}',
    );
