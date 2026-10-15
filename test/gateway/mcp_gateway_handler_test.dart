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
}
