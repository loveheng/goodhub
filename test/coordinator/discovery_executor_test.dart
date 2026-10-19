import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/discovery_executor.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/tool_router.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';

/// 假执行器：记录收到的调用名并返回固定结果（不触网）。
class _FakeExecutor implements ToolExecutor {
  final List<String> calls = [];
  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    calls.add(call.name);
    return ToolExecutionResult(content: 'echo:${call.name}');
  }
}

/// 构造不触网的 face（不调 listTools/negotiate，cachedSchemas 为空）。
McpToolFace _fakeFace(String id) =>
    McpToolFace(client: McpClient.http(baseUrl: 'http://x/$id/mcp'), serverId: id);

/// 带 schema 的假 face（覆写 cachedSchemas，不触网）——聚焦面过滤测试用。
class _SchemaFace extends McpToolFace {
  _SchemaFace({
    required super.client,
    required super.serverId,
    required this.schemas,
  });

  final List<CloudToolSchema> schemas;

  @override
  List<CloudToolSchema> get cachedSchemas => List.unmodifiable(schemas);
}

CloudToolSchema _schema(String bareName) => CloudToolSchema(
      name: bareName,
      description: 'd',
      parametersSchema: <String, Object?>{},
    );

void main() {
  group('parsePrefixedToolName', () {
    test('正常前缀解析', () {
      final r = parsePrefixedToolName('goodshare__get_item');
      expect(r?.serverId, 'goodshare');
      expect(r?.toolName, 'get_item');
    });
    test('无分隔符返回 null', () {
      expect(parsePrefixedToolName('get_item'), isNull);
    });
    test('空段返回 null', () {
      expect(parsePrefixedToolName('__get_item'), isNull);
      expect(parsePrefixedToolName('goodshare__'), isNull);
    });
  });

  group('ToolRouter 路由守卫', () {
    late ToolRouter router;
    setUp(() {
      router = ToolRouter(
          faces: {'s1': _fakeFace('s1'), 's2': _fakeFace('s2')});
    });
    test('serverFor 解析前缀；本地无前缀工具返回 null', () {
      expect(router.serverFor('s1__foo'), 's1');
      expect(router.serverFor('bar'), isNull);
    });
    test('serverIds 收集', () {
      expect(router.serverIds, containsAll(['s1', 's2']));
    });
    test('未激活 server 调用 → isError 引导 activate_server_tools', () async {
      final res = await router.execute(
          AssembledToolCall(id: '1', name: 's1__foo', argumentsJson: '{}'));
      expect(res.isError, isTrue);
      expect(res.content, contains('activate_server_tools'));
    });
    test('未知 server 调用 → isError', () async {
      final res = await router.execute(
          AssembledToolCall(id: '1', name: 'bad__foo', argumentsJson: '{}'));
      expect(res.isError, isTrue);
    });
    test('无前缀调用 → isError 引导 get_connected_apps', () async {
      final res = await router.execute(
          AssembledToolCall(id: '1', name: 'foo', argumentsJson: '{}'));
      expect(res.isError, isTrue);
      expect(res.content, contains('get_connected_apps'));
    });
  });

  group('DiscoveryExecutor JIT 元工具', () {
    late ToolRouter router;
    late _FakeExecutor inner;
    late DiscoveryExecutor disc;
    late List<String> activations;
    setUp(() {
      router = ToolRouter(faces: {'s1': _fakeFace('s1')});
      inner = _FakeExecutor();
      activations = [];
      disc = DiscoveryExecutor(
        router: router,
        inner: inner,
        serverSummaries: {'s1': 'goodshare Tier1'},
        onActivation: (id) => activations.add(id),
      );
    });
    test('get_connected_apps 列出已挂载服务 + 摘要', () async {
      final res = await disc.execute(AssembledToolCall(
          id: '1',
          name: DiscoveryExecutor.getConnectedApps,
          argumentsJson: '{}'));
      expect(res.isError, isFalse);
      expect(res.content, contains('s1'));
      expect(res.content, contains('goodshare Tier1'));
    });
    test('activate_server_tools 激活 + 回调触发', () async {
      final res = await disc.execute(AssembledToolCall(
          id: '1',
          name: DiscoveryExecutor.activateServerTools,
          argumentsJson: jsonEncode({'server_id': 's1'})));
      expect(res.isError, isFalse);
      expect(router.activatedServers, contains('s1'));
      expect(activations, contains('s1'));
    });
    test('activate_server_tools 未知 id → isError', () async {
      final res = await disc.execute(AssembledToolCall(
          id: '1',
          name: DiscoveryExecutor.activateServerTools,
          argumentsJson: jsonEncode({'server_id': 'bad'})));
      expect(res.isError, isTrue);
    });
    test('activate_server_tools 缺参 → isError', () async {
      final res = await disc.execute(AssembledToolCall(
          id: '1',
          name: DiscoveryExecutor.activateServerTools,
          argumentsJson: '{}'));
      expect(res.isError, isTrue);
    });
    test('activate_server_tools 入参损坏 → isError', () async {
      final res = await disc.execute(AssembledToolCall(
          id: '1',
          name: DiscoveryExecutor.activateServerTools,
          argumentsJson: '{bad json'));
      expect(res.isError, isTrue);
    });
    test('非 JIT 工具名透传到 inner', () async {
      await disc.execute(AssembledToolCall(
          id: '1', name: 's1__foo', argumentsJson: '{}'));
      expect(inner.calls, contains('s1__foo'));
    });
  });

  group('use_server 私有槽位（P1-4 / §1.6：public 常驻 + 单一 private 槽位）', () {
    late ToolRouter router;
    late _FakeExecutor inner;
    late DiscoveryExecutor disc;
    setUp(() {
      router = ToolRouter(faces: {
        's1': _SchemaFace(
            client: McpClient.http(baseUrl: 'http://x/s1/mcp'),
            serverId: 's1',
            schemas: [_schema('list_items'), _schema('get_item')]),
        's2': _SchemaFace(
            client: McpClient.http(baseUrl: 'http://x/s2/mcp'),
            serverId: 's2',
            schemas: [_schema('search')]),
        'p1': _SchemaFace(
            client: McpClient.http(baseUrl: 'http://x/p1/mcp'),
            serverId: 'p1',
            schemas: [_schema('private_a')]),
        'p2': _SchemaFace(
            client: McpClient.http(baseUrl: 'http://x/p2/mcp'),
            serverId: 'p2',
            schemas: [_schema('private_b')]),
      }, privateServerIds: const {'p1', 'p2'});
      inner = _FakeExecutor();
      disc = DiscoveryExecutor(
        router: router,
        inner: inner,
        serverSummaries: const {'s1': 'A', 's2': 'B', 'p1': 'P1', 'p2': 'P2'},
      );
    });

    test('public use_server：常驻不聚焦（不踢其他 public），幂等激活', () async {
      router.activatedServers.addAll(['s1', 's2']);
      final res = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 's1'})));
      expect(res.isError, isFalse);
      expect(router.activePrivateServerId, isNull);
      // 公共面常驻：全部 public schema 都在（按 (serverId, toolName) 排序）。
      expect(router.focusedSchemas().map((s) => s.name).toList(), [
        's1__get_item',
        's1__list_items',
        's2__search',
      ]);
      expect(router.activatedServers, containsAll(['s1', 's2']));
    });

    test('private use_server：pending 请求 + 提交点后槽位切换，公共前缀不动', () async {
      router.activatedServers.addAll(['s1', 's2']);
      final r1 = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 'p1'})));
      expect(r1.isError, isFalse);
      expect(router.activePrivateServerId, isNull,
          reason: '执行期只写 pending（提交点 = ToolResultMessage 落历史后）');
      expect(r1.content, contains('下一轮生效'));
      router.commitPendingSlot();
      expect(router.activePrivateServerId, 'p1');
      final names1 = router.focusedSchemas().map((s) => s.name).toList();
      expect(names1,
          ['s1__get_item', 's1__list_items', 's2__search', 'p1__private_a']);

      // 抢占替换：p2 抢槽后尾部块换成 p2，公共前缀字节不动（缓存命中的关键）。
      final r2 = await disc.execute(AssembledToolCall(
          id: '2', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 'p2'})));
      expect(r2.isError, isFalse);
      router.commitPendingSlot();
      expect(router.activePrivateServerId, 'p2');
      final names2 = router.focusedSchemas().map((s) => s.name).toList();
      expect(names2.sublist(0, 3),
          ['s1__get_item', 's1__list_items', 's2__search']);
      expect(names2.last, 'p2__private_b');
    });

    test('activate_server_tools 私有服务：pending 占槽，提交后不进公共激活集', () async {
      final res = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.activateServerTools,
          argumentsJson: jsonEncode({'server_id': 'p1'})));
      expect(res.isError, isFalse);
      router.commitPendingSlot();
      expect(router.activePrivateServerId, 'p1');
      expect(router.activatedServers, isNot(contains('p1')));
    });

    test('"all" 清空私有槽位（pending），公共面不变', () async {
      router.activatedServers.addAll(['s1', 's2']);
      router.activePrivateServerId = 'p1';
      final res = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 'all'})));
      expect(res.isError, isFalse);
      router.commitPendingSlot();
      expect(router.activePrivateServerId, isNull);
      expect(router.focusedSchemas().map((s) => s.name),
          everyElement(isNot(contains('p1'))));
      expect(router.activatedServers, containsAll(['s1', 's2']));
    });

    test('无槽位时 focusedSchemas == 全部 public（排序）', () {
      router.activatedServers.addAll(['s1', 's2']);
      expect(router.activePrivateServerId, isNull);
      expect(router.focusedSchemas().map((s) => s.name).toList(), [
        's1__get_item',
        's1__list_items',
        's2__search',
      ]);
    });

    test('私有槽位守卫：未占槽/被抢占 → isError 引导 use_server', () async {
      router.activatedServers.addAll(['s1', 's2']);
      final res = await router.execute(
          AssembledToolCall(id: '1', name: 'p2__private_b', argumentsJson: '{}'));
      expect(res.isError, isTrue);
      expect(res.content, contains('use_server'));

      // p1 占槽后，p2 调用仍被守卫（单一私有域独占）。
      router.activePrivateServerId = 'p1';
      final res2 = await router.execute(
          AssembledToolCall(id: '2', name: 'p2__private_b', argumentsJson: '{}'));
      expect(res2.isError, isTrue);
      expect(res2.content, contains('抢占'));
    });

    test('private 槽位占守卫放行本域：不再命中槽位守卫文案', () async {
      router.activePrivateServerId = 'p1';
      final res = await router.execute(
          AssembledToolCall(id: '1', name: 'p1__private_a', argumentsJson: '{}'));
      // _SchemaFace 未覆写 execute，放行后走真实 face 传输（结果形态不定）；
      // 断言关键：不再是槽位守卫的引导文案（未被拦截）。
      expect(res.content, isNot(contains('私有槽位')));
      expect(res.content, isNot(contains('use_server')));
    });

    test('未知 server_id → isError 不抛', () async {
      final res = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 'bad'})));
      expect(res.isError, isTrue);
    });

    test('缺参 / 入参损坏 → isError', () async {
      final r1 = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer, argumentsJson: '{}'));
      expect(r1.isError, isTrue);
      final r2 = await disc.execute(AssembledToolCall(
          id: '2', name: DiscoveryExecutor.useServer, argumentsJson: '{bad'));
      expect(r2.isError, isTrue);
    });

    test('use_server 在槽位占用态可切换/清空（元工具本身不被守卫拦截）',
        () async {
      router.activePrivateServerId = 'p1';
      final res = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 'all'})));
      expect(res.isError, isFalse);
      router.commitPendingSlot();
      expect(router.activePrivateServerId, isNull);
    });
  });
}
