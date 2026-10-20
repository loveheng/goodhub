/// 网关服务器 e2e（G1/G2）：假 Binder 传输 face → 真回环 HTTP 全链路——
/// initialize（会话下发）→ tools/list 聚合（前缀化）→ tools/call SSE 流式
/// （progress 帧 + 终帧）→ 会话强制 → Bearer Token（G3 最小件）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/gateway/gateway_server.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// 假 Binder 传输：initialize/tools/list/tools/call 最小 server 语义；
/// sendStream 回 SSE（progress 通知帧 + 终帧 result），send 回单 JSON。
class _FakeTransport implements McpTransport {
  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final Object result;
    switch (req['method'] as String?) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{'tools': <String, Object?>{}},
        };
      case 'tools/list':
        result = {
          'tools': [
            {
              'name': 'echo',
              'description': '回声',
              'inputSchema': <String, Object?>{'type': 'object'},
              // SDK 0.2.0：对外暴露须显式声明 shared（缺失即 private，不投影）
              '_meta': <String, Object?>{
                'goodhub': <String, Object?>{'visibility': 'shared'},
              },
            },
          ],
        };
      case 'tools/call':
        result = {
          'content': [
            {'type': 'text', 'text': 'ok-${_toolName(req)}'},
          ],
        };
      default:
        result = <String, Object?>{};
    }
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': req['id'], 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final tool = _toolName(req);
    final lines = [
      'data: ${jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': <String, Object?>{'progress': 1, 'total': 2},
      })}',
      '',
      'data: ${jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': 'ok-$tool'},
          ],
        },
      })}',
      '',
    ];
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'text/event-stream',
      lines: Stream.fromIterable(lines),
    );
  }

  static String _toolName(Map<String, Object?> req) =>
      ((req['params'] as Map?)?['name'] as String?) ?? '?';

  @override
  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('test transport 不支持 GET SSE 订阅通道');

  @override
  void close() {}
}

/// 慢进度传输：progress 帧后真实延迟 400ms 才发终帧——为「进度即达」回归钉子
/// 提供时间间隔（缓冲滞留时 progress 与终帧同刻到达，即达时相隔 ≈400ms）。
class _SlowProgressTransport extends _FakeTransport {
  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    Stream<String> gen() async* {
      yield 'data: ${jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': <String, Object?>{'progress': 1, 'total': 2},
      })}';
      yield '';
      await Future<void>.delayed(const Duration(milliseconds: 400));
      yield 'data: ${jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': 'ok-slow'},
          ],
        },
      })}';
      yield '';
    }

    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'text/event-stream',
      lines: gen(),
    );
  }
}

Future<HttpClientResponse> _post(
  HttpClient c,
  String url,
  String body, {
  String accept = 'application/json',
  String? sessionId,
  String? auth,
}) async {
  final req = await c.postUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.acceptHeader, accept);
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  if (sessionId != null) req.headers.set('Mcp-Session-Id', sessionId);
  if (auth != null) req.headers.set(HttpHeaders.authorizationHeader, auth);
  req.write(body);
  return req.close();
}

Future<(McpGatewayServer, String)> _startServer(
    {Map<String, McpToolFace>? faces}) async {
  final face = McpToolFace(client: McpClient(_FakeTransport()), serverId: 'demo');
  await face.listTools();
  final server = McpGatewayServer(GatewayHandler(faces: faces ?? {'demo': face}));
  await server.start(address: InternetAddress.loopbackIPv4, port: 0);
  return (server, 'http://127.0.0.1:${server.port}/mcp');
}

void main() {
  test('initialize 下发会话 → tools/list 聚合前缀化', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      final r1 = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      expect(r1.statusCode, 200);
      final sid = r1.headers.value('mcp-session-id');
      expect(sid, isNotNull);
      final b1 =
          jsonDecode(await r1.transform(utf8.decoder).join()) as Map;
      expect(((b1['result'] as Map)['serverInfo'] as Map)['name'],
          'GoodHub Gateway');

      final r2 = await _post(
        c,
        base,
        jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
        sessionId: sid!,
      );
      final b2 =
          jsonDecode(await r2.transform(utf8.decoder).join()) as Map;
      final tools = (b2['result'] as Map)['tools'] as List;
      final names = [for (final t in tools) (t as Map)['name'] as String];
      // 聚合前缀化 + 网关级系统工具 gateway__select_private 一并投影。
      expect(names, contains('demo__echo'));
      expect(names, contains(GatewayHandler.kGatewaySelectPrivate));
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('tools/call SSE 流式：progress 帧 + 终帧 result', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      final r0 = await _post(
          c, base, jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r0.headers.value('mcp-session-id')!;
      final r = await _post(
        c,
        base,
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 7,
          'method': 'tools/call',
          'params': {'name': 'demo__echo', 'arguments': {'msg': 'hi'}},
        }),
        accept: 'text/event-stream',
        sessionId: sid,
      );
      expect(r.statusCode, 200);
      expect(r.headers.contentType.toString(), contains('event-stream'));
      final body = await r.transform(utf8.decoder).join();
      expect(body, contains('notifications/progress'));
      expect(body, contains('"id":7'));
      expect(body, contains('ok-echo'));
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('SSE 进度帧即达（bufferOutput=false 回归钉子）：progress 先于终帧到达',
      () async {
    // 教训（lessons.md mcp/传输段 + goodshare M3-T1）：HttpResponse.bufferOutput
    // 默认 true 会把 SSE 中途帧缓冲到连接关闭一次性吐出——join() 读完再断言的
    // 测试抓不到（AtomCode 真网实测 slowEcho 4 帧 progress 挤压在收尾 1ms）。
    // 本测试逐帧计时：假传输 progress 与终帧间隔真实 400ms，若被缓冲两者同刻到达。
    final face =
        McpToolFace(client: McpClient(_SlowProgressTransport()), serverId: 'slow');
    await face.listTools();
    final server = McpGatewayServer(GatewayHandler(faces: {'slow': face}));
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final base = 'http://127.0.0.1:${server.port}/mcp';
    final c = HttpClient();
    try {
      final r0 = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r0.headers.value('mcp-session-id')!;
      final r = await _post(
        c,
        base,
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'tools/call',
          'params': {'name': 'slow__echo', 'arguments': <String, Object?>{}},
        }),
        accept: 'text/event-stream',
        sessionId: sid,
      );
      expect(r.statusCode, 200);
      final sw = Stopwatch()..start();
      Duration? tProgress;
      Duration? tFinal;
      await for (final line
          in r.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        if (line.contains('notifications/progress')) {
          tProgress ??= sw.elapsed;
        } else if (line.contains('"id":9')) {
          tFinal = sw.elapsed;
          break;
        }
      }
      expect(tProgress, isNotNull, reason: '应收到 progress 帧');
      expect(tFinal, isNotNull, reason: '应收到终帧');
      expect(tProgress!.inMilliseconds, lessThan(250),
          reason: 'progress 帧应在 250ms 内即达（缓冲滞留时 ≈终帧时刻 400ms+）');
      expect(tFinal!.inMilliseconds - tProgress.inMilliseconds,
          greaterThan(200),
          reason: 'progress 与终帧应有真实间隔（分段即达，非收尾一次性吐出）');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('会话强制：无 Mcp-Session-Id → 400', () async {
    final (server, base) = await _startServer();
    final c = HttpClient();
    try {
      final r = await _post(
          c, base, jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}));
      expect(r.statusCode, 400);
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('Bearer Token 校验（G3 最小件）：无 Token 401 / 有 Token 通过', () async {
    final face = McpToolFace(client: McpClient(_FakeTransport()), serverId: 'demo');
    await face.listTools();
    final server =
        McpGatewayServer(GatewayHandler(faces: {'demo': face}));
    server.requiredToken = 'secret';
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final base = 'http://127.0.0.1:${server.port}/mcp';
    final c = HttpClient();
    try {
      final r1 = await _post(
          c, base, jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      expect(r1.statusCode, 401);
      final r2 = await _post(
        c,
        base,
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}),
        auth: 'Bearer secret',
      );
      expect(r2.statusCode, 200);
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('POST-only 连接投影上下文 idle GC（#7 泄漏修复）', () async {
    // 纯 POST 客户端不维持 SSE 订阅通道，断连时无法经 _handleGet 的 done 清理，
    // 须由 idle GC 按 idleTimeout 回收其 handler/session 条目（否则长期运行网关累积泄漏）。
    final face = McpToolFace(client: McpClient(_FakeTransport()), serverId: 'demo');
    await face.listTools();
    final server = McpGatewayServer(
      GatewayHandler(faces: {'demo': face}),
      idleTimeout: const Duration(milliseconds: 100),
    );
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final base = 'http://127.0.0.1:${server.port}/mcp';
    final c = HttpClient();
    try {
      // 纯 POST 初始化（不订阅 SSE）。
      final r0 = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r0.headers.value('mcp-session-id')!;
      // 会话立即可用。
      final rList = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          sessionId: sid);
      expect(rList.statusCode, 200);
      // 超过 idleTimeout 无活动 → idle GC 回收纯 POST 连接。
      await Future.delayed(const Duration(milliseconds: 350));
      final rStale = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'}),
          sessionId: sid);
      expect(rStale.statusCode, 400,
          reason: 'idle GC 应已回收纯 POST 连接，旧 sid 应不可知');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });
}
