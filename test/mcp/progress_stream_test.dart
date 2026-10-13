/// M2.5-T7 Progress SSE 帧流收侧单测：callWithProgress 流式分帧解析 +
/// McpToolFace onProgress 通道 + resources 封装。
/// C-1 缓冲黑洞的收侧兑现钉子：progress 帧即达即回调（不等响应结束）。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _sse(String body) => http.Response(body, 200,
    headers: {'content-type': 'text/event-stream; charset=utf-8'});

http.Response _json(Object result) => http.Response(
      '{"jsonrpc":"2.0","id":1,"result":${json.jsonEncode(result)}}',
      200,
      headers: {'content-type': 'application/json'},
    );

/// SSE 帧序构造：心跳 comment + 两条 progress + 终帧。
String _sseBody({
  required String resultJson,
  int progressCount = 1,
  bool withHeartbeat = true,
  bool keepaliveFirst = true,
}) {
  final b = StringBuffer();
  if (withHeartbeat && keepaliveFirst) b.write(': keep-alive\n\n');
  for (var i = 0; i < progressCount; i++) {
    b.write('data: ${json.jsonEncode({
          'jsonrpc': '2.0',
          'method': 'notifications/progress',
          'params': {'progressToken': 1, 'progress': i, 'total': 10, 'message': 'step $i'},
        })}\n\n');
  }
  if (withHeartbeat && !keepaliveFirst) b.write(': keep-alive\n\n');
  b.write('data: $resultJson\n\n');
  return b.toString();
}

void main() {
  group('callWithProgress：SSE 分帧解析', () {
    test('progress 帧即达即回调，终帧返回 result，心跳 comment 忽略', () async {
      final progresses = <Object?>[];
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          expect(req.body, contains('"progressToken":1'),
              reason: 'token 自动注入 _meta');
          expect(req.body, contains('"_meta"'));
          return _sse(_sseBody(
            resultJson: json.jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'result': {'content': [], 'isError': false},
            }),
            progressCount: 3,
          ));
        }),
      );
      final result = await client.callWithProgress(
        'tools/call',
        params: {'name': 'slow_tool'},
        onProgress: progresses.add,
      );
      expect(result, isNotNull);
      expect(progresses.length, 3, reason: 'C-1 收侧：progress 帧逐帧回调');
      expect((progresses.first as Map)['progress'], 0);
      expect((progresses.last as Map)['message'], 'step 2');
    });

    test('终帧 error → 抛 McpRpcException', () async {
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((_) async => _sse(_sseBody(
              resultJson:
                  '{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"工具炸了"}}',
            ))),
      );
      await expectLater(
        client.callWithProgress('tools/call',
            params: {'name': 'x'}, onProgress: (_) {}),
        throwsA(isA<McpRpcException>()),
      );
    });

    test('流结束无终帧 → 协议违规抛（server 断流防护）', () async {
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((_) async => _sse(
              'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":0}}\n\n',
            )),
      );
      await expectLater(
        client.callWithProgress('tools/call',
            params: {'name': 'x'}, onProgress: (_) {}),
        throwsA(isA<McpProtocolException>()),
      );
    });

    test('单 JSON 回退：server 忽略 progressToken 回 application/json（Tier 2 兼容）', () async {
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          expect(req.body, contains('"progressToken"'),
              reason: 'client 照常注入 token——server 忽略与否是 server 的事');
          return _json({'content': [], 'isError': false});
        }),
      );
      var progressSeen = false;
      final result = await client.callWithProgress(
        'tools/call',
        params: {'name': 'x'},
        onProgress: (_) => progressSeen = true,
      );
      expect(result, isNotNull);
      expect(progressSeen, isFalse);
    });
  });

  group('McpToolFace progress 通道', () {
    test('onProgress 非 null → 走 callWithProgress，回调解出 progress/total/message', () async {
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((_) async => _sse(_sseBody(
              resultJson: json.jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'result': {
                  'content': [
                    {'type': 'text', 'text': 'done'},
                  ],
                  'isError': false,
                },
              }),
              progressCount: 1,
            ))),
      );
      final seen = <(String, num, num?, String?)>[];
      final face = McpToolFace(
        client: client,
        onProgress: (tool, progress, total, message) =>
            seen.add((tool, progress, total, message)),
      );
      final r = await face.execute(AssembledToolCall(
        id: 'c1',
        name: 'slow_tool',
        argumentsJson: '{}',
      ));
      expect(r.isError, isFalse);
      expect(seen.single.$1, 'slow_tool');
      expect(seen.single.$2, 0);
      expect(seen.single.$3, 10);
      expect(seen.single.$4, 'step 0');
    });

    test('onProgress null → 不注入 progressToken（普通 call）', () async {
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          expect(req.body.contains('"progressToken"'), isFalse,
              reason: '不消费进度就不注入 token——opt-in 语义');
          return _json({'content': [], 'isError': false});
        }),
      );
      final face = McpToolFace(client: client);
      final r = await face.execute(AssembledToolCall(
        id: 'c1',
        name: 'x',
        argumentsJson: '{}',
      ));
      expect(r.isError, isFalse);
    });

    test('M3：server 声明 sampling → onProgress null 也强制走流式（反向请求通道）', () async {
      var sawProgressToken = false;
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          if (req.body.contains('"method":"initialize"')) {
            return _json({
              'protocolVersion': '2025-06-18',
              'capabilities': {
                'tools': {},
                'sampling': {},
              },
            });
          }
          if (req.body.contains('notifications/initialized')) {
            return http.Response('', 202);
          }
          sawProgressToken = req.body.contains('"progressToken"');
          return _sse(_sseBody(
            resultJson: json.jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'result': {'content': [], 'isError': false},
            }),
            progressCount: 0,
          ));
        }),
      );
      final face = McpToolFace(client: client);
      final r = await face.execute(AssembledToolCall(
        id: 'c1',
        name: 'ai_suggest_tags',
        argumentsJson: '{"id":"abc"}',
      ));
      expect(r.isError, isFalse);
      expect(sawProgressToken, isTrue,
          reason: 'sampling 反向请求须有帧间夹带通道——声明即流式');
    });
  });

  group('M3：server→client 反向请求分派（ai-app-split.md §3.11）', () {
    http.Response askSse() => _sse(
          'data: ${json.jsonEncode({
            'jsonrpc': '2.0',
            'id': 'srv_1',
            'method': 'sampling/createMessage',
            'params': {
              'messages': [
                {'role': 'user', 'content': {'type': 'text', 'text': '提取标签'}},
              ],
              'maxTokens': 256,
            },
          })}\n\n'
          'data: ${json.jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {'content': [], 'isError': false},
          })}\n\n',
        );

    test('分派 onServerRequest 并按 id POST 回程 result，流继续读终帧', () async {
      final answers = <Map<String, Object?>>[];
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          if (req.body.contains('"id":"srv_1"')) {
            answers.add(json.jsonDecode(req.body) as Map<String, Object?>);
            return http.Response('', 202);
          }
          return askSse();
        }),
      );
      client.onServerRequest = (method, params) async {
        expect(method, 'sampling/createMessage');
        return {
          'role': 'assistant',
          'model': 'fake',
          'content': {'type': 'text', 'text': '["标签"]'},
        };
      };
      final result = await client.callWithProgress(
        'tools/call',
        params: {'name': 'ai_suggest_tags'},
        onProgress: (_) {},
      );
      expect(result, isNotNull, reason: '反向请求回程后流继续读到终帧');
      expect(answers.single['id'], 'srv_1');
      expect((answers.single['result'] as Map)['model'], 'fake');
    });

    test('handler 抛 McpRpcException → error 帧原样回程（配额结构化拒绝）', () async {
      final answers = <Map<String, Object?>>[];
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          if (req.body.contains('"id":"srv_1"')) {
            answers.add(json.jsonDecode(req.body) as Map<String, Object?>);
            return http.Response('', 202);
          }
          return askSse();
        }),
      );
      client.onServerRequest = (method, params) async {
        throw const McpRpcException(-32000, 'sampling 配额超限', data: {'hint': 'retry after 30s'});
      };
      final result = await client.callWithProgress(
        'tools/call',
        params: {'name': 'ai_suggest_tags'},
        onProgress: (_) {},
      );
      expect(result, isNotNull);
      final err = answers.single['error'] as Map;
      expect(err['code'], -32000);
      expect((err['data'] as Map)['hint'], contains('30s'));
    });

    test('handler 缺失 → -32601 error 帧回程，server 不悬挂', () async {
      final answers = <Map<String, Object?>>[];
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          if (req.body.contains('"id":"srv_1"')) {
            answers.add(json.jsonDecode(req.body) as Map<String, Object?>);
            return http.Response('', 202);
          }
          return askSse();
        }),
      );
      final result = await client.callWithProgress(
        'tools/call',
        params: {'name': 'ai_suggest_tags'},
        onProgress: (_) {},
      );
      expect(result, isNotNull);
      expect((answers.single['error'] as Map)['code'], -32601);
    });
  });

  group('resources 封装', () {
    test('listResources 防御解析 + readResource 取首 text 块', () async {
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((req) async {
          if (req.body.contains('resources/list')) {
            return _json({
              'resources': [
                {'uri': 'goodshare://items/abc', 'name': '条目', 'mimeType': 'text/plain'},
                '非对象条目会被滤掉',
              ],
            });
          }
          return _json({
            'contents': [
              {'uri': 'goodshare://items/abc', 'mimeType': 'text/plain', 'text': '正文'},
            ],
          });
        }),
      );
      final list = await client.listResources();
      expect(list.single['uri'], 'goodshare://items/abc');
      expect(await client.readResource('goodshare://items/abc'), '正文');
    });

    test('resources/read contents 缺失/无 text → 协议违规抛', () async {
      final client = McpClient.http(
        baseUrl: 'http://127.0.0.1:8765/mcp',
        httpClient: MockClient((_) async => _json({'contents': []})),
      );
      await expectLater(
        client.readResource('goodshare://items/abc'),
        throwsA(isA<McpProtocolException>()),
      );
    });
  });
}
