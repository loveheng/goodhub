import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/mcp/elicitation.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// 回显 id 的假传输：按 method 路由，返回单 JSON 响应帧（mirror 真实 HTTP 单 JSON 回退）。
class IdEchoTransport implements McpTransport {
  IdEchoTransport(this.onRequest);
  final Map<String, Object?> Function(String method, Map<String, Object?> params, dynamic id)
      onRequest;
  final StreamController<String> _getCtl = StreamController<String>.broadcast();

  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody);
    final id = req['id'];
    final method = req['method'] as String;
    final params =
        req['params'] is Map ? req['params'] as Map<String, Object?> : <String, Object?>{};
    final result = onRequest(method, params, id);
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final resp = await send(requestBody);
    return StreamedTransportResponse(
      statusCode: resp.statusCode,
      contentType: resp.contentType,
      lines: Stream.value(resp.body),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() async => StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: _getCtl.stream,
      );

  @override
  Future<void> close() async {}
}

Map<String, Object?> _standardRouter(
  String method,
  Map<String, Object?> params,
  dynamic id,
) {
  if (method == 'initialize') {
    return {
      'protocolVersion': '2025-06-18',
      'capabilities': <String, Object?>{},
      'serverInfo': {'name': 'fake', 'version': '1.0'},
    };
  }
  return <String, Object?>{};
}

void main() {
  group('分页 nextCursor', () {
    test('listResources 循环翻页直到无 nextCursor', () async {
      var calls = 0;
      final client = McpClient(
        IdEchoTransport((method, params, id) {
          if (method == 'resources/list') calls++;
          if (method == 'resources/list') {
            return params['cursor'] == null
                ? {
                    'resources': [
                      {'uri': 'a'}
                    ],
                    'nextCursor': 'c1'
                  }
                : {
                    'resources': [
                      {'uri': 'b'}
                    ]
                  };
          }
          return _standardRouter(method, params, id);
        }),
      );
      await client.negotiate();
      final resources = await client.listResources();
      expect(calls, 2); // 首轮 + 翻页一轮
      expect(resources, hasLength(2));
      expect(resources[0]['uri'], 'a');
      expect(resources[1]['uri'], 'b');
    });

    test('server 不支持分页时单次全量返回（向后兼容）', () async {
      var calls = 0;
      final client = McpClient(
        IdEchoTransport((method, params, id) {
          if (method == 'prompts/list') calls++;
          if (method == 'prompts/list') {
            return {
              'prompts': [
                {'name': 'p1'},
                {'name': 'p2'}
              ]
            };
          }
          return _standardRouter(method, params, id);
        }),
      );
      await client.negotiate();
      final prompts = await client.listPrompts();
      expect(calls, 1);
      expect(prompts, hasLength(2));
    });

    test('listTools 走分页并提取 tools 数组', () async {
      var calls = 0;
      final client = McpClient(
        IdEchoTransport((method, params, id) {
          if (method == 'tools/list') calls++;
          if (method == 'tools/list') {
            return params['cursor'] == null
                ? {
                    'tools': [
                      {'name': 't1'}
                    ],
                    'nextCursor': 'c1'
                  }
                : {
                    'tools': [
                      {'name': 't2'}
                    ]
                  };
          }
          return _standardRouter(method, params, id);
        }),
      );
      await client.negotiate();
      final tools = await client.listTools();
      expect(calls, 2);
      expect(tools, hasLength(2));
      expect(tools[1]['name'], 't2');
    });
  });

  group('elicitation 模型', () {
    test('fromParams 解析 message + schema 字段', () {
      final req = ElicitationRequest.fromParams({
        'message': '补充参数？',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'title': '名称'},
            'age': {'type': 'integer'},
            'ok': {'type': 'boolean'},
            'level': {
              'type': 'string',
              'enum': ['a', 'b']
            },
          },
          'required': ['name'],
        },
      });
      expect(req.message, '补充参数？');
      expect(req.fields, hasLength(4));
      expect(req.required, contains('name'));
      expect(req.fields.first.isBoolean, isFalse);
      expect(req.fields[1].isNumeric, isTrue);
      expect(req.fields[2].isBoolean, isTrue);
      expect(req.fields[3].enumValues, ['a', 'b']);
    });

    test('fromParams 缺字段抛 -32602', () {
      expect(
        () => ElicitationRequest.fromParams({'message': 'x'}),
        throwsA(isA<McpRpcException>()
            .having((e) => e.code, 'code', -32602)),
      );
    });

    test('toResult accept / decline', () {
      expect(
        ElicitationAnswer.accept({'k': 'v'}).toResult(),
        {'action': 'accept', 'content': {'k': 'v'}},
      );
      expect(
        ElicitationAnswer.decline('no').toResult(),
        {'action': 'decline', 'reason': 'no'},
      );
    });

    test('adapter 把 delegate 输出序列化为 result', () async {
      final handler = elicitationRequestHandler(
        delegate: _StubDelegate(
          ElicitationAnswer.accept({'x': 1}),
        ),
      );
      final out = await handler({'message': 'm', 'requestedSchema': {'type': 'object'}});
      expect(out, {'action': 'accept', 'content': {'x': 1}});
    });
  });
}

class _StubDelegate implements ElicitationDelegate {
  _StubDelegate(this._answer);
  final ElicitationAnswer _answer;
  @override
  Future<ElicitationAnswer> request(ElicitationRequest req) async => _answer;
}
