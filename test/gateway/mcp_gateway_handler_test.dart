/// 网关协议处理器（handler）接线单测：前缀解析与未挂载拒绝、**环路阻断**
/// 回协议错误码、`_meta` 出站注入位置与递增、`try/finally` 在成功与失败两条
/// 路径都释放在途记录。
///
/// 传输层用假实现（不触网）：`_EchoTransport` 回单帧 JSON 结果（并记录出站
/// 报文以断言 `_meta`），`_BoomTransport` 抛异常（验证失败路径仍释放）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/gateway/gateway_loop_guard.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

Map<String, Object?> _okFrame(String text) => {
      'jsonrpc': '2.0',
      'id': 1,
      'result': {
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    };

class _EchoTransport implements McpTransport {
  final List<String> sent = [];

  @override
  Future<TransportResponse> send(String requestBody) async {
    sent.add(requestBody);
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode(_okFrame('ok')),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    sent.add(requestBody);
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      lines: Stream<String>.fromIterable([jsonEncode(_okFrame('ok'))]),
    );
  }

  @override
  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('test transport 不支持 GET SSE 订阅通道');

  @override
  void close() {}
}

class _BoomTransport implements McpTransport {
  @override
  Future<TransportResponse> send(String requestBody) async =>
      throw StateError('boom');

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      throw StateError('boom');

  @override
  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('test transport 不支持 GET SSE 订阅通道');

  @override
  void close() {}
}

class _ToolListTransport implements McpTransport {
  _ToolListTransport(this._tools);
  final List<Map<String, Object?>> _tools;

  Map<String, Object?> _resp(Map<String, Object?> req, Object result) => {
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': result,
      };

  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final method = req['method'];
    final result = method == 'tools/list'
        ? {'tools': _tools}
        : {
            'content': [
              {'type': 'text', 'text': 'ok'}
            ]
          };
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode(_resp(req, result)),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final method = req['method'];
    final result = method == 'tools/list'
        ? {'tools': _tools}
        : {
            'content': [
              {'type': 'text', 'text': 'ok'}
            ]
          };
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      lines: Stream<String>.fromIterable([jsonEncode(_resp(req, result))]),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('test transport 不支持 GET SSE 订阅通道');

  @override
  void close() {}
}

Future<McpToolFace> _faceWithTools(List<Map<String, Object?>> tools) async {
  final f = McpToolFace(
    client: McpClient(_ToolListTransport(tools)),
    serverId: 'x',
  );
  await f.listTools();
  return f;
}

/// 假 face（echo 成功路径）：用于跨源 $ref 守卫测试，目标服务任意 serverId。
/// 无需 listTools——[GatewayHandler.toolsCall] 直接走 face.client.callWithProgress，
/// 不依赖 cachedSchemas（_annotationsFor 对空 schema 返回 null 即可）。
McpToolFace _echoFace(String serverId) =>
    McpToolFace(client: McpClient(_EchoTransport()), serverId: serverId);

void main() {
  group('入站校验', () {
    test('工具名缺服务前缀 → isError（非协议错误）', () async {
      final h = GatewayHandler(faces: const {});
      final r = await h.toolsCall(
        name: 'echo',
        arguments: const {},
        onProgress: (_) {},
      );
      expect(r.isError, isTrue);
      expect(r.errorCode, isNull); // 业务级错误，走 result.isError
    });

    test('服务未挂载 → isError', () async {
      final h = GatewayHandler(faces: const {});
      final r = await h.toolsCall(
        name: 'ghost__echo',
        arguments: const {},
        onProgress: (_) {},
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('未挂载'));
    });
  });

  group('环路阻断（接线层）', () {
    test('同 traceId 在途 + hop=1 → 阻断并回 -32000', () async {
      final guard = GatewayLoopGuard();
      final t = _EchoTransport();
      final h = GatewayHandler(
        faces: {'s1': McpToolFace(client: McpClient(t), serverId: 's1')},
        loopGuard: guard,
      );
      guard.acquire('T'); // 模拟父请求在途
      final r = await h.toolsCall(
        name: 's1__echo',
        arguments: const {},
        onProgress: (_) {},
        traceId: 'T',
        hopCount: 1,
      );
      expect(r.errorCode, kGatewayLoopBlockedCode);
      expect(r.content, contains('嵌套回环'));
      expect(t.sent, isEmpty); // 阻断必须发生在转发之前
    });

    test('hop=3 超上限 → 阻断（即便 traceId 未在途）', () async {
      final h = GatewayHandler(faces: const {});
      final r = await h.toolsCall(
        name: 's1__echo',
        arguments: const {},
        onProgress: (_) {},
        traceId: 'T2',
        hopCount: 3,
      );
      expect(r.errorCode, kGatewayLoopBlockedCode);
      expect(r.content, contains('超过上限'));
    });
  });

  group('成功路径与出站注入', () {
    test('剥前缀转发 + `_meta` 与 name/arguments 平级 + hopCount 递增', () async {
      final guard = GatewayLoopGuard();
      final t = _EchoTransport();
      final h = GatewayHandler(
        faces: {'s1': McpToolFace(client: McpClient(t), serverId: 's1')},
        loopGuard: guard,
      );
      final r = await h.toolsCall(
        name: 's1__echo',
        arguments: const {'a': 1},
        onProgress: (_) {},
        traceId: 'T1',
        hopCount: 1,
      );
      expect(r.isError, isFalse);
      expect(r.content, 'ok');

      final sent = jsonDecode(t.sent.single) as Map<String, Object?>;
      final params = sent['params'] as Map<String, Object?>;
      expect(params['name'], 'echo'); // 前缀已剥（server 侧零感知）
      expect(params['arguments'], {'a': 1});
      // 严禁塞进 arguments：强校验插件会报 unknown parameter
      expect((params['arguments'] as Map).containsKey('_meta'), isFalse);
      final meta = params['_meta'] as Map<String, Object?>;
      expect(meta['traceId'], 'T1');
      expect(meta['hopCount'], 2); // 入站 1 → 出站 2
      expect(guard.inFlightCount, 0); // finally 释放
    });

    test('入站未带 traceId → 网关自派并照常注入', () async {
      final t = _EchoTransport();
      final h = GatewayHandler(
        faces: {'s1': McpToolFace(client: McpClient(t), serverId: 's1')},
      );
      await h.toolsCall(
        name: 's1__echo',
        arguments: const {},
        onProgress: (_) {},
      );
      final params =
          (jsonDecode(t.sent.single) as Map<String, Object?>)['params']
              as Map<String, Object?>;
      final meta = params['_meta'] as Map<String, Object?>;
      expect((meta['traceId'] as String).startsWith('gw-'), isTrue);
      expect(meta['hopCount'], 1);
    });
  });

  group('失败路径的释放', () {
    test('下游抛异常 → isError 且在途记录仍被释放（防假死封锁）', () async {
      final guard = GatewayLoopGuard();
      final h = GatewayHandler(
        faces: {
          's1': McpToolFace(client: McpClient(_BoomTransport()), serverId: 's1')
        },
        loopGuard: guard,
      );
      final r = await h.toolsCall(
        name: 's1__echo',
        arguments: const {},
        onProgress: (_) {},
        traceId: 'T3',
      );
      expect(r.isError, isTrue);
      expect(guard.inFlightCount, 0); // 异常路径也必须释放
    });
  });

  group('MO6 阶段一：PC 只读镜像投影', () {
    test('toolsList 仅投影 public + 激活 private，其余私有隐藏', () async {
      final pub = await _faceWithTools([
        {'name': 'pub_tool', 'description': '', 'inputSchema': {}}
      ]);
      final privA = await _faceWithTools([
        {'name': 'a_tool', 'description': '', 'inputSchema': {}}
      ]);
      final privB = await _faceWithTools([
        {'name': 'b_tool', 'description': '', 'inputSchema': {}}
      ]);
      final h = GatewayHandler(
        faces: {'pub': pub, 'privA': privA, 'privB': privB},
        privateServerIds: {'privA', 'privB'},
        activePrivateServerId: 'privA',
      );
      final names = h.toolsList().map((e) => e['name']).toList();
      expect(names, contains('pub__pub_tool'));
      expect(names, contains('privA__a_tool'));
      expect(names, isNot(contains('privB__b_tool'))); // 非激活私有被隐藏
    });

    test('privateServerIds 为空 → 全量投影（向后兼容无私有门控）', () async {
      final a = await _faceWithTools([
        {'name': 'a_tool', 'description': '', 'inputSchema': {}}
      ]);
      final b = await _faceWithTools([
        {'name': 'b_tool', 'description': '', 'inputSchema': {}}
      ]);
      final h = GatewayHandler(faces: {'a': a, 'b': b});
      final names = h.toolsList().map((e) => e['name']).toList();
      expect(names, contains('a__a_tool'));
      expect(names, contains('b__b_tool'));
    });

    test('调用非激活私有服务 → 防火墙拒绝（禁 use_server 换绑）', () async {
      final privA = await _faceWithTools([
        {'name': 'a_tool', 'description': '', 'inputSchema': {}}
      ]);
      final privB = await _faceWithTools([
        {'name': 'b_tool', 'description': '', 'inputSchema': {}}
      ]);
      final h = GatewayHandler(
        faces: {'privA': privA, 'privB': privB},
        privateServerIds: {'privA', 'privB'},
        activePrivateServerId: 'privA',
      );
      final r = await h.toolsCall(
        name: 'privB__b_tool',
        arguments: const {},
        onProgress: (_) {},
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('只读镜像'));
    });

    test('调用激活私有服务 → 放行', () async {
      final privA = await _faceWithTools([
        {'name': 'a_tool', 'description': '', 'inputSchema': {}}
      ]);
      final h = GatewayHandler(
        faces: {'privA': privA},
        privateServerIds: {'privA'},
        activePrivateServerId: 'privA',
      );
      final r = await h.toolsCall(
        name: 'privA__a_tool',
        arguments: const {},
        onProgress: (_) {},
      );
      expect(r.isError, isFalse);
      expect(r.content, 'ok');
    });
  });

  group('MO7 跨源 \$ref 防火墙（仅网关入站/跨源边界）', () {
    test('跨源 \$ref（指向 privA）无会话 → 拒绝', () async {
      final pub = _echoFace('pub');
      final h = GatewayHandler(faces: {'pub': pub});
      final r = await h.toolsCall(
        name: 'pub__echo',
        arguments: {'ref': r'$ref:privA:abc'},
        onProgress: (_) {},
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('跨服务'));
      expect(r.content, contains('会话'));
    });

    test('跨源 \$ref 携带有效会话 → 放行', () async {
      final pub = _echoFace('pub');
      final h = GatewayHandler(faces: {'pub': pub});
      final r = await h.toolsCall(
        name: 'pub__echo',
        arguments: {'ref': r'$ref:privA:abc'},
        onProgress: (_) {},
        sessionId: 'gw-session-1',
      );
      expect(r.isError, isFalse);
      expect(r.content, 'ok');
    });

    test('同源 \$ref（指向目标服务自身）无会话 → 不触发跨源守卫', () async {
      final pub = _echoFace('pub');
      final h = GatewayHandler(faces: {'pub': pub});
      final r = await h.toolsCall(
        name: 'pub__echo',
        arguments: {'ref': r'$ref:pub:abc'},
        onProgress: (_) {},
      );
      expect(r.isError, isFalse);
      expect(r.content, 'ok');
    });

    test('嵌套结构中的跨源 \$ref → 仍被检出并拒绝（无会话）', () async {
      final pub = _echoFace('pub');
      final h = GatewayHandler(faces: {'pub': pub});
      final r = await h.toolsCall(
        name: 'pub__echo',
        arguments: {
          'list': [r'$ref:privA:xyz'],
          'nested': {'deep': r'$ref:privA:zzz'},
        },
        onProgress: (_) {},
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('跨服务'));
    });
  });
}
