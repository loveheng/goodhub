/// §S6 主体 × 工具矩阵（网关运行时闸）单测：
/// ① 在集内主体放行且真实触达宿主执行面；② 集外主体协议级拒绝且**不触达**；
/// ③ owner 恒可读；④ 非 host 服务不受主体闸影响；⑤ 错误码独立于环路码。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/actor.dart';
import 'package:goodhub/core/tool_result.dart';
import 'package:goodhub/core/tool_visibility.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/host_transport.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

class _HostTransportHarness implements McpTransport {
  _HostTransportHarness(this.onCall);

  final ToolExecutionResult Function(String name) onCall;
  int calls = 0;

  @override
  Future<TransportResponse> send(String requestBody) async {
    calls++;
    // 最小协议应答（与 mcp_gateway_handler_test 的 _EchoTransport 同口径）。
    final body = requestBody.contains('"tools/call"')
        ? '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}]}}'
        : '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18",'
            '"capabilities":{"tools":{}},"serverInfo":{"name":"host","version":"1"}}}';
    return TransportResponse(statusCode: 200, contentType: 'application/json', body: body);
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: const Stream<String>.empty(),
      );

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('no GET SSE');

  @override
  void close() {}
}

GatewayHandler _handler({
  required Actor actor,
  required List<String> calls,
}) {
  return GatewayHandler(
    faces: {
      kHostServerId: McpToolFace(
        client: McpClient(HostTransport(
          invoker: ({required String name, required String argumentsJson}) {
            calls.add(name);
            return Future.value(const ToolExecutionResult(content: 'host-ok'));
          },
          allowlist: [
            HostExportEntry(
              name: 'get_host_status',
              annotations: <String, Object?>{'readOnlyHint': true},
              visibility: ToolVisibility.shared,
              tags: <String>['core'],
              allowedActors: <Actor>{Actor.owner, Actor.external('gateway')},
            ),
          ],
        )),
        serverId: kHostServerId,
      ),
    },
    actor: actor,
  );
}

void main() {
  test('配对 PC（external:gateway）→ 放行并真实触达宿主执行面', () async {
    final calls = <String>[];
    final h = _handler(actor: Actor.external('gateway'), calls: calls);
    final r = await h.toolsCall(
      name: 'host__get_host_status',
      arguments: const {},
      onProgress: (_) {},
    );
    expect(r.isError, isFalse, reason: r.content);
    expect(calls, isNotEmpty, reason: '放行必须真实触达执行面');
  });

  test('集外主体（external:untrusted）→ 协议级拒绝且不触达执行面', () async {
    final calls = <String>[];
    final h = _handler(actor: Actor.external('untrusted'), calls: calls);
    final r = await h.toolsCall(
      name: 'host__get_host_status',
      arguments: const {},
      onProgress: (_) {},
    );
    expect(r.errorCode, kGatewayActorDeniedCode);
    expect(r.isError, isTrue);
    expect(r.content, contains('external:untrusted'));
    expect(r.content, contains('owner'));
    expect(calls, isEmpty, reason: '拒绝必须发生在转发之前');
  });

  test('owner 恒在集内（宿主本人调用）', () async {
    final calls = <String>[];
    final h = _handler(actor: Actor.owner, calls: calls);
    final r = await h.toolsCall(
      name: 'host__get_host_status',
      arguments: const {},
      onProgress: (_) {},
    );
    expect(r.isError, isFalse);
  });

  test('非 host 服务不受主体闸影响（矩阵只辖导出面）', () async {
    final calls = <String>[];
    final transport = _HostTransportHarness((name) {
      calls.add(name);
      return const ToolExecutionResult(content: 'ok');
    });
    final h = GatewayHandler(
      faces: {
        's1': McpToolFace(client: McpClient(transport), serverId: 's1'),
      },
      actor: const Actor.external('untrusted'),
    );
    final r = await h.toolsCall(
      name: 's1__echo',
      arguments: const {},
      onProgress: (_) {},
    );
    expect(r.errorCode, isNull, reason: '远端服务的主体裁决属其自身域，网关不代裁');
  });
}
