/// M2.5-T2 能力协商单测：ServerCapabilities 解析防御矩阵 + Tier 判定 +
/// C-4 静态摘要封顶 + McpClient.negotiate 幂等/降级语义。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_capabilities.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Object? payload) => http.Response(
      '{"jsonrpc":"2.0","id":1,"result":${json.jsonEncode(payload)}}',
      200,
      headers: {'content-type': 'application/json'},
    );

ServerCapabilities _caps(Object? result) => ServerCapabilities.parse(result);

void main() {
  group('ServerCapabilities.parse', () {
    test('Tier 1：prompts+resources 声明齐全（goodshare 全量形态）', () {
      final caps = _caps({
        'protocolVersion': '2025-06-18',
        'capabilities': {
          'tools': {'listChanged': false},
          'prompts': <String, Object?>{},
          'resources': <String, Object?>{},
        },
        'serverInfo': {'name': 'goodshare', 'version': '1.0.0'},
        'instructions': '说明',
      });
      expect(caps.isTier1, isTrue);
      expect(caps.isTier2, isFalse);
      expect(caps.hasTools, isTrue);
      expect(caps.serverName, 'goodshare');
      expect(caps.instructions, '说明');
    });

    test('Tier 2：仅 tools（vanilla 形态）——字段缺省即无能力，不抛异常', () {
      final caps = _caps({
        'protocolVersion': '2025-06-18',
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {'name': 'sqlite', 'version': '0.6'},
      });
      expect(caps.isTier2, isTrue);
      expect(caps.hasPrompts, isFalse);
      expect(caps.hasResources, isFalse);
    });

    test('capabilities 整体缺失 / serverInfo 缺失 → 全 false + 字段 null（Polyfill 缺省）', () {
      final caps = _caps({'protocolVersion': '2025-03-26'});
      expect(caps.isTier2, isTrue);
      expect(caps.hasTools, isFalse);
      expect(caps.serverName, isNull);
      expect(caps.protocolVersion, '2025-03-26');
    });

    test('result 非对象 → 协议违规抛（唯一硬失败面）', () {
      expect(() => _caps('oops'), throwsA(isA<McpProtocolException>()));
      expect(() => _caps(null), throwsA(isA<McpProtocolException>()));
    });

    test('progress 不参与 Tier 判定（per-request opt-in，§3.9）', () {
      final caps = _caps({
        'protocolVersion': '2025-06-18',
        'capabilities': {'tools': {}, 'prompts': {}, 'resources': {}},
      });
      // capabilities 里本就没有 progress 字段——有无都不影响 isTier1
      expect(caps.isTier1, isTrue);
    });
  });

  group('buildStaticSummary（C-4）', () {
    test('前 3 工具拼接 + 「自动生成」标注', () {
      final s = buildStaticSummary([
        (name: 'a', description: '工具 A'),
        (name: 'b', description: '工具 B'),
        (name: 'c', description: '工具 C'),
        (name: 'd', description: '不该出现'),
      ]);
      expect(s, startsWith('（自动生成）'));
      expect(s, contains('a: 工具 A'));
      expect(s, contains('c: 工具 C'));
      expect(s.contains('d'), isFalse, reason: 'take(3) 之外不进摘要');
    });

    test('超 500 字符硬封顶 + 省略号', () {
      final s = buildStaticSummary([
        (name: 'big', description: '长' * 900),
      ]);
      expect(s.length, lessThanOrEqualTo(kStaticSummaryBudget + '（自动生成）'.length + 1));
      expect(s.endsWith('…'), isTrue);
    });

    test('工具数 <3 与空列表不越界；空描述回退占位', () {
      expect(buildStaticSummary([]), '（自动生成）');
      final one = buildStaticSummary([(name: 'solo', description: '')]);
      expect(one, contains('solo: （无描述）'));
    });
  });

  group('McpClient.negotiate', () {
    test('握手序列：initialize 请求（协议版本+clientInfo）→ initialized 通知 → 缓存幂等', () async {
      var initializeCalls = 0;
      var notifyCalls = 0;
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          final body = req.body;
          if (body.contains('"method":"initialize"')) {
            initializeCalls++;
            expect(body, contains('"protocolVersion":"$kMcpProtocolVersion"'));
            expect(body, contains('"clientInfo"'));
            expect(body, contains('goodhub'));
            return _ok({
              'protocolVersion': '2025-06-18',
              'capabilities': {'tools': {}, 'prompts': {}, 'resources': {}},
              'serverInfo': {'name': 'goodshare', 'version': '1.0.0'},
            });
          }
          if (body.contains('"method":"notifications/initialized"')) {
            notifyCalls++;
            expect(body.contains('"id"'), isFalse, reason: '通知无 id');
            return http.Response('', 202);
          }
          fail('意外请求: $body');
        }),
      );
      final caps1 = await client.negotiate();
      expect(caps1.isTier1, isTrue);
      final caps2 = await client.negotiate();
      expect(identical(caps1, caps2), isTrue, reason: '同实例协商结果缓存复用');
      expect(initializeCalls, 1, reason: '幂等：重复 negotiate 不重发握手');
      expect(notifyCalls, 1);
    });

    test('DEGRADE：initialized 通知失败不阻断握手（降级为无通知连接）', () async {
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          if (req.body.contains('"method":"initialize"')) {
            return _ok({
              'protocolVersion': '2025-06-18',
              'capabilities': {'tools': {}},
              'serverInfo': {'name': 'vanilla', 'version': '0.1'},
            });
          }
          return http.Response('nope', 500); // 通知被拒
        }),
      );
      final caps = await client.negotiate();
      expect(caps.isTier2, isTrue, reason: '通知失败仅留痕，capabilities 照常返回');
    });

    test('协商失败（连不上）→ 抛出且缓存置空允许重试（区别于缺能力 Polyfill）', () async {
      var initializeCalls = 0;
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          if (req.body.contains('"method":"initialize"')) {
            initializeCalls++;
            if (initializeCalls == 1) return http.Response('boom', 500);
            return _ok({
              'protocolVersion': '2025-06-18',
              'capabilities': {'tools': {}},
            });
          }
          return http.Response('', 202); // notifications/initialized
        }),
      );
      await expectLater(client.negotiate(), throwsA(isA<McpNetworkException>()));
      final caps = await client.negotiate(); // 重试成功
      expect(caps.hasTools, isTrue);
      expect(initializeCalls, 2, reason: '首次失败缓存置空 → 重试重新握手');
    });
  });
}
