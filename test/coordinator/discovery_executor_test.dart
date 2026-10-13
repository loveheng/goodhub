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
}
