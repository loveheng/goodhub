/// M4-T5 节点卡探活单测（server_probe.dart）：握手 + tools/list 计时取数、
/// 401/403 鉴权态与离线的显式区分（F1.17）、失败不抛穿（结果承载观测值）。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_probe.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Object result) => http.Response(
      '{"jsonrpc":"2.0","id":1,"result":${json.jsonEncode(result)}}',
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _status(int code) => http.Response('denied', code);

/// 按方法路由的假 server：initialize / notifications/initialized / tools/list。
MockClient mockRoute({
  Object? initResult,
  Object? toolsResult,
  http.Response Function(String method)? override,
  Future<http.Response> Function(http.Request)? slow,
}) =>
    MockClient((req) async {
      if (slow != null) return slow(req);
      final body = json.jsonDecode(req.body) as Map;
      final method = body['method'] as String?;
      final resp = override?.call(method ?? '');
      if (resp != null) return resp;
      if (method == 'initialize') {
        return _ok(initResult ?? {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake', 'version': '1.0'},
        });
      }
      if (method == 'notifications/initialized') {
        return http.Response('', 202);
      }
      if (method == 'tools/list') {
        return _ok(toolsResult ??
            {
              'tools': [
                {'name': 'a'},
                {'name': 'b'},
                {'name': 'c'},
              ],
            });
      }
      return _ok({});
    });

McpClientFactory factoryWith(MockClient mock) =>
    (endpoint, apiKey) => McpClient.http(
          baseUrl: endpoint,
          apiKey: apiKey,
          httpClient: mock,
        );

void main() {
  const ep = 'http://127.0.0.1:8765/mcp';

  test('在线：握手 + 工具计数 + 计时（绿点态）', () async {
    final prober = ServerProber(clientFactory: factoryWith(mockRoute()));
    final r = await prober.probe(ep, apiKey: 'sk-test');
    expect(r.online, isTrue);
    expect(r.authDenied, isFalse);
    expect(r.toolCount, 3);
    expect(r.latencyMs, isNotNull);
    expect(r.latencyMs! >= 0, isTrue);
    expect(r.error, isNull);
  });

  test('apiKey 空/缺省不传鉴权头（探活与生产同口径）', () async {
    var sawKey = false;
    final prober = ServerProber(
      clientFactory: (endpoint, apiKey) {
        sawKey = apiKey != null;
        return McpClient.http(baseUrl: endpoint, apiKey: apiKey);
      },
    );
    // 连不上的端点即可——本测只断言工厂收到的 apiKey 形态。
    await prober.probe(ep);
    expect(sawKey, isFalse, reason: '无令牌不应传 apiKey');
  });

  test('403 → 待授权（Rose），非离线灰阶（F1.17）', () async {
    final prober = ServerProber(
        clientFactory: factoryWith(mockRoute(override: (_) => _status(403))));
    final r = await prober.probe(ep);
    expect(r.online, isFalse);
    expect(r.authDenied, isTrue);
  });

  test('401 → 同待授权口径', () async {
    final prober = ServerProber(
        clientFactory: factoryWith(mockRoute(override: (_) => _status(401))));
    final r = await prober.probe(ep);
    expect(r.online, isFalse);
    expect(r.authDenied, isTrue);
  });

  test('连接失败 → 离线（authDenied=false，错误文本承载）', () async {
    final prober = ServerProber(
      clientFactory: factoryWith(MockClient((_) async {
        throw http.ClientException('connection refused');
      })),
    );
    final r = await prober.probe(ep);
    expect(r.online, isFalse);
    expect(r.authDenied, isFalse);
    expect(r.error, isNotNull);
  });

  test('超时 → 离线（单方法 timeout 兜底，不悬挂）', () async {
    final prober = ServerProber(
      timeout: const Duration(milliseconds: 40),
      clientFactory: factoryWith(mockRoute(
        slow: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return _ok({});
        },
      )),
    );
    final r = await prober.probe(ep);
    expect(r.online, isFalse);
    expect(r.error, isNotNull);
  });

  test('tools/list 形状异常 → 在线但工具数不可知（观测留痕不假报）', () async {
    final prober = ServerProber(
        clientFactory: factoryWith(mockRoute(toolsResult: 'not-a-map')));
    final r = await prober.probe(ep);
    expect(r.online, isTrue, reason: '握手已通即在先');
    expect(r.toolCount, isNull);
    expect(r.error, contains('not an object'));
  });
}
