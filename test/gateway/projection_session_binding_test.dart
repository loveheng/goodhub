/// 投影策略的**会话绑定**契约单测（host-tools-gateway-export PR2）：
/// 仅 `initialize` 期解析 URL query 并绑定进会话 handler，后续请求一律忽略
/// URL 参数；目标未挂载 / 非法字面量 Fail-Fast 返 -32602。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/gateway/gateway_server.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// 假传输：`tools/list` 回一条 shared 工具，`tools/call` 回 `echo:<name>`。
class _FakeTransport implements McpTransport {
  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final method = req['method'];
    final params = req['params'];
    final result = method == 'tools/list'
        ? {
            'tools': [
              {
                'name': 'echo',
                'description': 'd',
                'inputSchema': {'type': 'object'},
                '_meta': {
                  'goodhub': {'visibility': 'shared', 'tags': ['core']}
                },
              }
            ]
          }
        : {
            'content': [
              {
                'type': 'text',
                'text': 'echo:${params is Map ? params['name'] : ''}'
              }
            ]
          };
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': req['id'], 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      lines: Stream<String>.fromIterable([jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': 'echo'}
          ]
        }
      })]),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('假传输无 GET SSE');

  @override
  void close() {}
}

Future<(McpGatewayServer, String)> _startServer({
  Set<String> privateServerIds = const {},
  String? activePrivateServerId,
}) async {
  final demo = McpToolFace(client: McpClient(_FakeTransport()), serverId: 'demo');
  await demo.listTools();
  final host = McpToolFace(client: McpClient(_FakeTransport()), serverId: 'host');
  await host.listTools();
  final server = McpGatewayServer(GatewayHandler(
    faces: {'demo': demo, 'host': host},
    privateServerIds: privateServerIds,
    activePrivateServerId: activePrivateServerId,
  ));
  await server.start(address: InternetAddress.loopbackIPv4, port: 0);
  return (server, 'http://127.0.0.1:${server.port}/mcp');
}

Future<HttpClientResponse> _post(
  HttpClient c,
  String url,
  String body, {
  String? sessionId,
}) async {
  final req = await c.postUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.acceptHeader, 'application/json');
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  if (sessionId != null) req.headers.set('Mcp-Session-Id', sessionId);
  req.write(body);
  return req.close();
}

Future<Map<String, Object?>> _body(HttpClientResponse r) async =>
    jsonDecode(await r.transform(utf8.decoder).join()) as Map<String, Object?>;

List<String> _toolNames(Map<String, Object?> body) {
  final tools = ((body['result'] as Map)['tools']) as List;
  return [for (final t in tools) (t as Map)['name'] as String];
}

void main() {
  test('?strategy=single&server=host → 目录只含无前缀 host 工具', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      final r1 = await _post(
          c, '$base?strategy=single&server=host',
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      expect(r1.statusCode, 200);
      final sid = r1.headers.value('mcp-session-id');
      expect(sid, isNotNull);

      final names = _toolNames(await _body(await _post(
          c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          sessionId: sid)));
      expect(names, ['echo', GatewayHandler.kGatewaySelectPrivate],
          reason: 'single 剥前缀 + 只暴露目标服务（出口工具保留，列举工具隐匿）');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('后续请求改 URL 不影响已绑定策略（只读会话值）', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      final r1 = await _post(
          c, '$base?strategy=single&server=host',
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r1.headers.value('mcp-session-id')!;
      // 后续请求带 full 的 URL 参数——必须被忽略
      final names = _toolNames(await _body(await _post(
          c, '$base?strategy=full',
          jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          sessionId: sid)));
      expect(names, ['echo', GatewayHandler.kGatewaySelectPrivate],
          reason: '策略在 initialize 期冻结，后续 URL 无效');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('single 无前缀 tools/call 经服务端补齐直达目标 face', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      final r1 = await _post(
          c, '$base?strategy=single&server=host',
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r1.headers.value('mcp-session-id')!;
      final body = await _body(await _post(
          c, base,
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {'name': 'echo', 'arguments': <String, Object?>{}}
          }),
          sessionId: sid));
      final result = body['result'] as Map;
      expect(result['isError'], isFalse);
      expect(((result['content'] as List).single as Map)['text'], contains('echo'),
          reason: '补齐后直达 host face（回包文本含工具名）');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('single 下非出口控制面工具调用被拒（零泄漏）', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      final r1 = await _post(
          c, '$base?strategy=single&server=host',
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r1.headers.value('mcp-session-id')!;
      final body = await _body(await _post(
          c, base,
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {'name': GatewayHandler.kGatewayListServers}
          }),
          sessionId: sid));
      expect((body['result'] as Map)['isError'], isTrue);
      expect(((body['result'] as Map)['content'] as List).single.toString(),
          contains('single'));
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('Fail-Fast：single 目标未挂载 / 未知字面量 → initialize 返 -32602', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      for (final q in ['strategy=single&server=ghost', 'strategy=narrow']) {
        final body = await _body(await _post(
            c, '$base?$q',
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'})));
        expect((body['error'] as Map)['code'], -32602, reason: q);
        expect(body.containsKey('result'), isFalse,
            reason: '严禁静默初始化为空工具面（$q）');
      }
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('私有服务 single：连接级绑定（无需宿主先激活），宿主槽位零污染', () async {
    // 用户诉求：PC 就是要用私有服务、不想被公共面干扰，也不该依赖宿主手动切域。
    // 实现 = 本连接投影绑定到目标私有服务（权限集合与 gateway__select_private
    // 相同：仅改本连接，绝不触碰宿主槽位机）。
    final (server, base) = await _startServer(privateServerIds: {'demo'});
    final c = HttpClient();
    try {
      final r1 = await _post(
          c, '$base?strategy=single&server=demo',
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      expect(r1.statusCode, 200,
          reason: '已挂载的私有服务不得因宿主未激活而失败（此前会给空目录）');
      final sid = r1.headers.value('mcp-session-id')!;
      final names = _toolNames(await _body(await _post(
          c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          sessionId: sid)));
      expect(names, ['echo', GatewayHandler.kGatewaySelectPrivate],
          reason: '只暴露目标私有服务的裸名工具，公共面零泄漏（出口工具除外）');

      // 调用直达该私有 face（补齐后剥前缀分发）
      final called = await _body(await _post(
          c, base,
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': {'name': 'echo', 'arguments': <String, Object?>{}}
          }),
          sessionId: sid));
      expect((called['result'] as Map)['isError'], isFalse);

      // 同一宿主上另一连接（full）的私有投影不受影响 → 宿主槽位零污染
      final r2 = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final fullNames = _toolNames(await _body(await _post(
          c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          sessionId: r2.headers.value('mcp-session-id')!)));
      expect(fullNames, isNot(contains('demo__echo')),
          reason: 'single 的连接级绑定不得外溢到其他连接/宿主默认投影');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('Fail-Fast：single 目标未挂载 → -32602（不给空目录）', () async {
    final (server, base) = await _startServer(privateServerIds: {'demo'});
    final c = HttpClient();
    try {
      final body = await _body(await _post(
          c, '$base?strategy=single&server=ghost',
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'})));
      expect((body['error'] as Map)['code'], -32602);
      expect(body.containsKey('result'), isFalse,
          reason: '严禁静默初始化为空工具面');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('默认（无参）连接行为不变：全量前缀面 + 系统工具', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      final r1 = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r1.headers.value('mcp-session-id')!;
      final names = _toolNames(await _body(await _post(
          c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          sessionId: sid)));
      expect(names, contains('demo__echo'));
      expect(names, contains('host__echo'));
      expect(names, contains(GatewayHandler.kGatewaySelectPrivate));
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });
  group('单轴化：URL 键 policy 为主名 / strategy 为兼容别名（D1）', () {
    test('?policy=single&server=host → 目录只含无前缀 host 工具（新键）', () async {
      final (server, base) = await _startServer();
      final c = HttpClient();
      try {
        final r1 = await _post(
            c, '$base?policy=single&server=host',
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
        expect(r1.statusCode, 200);
        final sid = r1.headers.value('mcp-session-id');
        final names = _toolNames(await _body(await _post(
            c, base,
            jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
            sessionId: sid)));
        expect(names, ['echo', GatewayHandler.kGatewaySelectPrivate],
            reason: '新键 policy 与旧键 strategy 同义，行为逐字一致');
      } finally {
        c.close(force: true);
        await server.stop();
      }
    });

    test('?policy=full → 联邦面（含旧键 strategy=full 的等价语义）', () async {
      final (server, base) = await _startServer();
      final c = HttpClient();
      try {
        final r1 = await _post(c, '$base?policy=full',
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
        final sid = r1.headers.value('mcp-session-id');
        final names = _toolNames(await _body(await _post(
            c, base,
            jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
            sessionId: sid)));
        expect(names, containsAll(['demo__echo', 'host__echo']));
      } finally {
        c.close(force: true);
        await server.stop();
      }
    });

    test('Fail-Fast：?policy=private 目标未挂载 → initialize 返 -32602', () async {
      final (server, base) = await _startServer();
      final c = HttpClient();
      try {
        final r1 = await _post(c, '$base?policy=private&server=ghost',
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
        final body = await _body(r1);
        expect((body['error'] as Map)['code'], -32602);
      } finally {
        c.close(force: true);
        await server.stop();
      }
    });

    test('?policy=private&server=<已挂载私有> → 连接级私有绑定（联邦面 + 该私有）',
        () async {
      final (server, base) = await _startServer(privateServerIds: {'host'});
      final c = HttpClient();
      try {
        final r1 = await _post(c, '$base?policy=private&server=host',
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
        expect(r1.statusCode, 200);
        final sid = r1.headers.value('mcp-session-id');
        final names = _toolNames(await _body(await _post(
            c, base,
            jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
            sessionId: sid)));
        expect(names, containsAll(['demo__echo', 'host__echo']),
            reason: 'private 档 = 联邦面 + 该私有服务（连接级绑定，宿主槽位零污染）');
      } finally {
        c.close(force: true);
        await server.stop();
      }
    });
  });

}
