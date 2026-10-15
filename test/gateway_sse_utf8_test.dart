// 回归：网关 SSE 响应分支必须用 UTF-8 编码（修复前缺 charset → dart:io 退回
// Latin-1，遇到中文等非 ASCII 工具描述直接抛 "Contains invalid characters" 500）。
// 此前 in-process 测试只走了 ASCII 工具面，漏掉该缺陷（thirdconnect §7 PC→手机
// 经 adb 转发真实链路必现，因 dummy 插件工具描述含中文）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/gateway/gateway_server.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// 返回含中文的 tools/list / tools/call 罐头响应，复刻 dummy 插件真实负载。
class _FakeTransport implements McpTransport {
  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final method = req['method'];
    if (method == 'tools/list') {
      return TransportResponse(
        statusCode: 200,
        contentType: 'application/json',
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': req['id'],
          'result': {
            'tools': [
              {
                'name': 'add',
                'description': '两个整数相加',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'a': {'type': 'integer', 'description': '加数'},
                    'b': {'type': 'integer', 'description': '被加数'},
                  },
                  'required': ['a', 'b'],
                },
              }
            ]
          },
        }),
      );
    }
    if (method == 'tools/call') {
      return TransportResponse(
        statusCode: 200,
        contentType: 'application/json',
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': req['id'],
          'result': {
            'content': [
              {'type': 'text', 'text': '中文结果 hello'},
            ],
            'isError': false,
          },
        }),
      );
    }
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {
          'protocolVersion': '2025-06-18',
          'capabilities': {},
          'serverInfo': {'name': 'fake'},
        },
      }),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final frame = jsonEncode({
      'jsonrpc': '2.0',
      'id': req['id'],
      'result': {
        'content': [
          {'type': 'text', 'text': '中文流式结果'},
        ],
        'isError': false,
      },
    });
    // 行分离的 SSE（与 HttpTransport 的 LineSplitter 行为一致）；用 fromIterable
    // 保证监听订阅后才逐行发射并自然结束，规避 pre-closed StreamController 挂起。
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'text/event-stream',
      lines: Stream<String>.fromIterable(
          ['event: message', 'data: $frame', '', '']),
    );
  }

  @override
  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('test transport 不支持 GET SSE 订阅通道');

  @override
  void close() {}
}

Future<Map<String, Object?>> _ssePost(
  String host,
  int port,
  String sessionId,
  Map<String, Object?> body,
) async {
  final client = HttpClient();
  final req = await client.post(host, port, '/mcp');
  req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
  if (sessionId.isNotEmpty) req.headers.set('mcp-session-id', sessionId);
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode(body));
  final resp = await req.close();
  final raw = await resp.transform(utf8.decoder).join();
  client.close();
  // SSE 帧：取首个 data: 行解析 JSON-RPC。
  final dataLine = raw
      .split('\n')
      .firstWhere((l) => l.startsWith('data:'), orElse: () => 'data: {}');
  final payload = jsonDecode(dataLine.substring(5).trim()) as Map<String, Object?>;
  return {'status': resp.statusCode, 'payload': payload};
}

void main() {
  test('gateway SSE encodes non-ASCII (Chinese) tool metadata', () async {
    final client = McpClient(_FakeTransport());
    final face = McpToolFace(client: client, serverId: 'dummy');
    await face.listTools(); // 填充含中文的 cachedSchemas

    final handler = GatewayHandler(faces: {'dummy': face}, security: null);
    final server = McpGatewayServer(handler);
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final port = server.port;
    addTearDown(() => server.stop());

    // initialize（SSE）拿 mcp-session-id（_ssePost 不暴露 header，单独取）
    final c2 = HttpClient();
    final r2 = await c2.post('127.0.0.1', port, '/mcp')
      ..headers.set(HttpHeaders.acceptHeader, 'text/event-stream')
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
      }));
    final resp2 = await r2.close();
    final sid = resp2.headers.value('mcp-session-id') ?? '';
    await resp2.drain<void>();
    c2.close();
    expect(sid, isNotEmpty);

    // tools/list（SSE，含中文描述）—— 修复前此处抛 500
    final list = await _ssePost('127.0.0.1', port, sid, {
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    expect(list['status'], 200,
        reason: 'SSE tools/list 必须正常返回（修复前为 500）');
    final tools = (list['payload']! as Map)['result'] as Map;
    final names = (tools['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(names, contains('dummy__add'));
    final desc = ((tools['tools'] as List)
        .firstWhere((t) => (t as Map)['name'] == 'dummy__add')
        as Map)['description'];
    expect(desc, '两个整数相加', reason: '中文描述须原样 UTF-8 透传');

    // tools/call（SSE，中文结果）
    final call = await _ssePost('127.0.0.1', port, sid, {
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {
        'name': 'dummy__add',
        'arguments': {'a': 1, 'b': 2},
      },
    });
    expect(call['status'], 200,
        reason: 'SSE tools/call 必须正常返回（修复前为 500）');
    final callResult = (call['payload']! as Map)['result'] as Map;
    final text = (callResult['content'] as List)
        .map((c) => (c as Map)['text'])
        .join();
    expect(text, contains('中文'), reason: '中文结果须原样 UTF-8 透传');
  });
}
