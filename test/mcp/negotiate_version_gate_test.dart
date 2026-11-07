import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_capabilities.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// S1a（extensibility-hardening，架构债 #28）：negotiate 协议版本闸——
/// server 回显异版本 = 标准 MCP 客户端协商语义下拒装（fail-closed），禁静默
/// 按旧版本硬连；不回显（parse 缺字段回退宿主版本）的存量保守 server 不拦。
class _RouterTransport implements McpTransport {
  _RouterTransport(this.result);
  final Object? result;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': req['id'], 'result': result}),
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
  Future<StreamedTransportResponse> getStream() async =>
      StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: const Stream.empty(),
      );

  @override
  void close() {}
}

Map<String, Object?> _caps() => {'tools': <String, Object?>{}};

void main() {
  test('server 回显同版本 → 协商通过', () async {
    final client = McpClient(_RouterTransport({
      'protocolVersion': kMcpProtocolVersion,
      'capabilities': _caps(),
    }));
    final caps = await client.negotiate();
    expect(caps.protocolVersion, kMcpProtocolVersion);
    client.close();
  });

  test('server 回显异版本 → McpProtocolException 拒装（消息含双版本）', () async {
    final client = McpClient(_RouterTransport({
      'protocolVersion': '2025-01-01',
      'capabilities': _caps(),
    }));
    await expectLater(
      client.negotiate(),
      throwsA(isA<McpProtocolException>().having(
          (e) => e.message, 'message', allOf(
        contains('2025-01-01'),
        contains(kMcpProtocolVersion),
      ))),
    );
    client.close();
  });

  test('server 不回显 protocolVersion → 缺省按宿主版本通过（保守不拦）', () async {
    final client = McpClient(_RouterTransport({'capabilities': _caps()}));
    final caps = await client.negotiate();
    expect(caps.protocolVersion, kMcpProtocolVersion);
    client.close();
  });
}
