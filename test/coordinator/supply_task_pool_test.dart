import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/host_on_device_tool.dart';
import 'package:goodhub/coordinator/supply_task_pool.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// W6-a 回归锚（on-device-residency 第七节）：任务池状态机 / M4 配额 / M5
/// 身份过滤 / M6 毒丸死信 / 过期清账 / 持久化恢复；executor 联合态
///（allow_deferred 冷态入池 + Pull 交付真理源 + 存量 failFast 零变化）。
class _StubPrimitive implements OnDeviceCapabilityService {
  @override
  Future<String> complete(
      {required String instruction,
      required String input,
      OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
      PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
      String? traceId}) async {
    throw const OnDevicePrimitiveException('引擎未装载（stub 冷态）');
  }

  @override
  Future<OnDeviceCapabilityAvailability> availability() async =>
      OnDeviceCapabilityAvailability.unavailable;

  @override
  Future<void> loadExplicit() async {}

  @override
  Stream<EngineChunk> completeStream(
      {required String instruction,
      required String input,
      OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
      PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
      String? traceId}) async* {
    throw const OnDevicePrimitiveException('引擎未装载（stub 冷态）');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmpDir;
  late SupplyTaskPool pool;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('supply-pool-test');
    pool = SupplyTaskPool(dirResolver: () async => tmpDir);
  });
  tearDown(() async => tmpDir.deleteSync(recursive: true));

  test('登记→认领→完成→拉取（Pull 即交付真理源）', () async {
    final e = await pool.submit(
        callerKey: 'com.a', instruction: '提取标签', input: '正文');
    expect(e.status, SupplyTaskStatus.queued);
    final claimed = await pool.claimNext();
    expect(claimed?.taskId, e.taskId);
    expect(claimed?.status, SupplyTaskStatus.running);
    await pool.completeTask(e.taskId, '标签A,标签B');
    expect(await pool.statusFor(e.taskId, callerKey: 'com.b'), isNull,
        reason: 'M5：callerKey 不匹配不可见');
    final pulled = await pool.statusFor(e.taskId, callerKey: 'com.a');
    expect(pulled?.status, SupplyTaskStatus.pendingDelivery);
    expect(pulled?.result, '标签A,标签B');
    await pool.markDelivered(e.taskId, callerKey: 'com.a');
    expect((await pool.statusFor(e.taskId, callerKey: 'com.a'))?.status,
        SupplyTaskStatus.delivered);
  });

  test('M4 配额：per-caller 上限 8 拒绝第 9 条；另一 caller 不受影响', () async {
    for (var i = 0; i < 8; i++) {
      await pool.submit(callerKey: 'com.a', instruction: 't$i', input: 'x');
    }
    expect(() => pool.submit(callerKey: 'com.a', instruction: 't9', input: 'x'),
        throwsStateError);
    final e = await pool.submit(
        callerKey: 'com.b', instruction: 't', input: 'x');
    expect(e.status, SupplyTaskStatus.queued);
  });

  test('M6 毒丸防线：requeue 3 次后死信（不计配额回池）', () async {
    final e = await pool.submit(
        callerKey: 'com.a', instruction: 't', input: 'x');
    await pool.requeue(e.taskId);
    await pool.requeue(e.taskId);
    final alive = await pool.requeue(e.taskId);
    expect(alive, isFalse, reason: '第 3 次达上限转死信');
    final after = await pool.statusFor(e.taskId, callerKey: 'com.a');
    expect(after?.status, SupplyTaskStatus.failedExhausted);
    expect(after?.failReason, contains('毒丸'));
  });

  test('持久化：新实例从盘加载（崩溃恢复 running→queued）', () async {
    final e = await pool.submit(
        callerKey: 'com.a', instruction: 't', input: 'x');
    await pool.claimNext(); // running
    final reloaded = SupplyTaskPool(dirResolver: () async => tmpDir);
    final got = await reloaded.statusFor(e.taskId, callerKey: 'com.a');
    expect(got?.status, SupplyTaskStatus.queued,
        reason: '崩溃恢复：running 视同 queued 重排');
  });

  test('executor 联合态：冷态 + allow_deferred → 入池回执（非错误）', () async {
    final executor =
        HostOnDeviceToolExecutor(_StubPrimitive(), taskPool: pool);
    final r = await executor.execute(const AssembledToolCall(
      id: 't1',
      name: 'on_device_complete',
      argumentsJson:
          '{"instruction":"提取标签","input":"正文","allow_deferred":true}',
    ), callerKeyOverride: 'com.a');
    expect(r.isError, isFalse, reason: '冷态入池回执 = ok 非错误');
    final payload = jsonDecode(r.content) as Map<String, Object?>;
    expect(payload['execution_mode'], 'deferred');
    expect(payload['status'], 'queued');
  });

  test('存量语义：无 allow_deferred → 同步 failFast 错误（零变化）', () async {
    final executor =
        HostOnDeviceToolExecutor(_StubPrimitive(), taskPool: pool);
    final r = await executor.execute(const AssembledToolCall(
      id: 't2',
      name: 'on_device_complete',
      argumentsJson: '{"instruction":"提取标签","input":"正文"}',
    ), callerKeyOverride: 'com.a');
    expect(r.isError, isTrue, reason: '缺省 false = 同步 failFast 存量语义');
  });

  test('M5 安全：无 callerKey 的 deferred 请求不受理', () async {
    final executor =
        HostOnDeviceToolExecutor(_StubPrimitive(), taskPool: pool);
    final r = await executor.execute(const AssembledToolCall(
      id: 't3',
      name: 'on_device_complete',
      argumentsJson:
          '{"instruction":"提取标签","input":"正文","allow_deferred":true}',
    ));
    expect(r.isError, isTrue, reason: '无身份不受理 deferred（M5）');
  });

  test('status 工具：Pull 交付 + M5 过滤', () async {
    final e = await pool.submit(
        callerKey: 'com.a', instruction: 't', input: 'x');
    await pool.completeTask(e.taskId, '结果');
    final statusExecutor = HostSupplyTaskStatusExecutor(pool);
    final foreign = await statusExecutor.execute(AssembledToolCall(
      id: 's1',
      name: 'on_device_task_status',
      argumentsJson: jsonEncode({'task_id': e.taskId}),
    ), callerKeyOverride: 'com.b');
    expect((jsonDecode(foreign.content) as Map)['status'], 'not_found');
    final own = await statusExecutor.execute(AssembledToolCall(
      id: 's2',
      name: 'on_device_task_status',
      argumentsJson: jsonEncode({'task_id': e.taskId}),
    ), callerKeyOverride: 'com.a');
    final payload = jsonDecode(own.content) as Map<String, Object?>;
    expect(payload['status'], 'delivered', reason: 'Pull 即交付真理源');
    expect(payload['result'], '结果');
  });
}
