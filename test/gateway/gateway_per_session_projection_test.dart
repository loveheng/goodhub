/// 阶段二 D-D 投影隔离验收（per-connection projection）：
/// 模拟两个不同 Mcp-Session-Id 的客户端连接，验证各自 `tools/list` 投影独立、
/// `gateway__select_private` 仅改写本连接激活私有、宿主内部 activePrivateServerId
/// 保持零污染。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/gateway/gateway_server.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// 可配置 tools/list 的假传输：每个 face 注入各自工具清单，tools/call 回 ok。
class _ListTransport implements McpTransport {
  _ListTransport(this._tools);
  final List<Map<String, Object?>> _tools;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final result = switch (req['method'] as String?) {
      'tools/list' => {'tools': _tools},
      'initialize' => {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
        },
      _ => {
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
        },
    };
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': req['id'], 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      throw UnsupportedError('unused in this test');
  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('unused in this test');
  @override
  void close() {}
}

Future<McpToolFace> _face(McpTransport t, String id) async {
  final f = McpToolFace(client: McpClient(t), serverId: id);
  await f.listTools();
  return f;
}

Future<HttpClientResponse> _post(
  HttpClient c,
  String url,
  String body, {
  String accept = 'application/json',
  String? sessionId,
}) async {
  final req = await c.postUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.acceptHeader, accept);
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  if (sessionId != null) req.headers.set('Mcp-Session-Id', sessionId);
  req.write(body);
  return req.close();
}

Future<String> _init(HttpClient c, String base) async {
  final r = await _post(
    c,
    base,
    jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}),
  );
  expect(r.statusCode, 200);
  final sid = r.headers.value('mcp-session-id');
  expect(sid, isNotNull);
  return sid!;
}

Future<List<String>> _listTools(HttpClient c, String base, String sid) async {
  final r = await _post(
    c,
    base,
    jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
    sessionId: sid,
  );
  final b = jsonDecode(await r.transform(utf8.decoder).join()) as Map;
  final tools = (b['result'] as Map)['tools'] as List;
  return [for (final t in tools) (t as Map)['name'] as String];
}

Future<Map<String, Object?>> _call(
  HttpClient c,
  String base,
  String sid,
  String name,
  Map<String, Object?> args,
) async {
  final r = await _post(
    c,
    base,
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    }),
    sessionId: sid,
  );
  return jsonDecode(await r.transform(utf8.decoder).join()) as Map<String, Object?>;
}

void main() {
  test('阶段二 D-D：两连接独立私有投影 + 宿主零污染', () async {
    final pub = await _face(
      _ListTransport([
        {'name': 'common', 'description': '', 'inputSchema': {}},
      ]),
      'pub',
    );
    final srvA = await _face(
      _ListTransport([
        {'name': 'a_tool', 'description': '', 'inputSchema': {}},
      ]),
      'srv_a',
    );
    final srvB = await _face(
      _ListTransport([
        {'name': 'b_tool', 'description': '', 'inputSchema': {}},
      ]),
      'srv_b',
    );
    // 模板 handler：宿主默认激活私有 = null（公共面）。
    final template = GatewayHandler(
      faces: {'pub': pub, 'srv_a': srvA, 'srv_b': srvB},
      privateServerIds: {'srv_a', 'srv_b'},
      activePrivateServerId: null,
      security: null,
    );
    final server = McpGatewayServer(template);
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final base = 'http://127.0.0.1:${server.port}/mcp';
    final c = HttpClient();
    try {
      // —— Client A：选 srv_a ——
      final sidA = await _init(c, base);
      final selA = await _call(
        c,
        base,
        sidA,
        GatewayHandler.kGatewaySelectPrivate,
        {'server_id': 'srv_a'},
      );
      expect((selA['result'] as Map)['isError'], isFalse);
      final listA = await _listTools(c, base, sidA);
      expect(listA, contains('srv_a__a_tool'));
      expect(listA, isNot(contains('srv_b__b_tool')));
      expect(listA, contains(GatewayHandler.kGatewaySelectPrivate));

      // —— Client B：选 srv_b ——
      final sidB = await _init(c, base);
      final selB = await _call(
        c,
        base,
        sidB,
        GatewayHandler.kGatewaySelectPrivate,
        {'server_id': 'srv_b'},
      );
      expect((selB['result'] as Map)['isError'], isFalse);
      final listB = await _listTools(c, base, sidB);
      expect(listB, contains('srv_b__b_tool'));
      expect(listB, isNot(contains('srv_a__a_tool')));
      expect(listB, contains(GatewayHandler.kGatewaySelectPrivate));

      // 两连接投影互不相同。
      expect(listA, isNot(equals(listB)));

      // A 选 srv_a 后仍调 srv_b → 防火墙拒绝（基于 A 自身投影）。
      final badA = await _call(c, base, sidA, 'srv_b__b_tool', {});
      expect((badA['result'] as Map)['isError'], isTrue);

      // 非法 server_id → 拒绝且不污染宿主。
      final selBad = await _call(
        c,
        base,
        sidA,
        GatewayHandler.kGatewaySelectPrivate,
        {'server_id': 'nope'},
      );
      expect((selBad['result'] as Map)['isError'], isTrue);

      // 宿主内部 activePrivateServerId 零污染（仍为空 = 公共面默认）。
      expect(template.activePrivateServerId, isNull);
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });
}
