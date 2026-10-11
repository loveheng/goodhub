import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/sandbox/memory_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  /// JSON-RPC 成功响应信封（McpClient 解 envelope 取 result）
  http.Response okJson(Object? result) => http.Response(
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
        200,
        headers: {'content-type': 'application/json'},
      );

  McpClient client(Future<http.Response> Function(http.BaseRequest req) handler) =>
      McpClient(baseUrl: 'http://10.0.0.5:8765/mcp', httpClient: MockClient(handler));

  group('listTools', () {
    test('tools/list → CloudToolSchema（缺省字段防御）', () async {
      http.BaseRequest? captured;
      final face = McpToolFace(
        client: client((req) async {
          captured = req;
          return okJson({
            'tools': [
              {
                'name': 'claim_ai_task',
                'description': '认领任务',
                'inputSchema': {'type': 'object'},
              },
              {'name': 'bare_tool'},
            ],
          });
        }),
      );
      final tools = await face.listTools();
      expect(captured!.url.path, '/mcp');
      expect(tools, hasLength(2));
      expect(tools.first.name, 'claim_ai_task');
      expect(tools.first.parametersSchema, {'type': 'object'});
      expect(tools.last.parametersSchema, isEmpty);
      expect(tools.last.description, isEmpty);
    });

    test('形状违规 → McpProtocolException', () async {
      final face = McpToolFace(
        client: client((req) async => okJson({'tools': [{}]})),
      );
      await expectLater(
        face.listTools(),
        throwsA(isA<McpProtocolException>()),
      );
    });
  });

  group('execute', () {
    test('tools/call 信封 + content 扁平拼接', () async {
      Object? capturedParams;
      final face = McpToolFace(
        client: client((req) async {
          capturedParams = jsonDecode((req as http.Request).body)['params'];
          return okJson({
            'content': [
              {'type': 'text', 'text': 'a'},
              {'type': 'text', 'text': 'b'},
            ],
          });
        }),
      );
      final r = await face.execute(
        const AssembledToolCall(id: 'c1', name: 'f', argumentsJson: '{"x":1}'),
      );
      expect(r.isError, isFalse);
      expect(r.content, 'a\nb');
      expect((capturedParams! as Map)['name'], 'f');
      expect((capturedParams! as Map)['arguments'], {'x': 1});
    });

    test('isError 标记透传', () async {
      final face = McpToolFace(
        client: client((req) async => okJson({
              'content': [
                {'type': 'text', 'text': 'x'}
              ],
              'isError': true,
            })),
      );
      final r = await face.execute(
        const AssembledToolCall(id: 'c', name: 'f', argumentsJson: '{}'),
      );
      expect(r.isError, isTrue);
    });

    test('JSON-RPC error → isError 结果（回填模型自纠）', () async {
      final face = McpToolFace(
        client: client((req) async => http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'error': {'code': -32000, 'message': 'version_conflict'},
              }),
              200,
            )),
      );
      final r = await face.execute(
        const AssembledToolCall(id: 'c', name: 'f', argumentsJson: '{}'),
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('version_conflict'));
    });

    test('入参 JSON 损坏 → isError 结果（不抛，回填模型自纠）', () async {
      final face = McpToolFace(
        client: client((req) async => okJson({})),
      );
      final r = await face.execute(
        const AssembledToolCall(id: 'c', name: 'f', argumentsJson: '{bad'),
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('JSON 损坏'));
    });
  });

  group('M3-T2：cancel 与 requestId', () {
    http.Response sseOk(Object result) => http.Response(
          'data: ${jsonEncode({
            'jsonrpc': '2.0',
            'method': 'notifications/progress',
            'params': {'progressToken': 1, 'progress': 0, 'total': 1},
          })}\n\n'
          'data: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': result,
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );

    McpClient streamingClient(List<String> bodies, {String? apiKey}) => McpClient(
          baseUrl: 'http://10.0.0.5:8765/mcp',
          apiKey: apiKey,
          httpClient: MockClient((req) async {
            bodies.add(req.body);
            if (apiKey != null) bodies.add('HEADER x-api-key=${req.headers['x-api-key']}');
            if (req.body.contains('"method":"initialize"')) {
              return okJson({
                'protocolVersion': '2025-06-18',
                'capabilities': {'tools': {}, 'sampling': {}},
              });
            }
            if (req.body.contains('notifications/')) {
              return http.Response('', 202); // initialized / cancelled 通知
            }
            return sseOk({
              'content': [
                {'type': 'text', 'text': 'done'},
              ],
              'isError': false,
            });
          }),
        );

    test('在途时 cancelActiveRequest 下发 notifications/cancelled（id 对齐 tools/call）', () async {
      final bodies = <String>[];
      late final McpToolFace face;
      face = McpToolFace(
        client: streamingClient(bodies, apiKey: 'k-test'),
        onProgress: (tool, progress, total, message) {
          face.cancelActiveRequest(reason: 'user abort'); // 流中触发——请求确在途
        },
      );
      final r = await face.execute(
        const AssembledToolCall(id: 'c1', name: 'f', argumentsJson: '{}'),
      );
      expect(r.isError, isFalse);
      await pumpEventQueue(); // cancel notify 为 unawaited 异步——断言前泵空队列
      final callId =
          RegExp(r'"id":(\d+)').firstMatch(bodies.firstWhere((b) => b.contains('tools/call')))!.group(1);
      final cancelBody = bodies.singleWhere((b) => b.contains('notifications/cancelled'));
      expect(cancelBody, contains('"requestId":$callId'),
          reason: '取消目标 = 在途 tools/call 的 JSON-RPC id');
      expect(cancelBody, contains('"reason":"user abort"'));
      expect(bodies, contains('HEADER x-api-key=k-test'),
          reason: 'notify 鉴权头修复（M3-T2）——cancelled 与 initialized 同路带鉴权');
    });

    test('结束后 cancelActiveRequest 为 no-op（id 已清，无 cancelled POST）', () async {
      final bodies = <String>[];
      final face = McpToolFace(client: streamingClient(bodies));
      await face.execute(
        const AssembledToolCall(id: 'c1', name: 'f', argumentsJson: '{}'),
      );
      final cancelsBefore = bodies.where((b) => b.contains('notifications/cancelled')).length;
      face.cancelActiveRequest(reason: 'late');
      expect(cancelsBefore, 0);
      expect(bodies.where((b) => b.contains('notifications/cancelled')), isEmpty,
          reason: '无在途请求不发包');
    });
  });
}
