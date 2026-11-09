// ai/complete 收编迁移真机 e2e（ai-capability-export 收编 2026-11-09）。
//
// 运行（真机）：
//   flutter test integration_test/ai_complete_e2e_test.dart -d <device>
//
// 覆盖：
//   e2e-1 受理链联合态：ai/complete + allow_deferred（冷态）→ 原子入池回执
//        （契约 0.5.0 §8.7 联合态；callerKey = 中性测试 caller → 跨进程 Pull 锚）；
//   e2e-2 Pull 交付真理源：completeTask → pendingDelivery → markDelivered（M5 寻址）；
//   e2e-3 Binder 生产接线：wireSampling 会话钩子挂接 → 宿主经 face 调 dummy 的
//        aiEcho（GoodHubAi.completeSync → ai/complete 反向帧 → 真实受理链）——
//        引擎冷态 → MODEL_COLD 结构化 FastFail 十二码透出（零等待语义真机钉）；
//   留存锚：e2e-1 入池任务保持 queued 留在宿主 WAL（真机接入方 App 轮询
//        可见，桥 /debug/state onDeviceTasks 断言用）。
//
// 引擎装载路径不在本 e2e（gemma3-1b 装载分钟级；热态成功路径已由 2026-11-08
// 真机 curl 取证 + query_on_device 直驱覆盖）——deferred 全链冷态即回，秒级稳跑。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart' show AidlOnDeviceEngine;
import 'package:goodhub/coordinator/ai_complete_service.dart';
import 'package:goodhub/coordinator/hybrid_assembly.dart';
import 'package:goodhub/coordinator/supply_quota.dart';
import 'package:goodhub/mcp/sampling.dart' show SamplingQuota;
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/reverse_wiring.dart';
import 'package:goodhub/coordinator/supply_task_pool.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';

Future<T> _withTimeout<T>(Future<T> f, String label) => f.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TimeoutException('超时: $label', const Duration(seconds: 60)),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 测试壳不走生产组合根（main.dart）——供给面共享引擎在此注册（等价装配根）。
  registerSharedOnDeviceEngine(AidlOnDeviceEngine());

  testWidgets('ai/complete e2e: deferred 入池 + Pull 真理源 + Binder 生产接线',
      (tester) async {
    // ---- phase0: 发现 + 挂载 dummy ----
    debugPrint('[ai-e2e] phase0: scan');
    final plugins = await _withTimeout(localPluginDiscovery.scan(), 'scan');
    final dummy = plugins.where((p) => p.serverId == 'dummy').toList();
    expect(dummy, isNotEmpty, reason: '应扫描到本地插件 dummy');

    // ---- 受理链生产装配（ensureConfigured：端腿 + 任务池 + 档案注册表）----
    AiCompleteService.resetForTest();
    AiCompleteService.ensureConfigured(
      onDevice: AidlOnDeviceCapabilityService(sharedOnDeviceEngine),
      taskPool: SupplyTaskPool.instance,
    );
    addTearDown(AiCompleteService.resetForTest);

    // ---- e2e-1 联合态：冷态 + allow_deferred → 原子入池回执 ----
    // callerKey = 中性测试 caller（宿主测试进程内直驱受理链，等价反向帧到达）——
    // 入池任务留在宿主 WAL，真机接入方 App 轮询可见（跨进程 Pull 锚）。
    debugPrint('[ai-e2e] e2e-1: deferred submit');
    final frames = <Map<String, Object?>>[];
    final handled = await AiCompleteService.instance.handleAiMethod(
      method: AiWire.methodComplete,
      id: 'e2e-defer-1',
      params: {
        'instruction': '提取要点',
        'input': 'e2e-deferred-anchor-body',
        'allow_deferred': true,
      },
      caller: null,
      callerKeyFallback: 'com.example.e2e.caller',
      emit: frames.add,
    );
    expect(handled, isTrue, reason: 'ai/complete 由统一受理链受理');
    final resultFrame =
        frames.singleWhere((f) => f['result'] != null);
    final resultPayload = (resultFrame['result'] as Map)['content'] as Map;
    final receipt =
        jsonDecode(resultPayload['text'] as String) as Map<String, Object?>;
    expect(receipt['execution_mode'], 'deferred',
        reason: '冷态 + allow_deferred → 联合态回执（契约 §8.7）');
    expect(receipt['status'], 'queued');
    final anchorTaskId = receipt['task_id'] as String;
    expect(anchorTaskId, isNotEmpty);
    debugPrint('[ai-e2e] deferred receipt: taskId=$anchorTaskId');

    // ---- e2e-2 Pull 交付真理源（M5 寻址 + pendingDelivery → delivered）----
    debugPrint('[ai-e2e] e2e-2: pull delivery');
    // 身份寻址：测试 caller 可见、他人不可见。
    final foreign =
        await SupplyTaskPool.instance.statusFor(anchorTaskId, callerKey: 'com.other.app');
    expect(foreign, isNull, reason: 'M5：callerKey 不匹配不可见');
    final pulled = await SupplyTaskPool.instance
        .statusFor(anchorTaskId, callerKey: 'com.example.e2e.caller');
    expect(pulled?.status, SupplyTaskStatus.queued);
    // 模拟顺风车消费产出 → Pull 即交付。
    await SupplyTaskPool.instance.completeTask(anchorTaskId, 'E2E-DEFERRED-OK');
    final pulled2 = await SupplyTaskPool.instance
        .statusFor(anchorTaskId, callerKey: 'com.example.e2e.caller');
    expect(pulled2?.status, SupplyTaskStatus.pendingDelivery);
    expect(pulled2?.result, 'E2E-DEFERRED-OK');
    await SupplyTaskPool.instance
        .markDelivered(anchorTaskId, callerKey: 'com.example.e2e.caller');
    final pulled3 = await SupplyTaskPool.instance
        .statusFor(anchorTaskId, callerKey: 'com.example.e2e.caller');
    expect(pulled3?.status, SupplyTaskStatus.delivered);
    debugPrint('[ai-e2e] pull delivery ok');

    // 留存锚：再入池一条 queued（不消费），真机接入方 App 轮询可见。
    final leave = await SupplyTaskPool.instance.submit(
      callerKey: 'com.example.e2e.caller',
      instruction: '留存锚（接入方轮询验证用）',
      input: 'leave-queued-anchor',
    );
    debugPrint('[ai-e2e] leave queued anchor: ${leave.taskId}');

    // ---- e2e-3 Binder 生产接线：aiEcho → ai/complete → 真实受理链 ----
    debugPrint('[ai-e2e] e2e-3: binder aiEcho via wireSampling');
    // 挂载 dummy（插件端点）+ goodhub-ai-consumer（消费端端点）——宿主 bind
    // 消费端服务并注册回调后，消费端 GoodHubAi runtime 才有 push 通道
    //（HostNotConnectedException 防线 = 未 bind 即发请求，此处必须先挂载）。
    final consumer = plugins.where((p) => p.serverId == 'goodhub-ai-consumer').toList();
    expect(consumer, isNotEmpty,
        reason: '应扫描到消费端端点（runtime 库 Manifest 随包声明 AiTransportService）');
    final faces = <String, McpToolFace>{};
    for (final e in [dummy.first, consumer.first]) {
      final c = localPluginDiscovery.createClient(e);
      await _withTimeout(c.negotiate(), 'negotiate ${e.serverId}');
      final f = McpToolFace(client: c, serverId: e.serverId);
      await _withTimeout(f.listTools(), 'listTools ${e.serverId}');
      faces[e.serverId] = f;
      addTearDown(c.close);
    }
    final face = faces['dummy']!;

    // 生产接线（wireSampling 会话钩子）：ai/complete + ai/cancel 进统一受理链。
    // 云腿注入生产装配件（无 BYOK 时云腿不可用——路由缺省端侧不受影响）。
    // 生产装配单源（无 BYOK 时云腿实例仍可建——受理链路由缺省端侧）。
    final hybrid = await assembleDefaultHybridEngine();
    wireSampling(
      faces: faces,
      engine: hybrid,
      quota: SamplingQuota(),
      onDeviceCapability: AidlOnDeviceCapabilityService(sharedOnDeviceEngine),
      supplyQuota: SupplyQuota(),
      taskPool: SupplyTaskPool.instance,
    );

    // 宿主调 dummy 的 aiEcho（completeSync 零等待通道）→ ai/complete 反向帧
    // → 真实受理链（引擎冷态）→ MODEL_COLD 结构化 FastFail → 十二码透出。
    final r = await _withTimeout(
      face.client.callWithProgress(
        'tools/call',
        params: {
          'name': 'aiEcho',
          'arguments': {'instruction': '原样重复：E2E-COLD-ANCHOR', 'input': ''},
        },
        onProgress: (_) {},
      ),
      'aiEcho cold fast-fail',
    );
    // callWithProgress 返回 tools/call result map（Object?）——取 content[0].text。
    final rMap = (r is Map) ? (r['content'] as List?)?.firstOrNull as Map? : null;
    final content = (rMap?['text'] as String?) ?? jsonEncode(r);
    debugPrint('[ai-e2e] aiEcho cold -> $content');
    expect(content, contains('aiEcho fast-fail[MODEL_COLD]'),
        reason: '零等待通道冷态 → MODEL_COLD 结构化失败（十二码真机透出）');
    debugPrint('[ai-e2e] ALL PASS');
  });
}
