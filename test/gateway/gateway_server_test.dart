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

/// 无 progress 的慢调用传输：延迟 600ms 只发终帧——模拟「下游不支持 progress」
/// 的长调用（PC 端此时只能靠网关侧 Keep-Alive 帧喂狗，否则 60s 超时掉线）。
class _SilentSlowTransport extends _FakeTransport {
  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    Stream<String> gen() async* {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      yield 'data: ${jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': 'ok-silent-slow'},
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

  test('SSE 订阅断开 ≠ 会话结束：同 sid 后续请求仍可用（无线断续不再 400）',
      () async {
    // 用户症状：无线使用过一段时间连接自动掉线。根因之一：GET SSE 订阅通道
    // 一断（NAT 空闲超时 / Wi-Fi 抖动 / 半开）即**销毁整个会话** → PC 复用旧
    // sid 继续请求时吃 400「unknown Mcp-Session-Id」= 掉线。
    final (server, base) = await _startServer();
    final c = HttpClient();
    final sub = HttpClient();
    try {
      final r0 = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r0.headers.value('mcp-session-id')!;
      // 建立 GET SSE 订阅通道。
      final subReq = await sub.openUrl('GET', Uri.parse(base));
      subReq.headers.set('mcp-session-id', sid);
      final subResp = await subReq.close();
      expect(subResp.statusCode, 200);
      // 订阅通道断开（模拟 NAT 空闲超时 / Wi-Fi 抖动）。
      sub.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 客户端复用同一 sid 继续请求。
      final r2 = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          sessionId: sid);
      expect(r2.statusCode, 200,
          reason: 'SSE 订阅断开不得销毁会话——否则 PC 复用旧 sid 直接 400 掉线');
      final b2 =
          jsonDecode(await r2.transform(utf8.decoder).join()) as Map;
      final names = [
        for (final t in (b2['result'] as Map)['tools'] as List)
          (t as Map)['name'] as String
      ];
      expect(names, contains('demo__echo'));
    } finally {
      sub.close(force: true);
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

  test('POST-only 连接：闲置后 handler 内存态被回收，会话 sid 仍有效', () async {
    // 纯 POST 客户端不维持 SSE 订阅通道 → 由 idle GC 按 idleTimeout 回收其
    // **内存态**（handler + L2 豁免集，防长期运行累积泄漏）。
    //
    // **2026-10-23 语义收口**：会话条目（sid）**不再按时间删除**——PC 侧可能
    // 任意时刻回来用旧 sid（无线下连接断续是常态），一旦 400 就是「掉线」体感。
    // 旧实现此处断言 400（sid 失效），现断言 200（sid 长期有效，handler 重建）。
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
      // 远超 idleTimeout 无活动 → idle GC 回收内存态，但会话条目保留。
      await Future.delayed(const Duration(milliseconds: 350));
      final rStale = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'}),
          sessionId: sid);
      expect(rStale.statusCode, 200,
          reason: 'sid 长期有效——客户端复用旧 sid 必须继续可用（不再 400 掉线）');
      final bStale =
          jsonDecode(await rStale.transform(utf8.decoder).join()) as Map;
      final names = [
        for (final t in (bStale['result'] as Map)['tools'] as List)
          (t as Map)['name'] as String
      ];
      expect(names, contains('demo__echo'),
          reason: 'handler 重建后工具面仍完整（策略与 face 均恢复）');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  // F10（review-fix-2026-10）：`gateway__select_private` 切换只改 handler 实例，
  // 会话条目此前是 final 旧值——idle GC 重建 handler 按建连值恢复，PC 投影
  // 无感知回退（差分基线还抑制了 list_changed，PC 无从得知）。修复 = 切换落定
  // 经 onProjectionApplied 写回会话条目，重建恢复最新投影。撤修复即红（第 6
  // 步变回全量前缀面）。
  test('F10：select_private 切换在 idle GC 重建后保持（无感回退即红）', () async {
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
      Future<List<String>> toolNames(String sid, int id) async {
        final r = await _post(c, base,
            jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': 'tools/list'}),
            sessionId: sid);
        final b = jsonDecode(await r.transform(utf8.decoder).join()) as Map;
        return [
          for (final t in (b['result'] as Map)['tools'] as List)
            (t as Map)['name'] as String
        ];
      }

      final r0 = await _post(c, base,
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
      final sid = r0.headers.value('mcp-session-id')!;
      expect(await toolNames(sid, 2), contains('demo__echo'),
          reason: '前置：默认全量前缀面');

      final rSwitch = await _post(c, base,
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': {
              'name': 'gateway__select_private',
              'arguments': {'server_id': 'demo', 'policy': 'single'},
            },
          }),
          sessionId: sid);
      final bSwitch =
          jsonDecode(await rSwitch.transform(utf8.decoder).join()) as Map;
      expect(bSwitch.containsKey('error'), isFalse,
          reason: '切换成功：${bSwitch['error']}');
      expect(await toolNames(sid, 4), isNot(contains('demo__echo')),
          reason: '前置：single 投影 = 无前缀目标面');

      // 远超 idleTimeout 无活动 → handler 内存态被回收。
      await Future.delayed(const Duration(milliseconds: 350));
      expect(await toolNames(sid, 5), isNot(contains('demo__echo')),
          reason: 'F10：重建后投影仍为所选项（回退全量即红）');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('TC12 Keep-Alive：长调用期间推 progress 帧喂狗（PC 60s 超时对策）',
      () async {
    // 设计稿 thirdconnect §10.4：PC 规则 = 连续 60s 收不到任何 HTTP 数据包即超时。
    // 下游无 progress 支持的长调用此前在网关侧静默 → PC 掉线；本例锁定「流中
    // 注入 Keep-Alive 帧」这一行为（帧必须早于终帧到达，证明非收尾补写）。
    final face = McpToolFace(
        client: McpClient(_SilentSlowTransport()), serverId: 'silent');
    await face.listTools();
    final server = McpGatewayServer(
      GatewayHandler(faces: {'silent': face}),
      keepAliveInterval: const Duration(milliseconds: 100),
    );
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
          'id': 5,
          'method': 'tools/call',
          'params': {'name': 'silent__echo', 'arguments': <String, Object?>{}},
        }),
        accept: 'text/event-stream',
        sessionId: sid,
      );
      expect(r.statusCode, 200);
      final sw = Stopwatch()..start();
      var keepAliveCount = 0;
      Duration? tFirstKeepAlive;
      Duration? tFinal;
      await for (final line
          in r.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final frame =
            jsonDecode(line.substring('data: '.length)) as Map<String, Object?>;
        if (frame['method'] == 'notifications/progress') {
          keepAliveCount++;
          tFirstKeepAlive ??= sw.elapsed;
          final params = frame['params'] as Map<String, Object?>;
          expect(params['progressToken'], isNotNull,
              reason: 'progress 帧须带 progressToken 供客户端关联本次调用');
          expect(params['message'], contains('silent__echo'));
        } else if (frame['id'] == 5) {
          tFinal = sw.elapsed;
        }
      }
      expect(tFirstKeepAlive, isNotNull,
          reason: '长调用期间须有 Keep-Alive 帧喂狗（否则 PC 60s 超时掉线）');
      expect(keepAliveCount, greaterThanOrEqualTo(3),
          reason: '600ms 内按 100ms 间隔应收到多条 Keep-Alive 帧');
      expect(tFirstKeepAlive!.inMilliseconds, lessThan(tFinal!.inMilliseconds),
          reason: 'Keep-Alive 帧必须早于终帧到达（证明是流中注入）');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  // B14（review-fix-2026-10 拍板①）：免鉴权强制绑回环——「无凭据 ⇔ 仅本机
  // 可达」结构化收口；显式传入 anyIPv4 不得覆盖不变式。撤修复即红。
  test('B14：免鉴权 → 强制 loopback；带 Token → 尊重传入地址', () async {
    final face = McpToolFace(client: McpClient(_FakeTransport()), serverId: 'demo');
    await face.listTools();
    // 免鉴权：显式 anyIPv4 也被强制回环。
    final open = McpGatewayServer(GatewayHandler(faces: {'demo': face}));
    await open.start(address: InternetAddress.anyIPv4, port: 0);
    try {
      expect(open.bindAddress!.isLoopback, isTrue,
          reason: 'B14：无凭据监听必须收敛到 loopback（ADB 转发场景不受影响）');
    } finally {
      await open.stop();
    }
    // 带 Token：尊重调用方地址（LAN 暴露语义不变）。
    final secured = McpGatewayServer(GatewayHandler(faces: {'demo': face}))
      ..requiredToken = 'secret';
    await secured.start(address: InternetAddress.anyIPv4, port: 0);
    try {
      expect(secured.bindAddress!.isLoopback, isFalse,
          reason: '带凭据的 LAN 监听不被强制回环');
    } finally {
      await secured.stop();
    }
  });
}
