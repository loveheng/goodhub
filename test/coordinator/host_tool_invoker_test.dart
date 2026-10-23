/// 宿主工具执行端口适配器单测（host-tools-gateway-export PR1-3）。
///
/// 覆盖五件事：① 记忆工具面经端口可实调 ② 资源面解析失败/缺席的降级语义
/// ③ **无裁决铁律**（端口链内不得出现 PermissionGateway——网关入站 L1/L2 已由
/// `GatewaySecurity.guard` 完成，重复挂载会让 PC 看到两次确认卡）
/// ④ **装配等价性**（资源面在场时三层工具面全在场——包裹顺序铁律）
/// ⑤ **Allowlist 登记项可达**（登记项不得在执行链上悬空）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/host_tool_invoker.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/mcp/transport/host_transport.dart' show kHostExportAllowlist;
import 'package:goodhub/resources/resource_store.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/sandbox/memory_store.dart';

/// 观测型假执行面（验 invoke 的入参透传与调用次数）。
class _SpyExecutor implements ToolExecutor {
  final calls = <AssembledToolCall>[];

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    calls.add(call);
    return const ToolExecutionResult(content: 'spy');
  }
}

Future<MemoryStore> _store() async {
  final dir = await Directory.systemTemp.createTemp('host_invoker_test');
  final store = MemoryStore.underSupportDir(dir.path);
  // 排空握手用 ioDrained（§3.2：禁固定 Future.delayed 猜等）——记忆工具会写
  // 沙盒 + ops.log，未排空即删目录会与在途写竞态。
  addTearDown(() async {
    await store.ioDrained;
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return store;
}

void main() {
  group('assembleHostToolInvoker · 记忆工具面', () {
    test('update_memory → query_memory 经端口闭环', () async {
      final store = await _store();
      final port = await assembleHostToolInvoker(memoryStore: store);

      final wrote = await port.invoke(
        name: 'update_memory',
        argumentsJson: jsonEncode(<String, Object?>{
          'content': '用户偏好中文回答',
          'tags': ['pref'],
        }),
      );
      expect(wrote.isError, isFalse);
      expect(wrote.content, contains('用户偏好中文回答'),
          reason: '写后必回最新快照（§5.3）');

      final read = await port.invoke(
        name: 'query_memory',
        argumentsJson: jsonEncode(<String, Object?>{'q': '中文'}),
      );
      expect(read.isError, isFalse);
      expect(read.content, contains('用户偏好中文回答'));
    });

    test('无裁决铁律：装配链内不得出现 PermissionGateway', () async {
      final store = await _store();
      final port = await assembleHostToolInvoker(memoryStore: store);
      expect(port.executor, isNot(isA<PermissionGateway>()),
          reason: 'L1/L2 已由 GatewaySecurity.guard 在 toolsCall 层完成，'
              '重复挂载会让 PC 看到两次确认卡');
    });

    test('Allowlist 之外的裸名 → 兜底显式拒绝（不静默透传）', () async {
      final store = await _store();
      final port = await assembleHostToolInvoker(memoryStore: store);
      final r = await port.invoke(name: 'rm_rf_everything', argumentsJson: '{}');
      expect(r.isError, isTrue);
      expect(r.content, contains('rm_rf_everything'));
    });
  });

  group('assembleHostToolInvoker · 资源面降级', () {
    test('resolver 抛错 → DEGRADE 不阻断，记忆工具面照常可用', () async {
      final store = await _store();
      final port = await assembleHostToolInvoker(
        memoryStore: store,
        resourceStoreResolver: () async => throw StateError('no platform channel'),
      );
      final r = await port.invoke(
        name: 'query_memory',
        argumentsJson: jsonEncode(<String, Object?>{'q': 'x'}),
      );
      expect(r.isError, isFalse, reason: '资源面降级不得牵连记忆工具面');
    });

    test('resolver 返回 null / 未提供 → 不挂资源工具面', () async {
      final store = await _store();
      for (final port in [
        await assembleHostToolInvoker(memoryStore: store),
        await assembleHostToolInvoker(
            memoryStore: store, resourceStoreResolver: () async => null),
      ]) {
        final r = await port.invoke(
            name: 'read_local_resource', argumentsJson: '{"resource_id":"r1"}');
        expect(r.isError, isTrue, reason: '无资源面时该工具不可达，不静默成功');
      }
    });
  });

  group('HostToolInvokerPort · 契约', () {
    test('invoke 透传裸名与原始入参 JSON（剥前缀由投影层负责）', () async {
      final spy = _SpyExecutor();
      final port = HostToolInvokerPort(executor: spy);
      await port.invoke(name: 'echo', argumentsJson: '{"a":1}');
      await port.invoke(name: 'echo', argumentsJson: '{"a":2}');
      expect(spy.calls.map((c) => c.name), ['echo', 'echo']);
      expect(spy.calls.map((c) => c.argumentsJson), ['{"a":1}', '{"a":2}']);
      expect(spy.calls.first.id, isNotEmpty, reason: '审计关联 id 不可为空');
    });
  });

  group('assembleHostToolInvoker · 装配等价性（全成员在场）', () {
    test('资源面在场时 status 层不得被丢弃（包裹顺序铁律）', () async {
      final dir = await Directory.systemTemp.createTemp('host_invoker_full');
      final store = MemoryStore.underSupportDir(dir.path);
      final res = ResourceStore.underSupportDir(dir.path);
      await res.load();
      addTearDown(() async {
        await store.ioDrained;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final port = await assembleHostToolInvoker(
        memoryStore: store,
        resourceStoreResolver: () async => res,
      );

      final status =
          await port.invoke(name: 'get_host_status', argumentsJson: '{}');
      expect(status.isError, isFalse,
          reason: '资源面在场时不得丢弃 status 层——链条须逐层向外包裹');
      expect(status.content, contains('"status":"ok"'));

      final mem = await port.invoke(
          name: 'query_memory', argumentsJson: '{"q":"x"}');
      expect(mem.isError, isFalse, reason: '记忆层须仍在链上');

      final res2 = await port.invoke(
          name: 'read_local_resource', argumentsJson: '{"resource_id":"r1"}');
      expect(res2.content, isNot(contains('未接入执行面')),
          reason: '资源层须在链上可达（不可被整层丢弃）');
    });

    test('Allowlist 登记项在生产装配下均可达（防悬空登记）', () async {
      final dir = await Directory.systemTemp.createTemp('host_invoker_allow');
      final store = MemoryStore.underSupportDir(dir.path);
      final res = ResourceStore.underSupportDir(dir.path);
      await res.load();
      addTearDown(() async {
        await store.ioDrained;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final port = await assembleHostToolInvoker(
        memoryStore: store,
        resourceStoreResolver: () async => res,
      );

      expect(kHostExportAllowlist, isNotEmpty,
          reason: 'Allowlist 首项登记纪律：至少一条 shared + readOnlyHint');
      for (final entry in kHostExportAllowlist) {
        final r = await port.invoke(name: entry.name, argumentsJson: '{}');
        expect(r.content, isNot(contains('未接入执行面')),
            reason: '登记项 ${entry.name} 在执行链上悬空——目录可见但调用必败');
      }
    });
  });
}