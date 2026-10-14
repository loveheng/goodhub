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

  group('use_server 聚焦（独占）', () {
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
      });
      inner = _FakeExecutor();
      disc = DiscoveryExecutor(
        router: router,
        inner: inner,
        serverSummaries: const {'s1': 'A', 's2': 'B'},
      );
    });

    test('聚焦后 focusedSchemas 仅含该服务，并顺带激活', () async {
      router.activatedServers.addAll(['s1', 's2']);
      final res = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 's1'})));
      expect(res.isError, isFalse);
      expect(router.focusedServer, 's1');
      final names =
          router.focusedSchemas().map((s) => s.name).toList();
      expect(names, ['s1__list_items', 's1__get_item']);
      expect(router.activatedServers, containsAll(['s1', 's2']));
    });

    test('聚焦未激活服务顺带激活（聚焦前后激活集持久）', () async {
      await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 's2'})));
      expect(router.activatedServers, contains('s2'));
      expect(router.focusedServer, 's2');
    });

    test('"all" 解除聚焦恢复全量，激活集不变', () async {
      router.activatedServers.addAll(['s1', 's2']);
      router.focusedServer = 's1';
      final res = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 'all'})));
      expect(res.isError, isFalse);
      expect(router.focusedServer, isNull);
      expect(router.focusedSchemas().length,
          router.activatedSchemas().length);
      expect(router.activatedServers, containsAll(['s1', 's2']));
    });

    test('未聚焦时 focusedSchemas == activatedSchemas', () {
      router.activatedServers.addAll(['s1', 's2']);
      expect(router.focusedServer, isNull);
      expect(router.focusedSchemas().length,
          router.activatedSchemas().length);
    });

    test('聚焦 server 独占守卫：其他 server 调用 → isError 引导 use_server("all")',
        () async {
      router.activatedServers.addAll(['s1', 's2']);
      router.focusedServer = 's1';
      final res = await router.execute(
          AssembledToolCall(id: '1', name: 's2__search', argumentsJson: '{}'));
      expect(res.isError, isTrue);
      expect(res.content, contains('use_server'));
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

    test('use_server 本身不被独占守卫拦截（聚焦态可切换/恢复）', () async {
      router.activatedServers.add('s1');
      router.focusedServer = 's1';
      final res = await disc.execute(AssembledToolCall(
          id: '1', name: DiscoveryExecutor.useServer,
          argumentsJson: jsonEncode({'server_id': 'all'})));
      expect(res.isError, isFalse);
      expect(router.focusedServer, isNull);
    });
  });
}
