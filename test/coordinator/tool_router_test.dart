/// coordinator/tool_router 单槽私有门控单测（MO：本地插件=私有 tier，须单槽隔离）。
///
/// 锁住的核心机制：privateServerIds 中的服务（含本地插件 id）在未激活时
/// 不进入 [ToolRouter.focusedSchemas]、[ToolRouter.execute] 被单槽门控拦截；
/// 仅激活的单一私有可见，其余私有被互斥隐藏。mcp_runtime 把本地插件 id 并入
/// privateServerIds 即依赖此机制——本测试钉住该机制不被回归破坏。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/tool_router.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';

McpClient _dummyClient() {
  final mock = MockClient((_) async => http.Response(
      json.jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': {}}),
      200,
      headers: {'content-type': 'application/json'}));
  return McpClient.http(baseUrl: 'http://fake', httpClient: mock);
}

/// 仅提供 canned schema / 结果，不触网（绕过 McpToolFace 真实传输）。
class _StubFace extends McpToolFace {
  _StubFace(this._schemas, this._result, {required super.serverId})
      : super(client: _dummyClient());

  final List<CloudToolSchema> _schemas;
  final ToolExecutionResult _result;

  @override
  List<CloudToolSchema> get cachedSchemas => List.unmodifiable(_schemas);

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async => _result;
}

CloudToolSchema _schema(String serverId, String tool) => CloudToolSchema(
      name: tool, // 裸名；schemasFor 会按 serverId 重新前缀化
      description: '',
      parametersSchema: const {},
    );

ToolRouter _router() => ToolRouter(
      faces: {
        'pub': _StubFace([_schema('pub', 'a')],
            const ToolExecutionResult(content: 'pub-ok'),
            serverId: 'pub'),
        'lp1': _StubFace([_schema('lp1', 'x')],
            const ToolExecutionResult(content: 'lp1-ok'),
            serverId: 'lp1'),
        'lp2': _StubFace([_schema('lp2', 'y')],
            const ToolExecutionResult(content: 'lp2-ok'),
            serverId: 'lp2'),
      },
      privateServerIds: {'lp1', 'lp2'}, // 本地插件同属私有 tier
    );

void main() {
  group('ToolRouter 单槽私有门控（本地插件=私有 tier）', () {
    test('私有（含本地插件 id）未激活：不在工具面，execute 拦截', () async {
      final router = _router();

      expect(router.focusedSchemas().map((s) => s.name).toList(), ['pub__a'],
          reason: '未激活私有（含本地插件）不得进入工具面');

      final blocked = await router.execute(
          AssembledToolCall(id: '1', name: 'lp1__x', argumentsJson: '{}'));
      expect(blocked.isError, isTrue);
      expect(blocked.content, contains('未激活'),
          reason: '非激活私有调用须被单槽门控拦截');
    });

    test('仅激活的单一私有可见（单槽互斥），其余私有隐藏', () async {
      final router = _router();
      router.activePrivateServerId = 'lp1';

      expect(router.focusedSchemas().map((s) => s.name).toList(),
          ['pub__a', 'lp1__x'],
          reason: '仅激活私有 lp1 可见，lp2 被互斥隐藏');

      final ok = await router.execute(
          AssembledToolCall(id: '1', name: 'lp1__x', argumentsJson: '{}'));
      expect(ok.isError, isFalse, reason: '激活私有可调用');

      final blocked = await router.execute(
          AssembledToolCall(id: '2', name: 'lp2__y', argumentsJson: '{}'));
      expect(blocked.isError, isTrue);
      expect(blocked.content, contains('单一私有域独占'),
          reason: '被互斥的私有 lp2 调用须拦截');
    });
  });
}
