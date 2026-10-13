/// 网关入站背压（§9.6）单测：单 server 并发硬上限 4（超限排队）、per-server
/// 隔离（A 满载不阻塞 B）、handler 级穿透验证（6 并发 tools/call 峰值 ≤ 4）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/gateway/gateway_backpressure.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

void main() {
  test('并发硬上限：5 任务 max 2，峰值 = 2 且全部完成', () async {
    final bp = PerServerBackpressure(maxConcurrent: 2);
    var inFlight = 0;
    var peak = 0;
    await Future.wait([
      for (var i = 0; i < 5; i++)
        bp.run('srv', () async {
          inFlight++;
          peak = peak > inFlight ? peak : inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          inFlight--;
          return i;
        }),
    ]);
    expect(peak, 2); // §9.6：超限排队，绝不穿透
  });

  test('per-server 隔离：A 满载不阻塞 B', () async {
    final bp = PerServerBackpressure(maxConcurrent: 1);
    final aReleased = Completer<void>();
    final aDone = bp.run('a', () => aReleased.future);
    // A 占满：a 的第二个任务排队，b 应即时执行。
    final aQueued = bp.run('a', () async => 'a2');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final sw = Stopwatch()..start();
    final b = await bp.run('b', () async => 'b1');
    expect(b, 'b1');
    expect(sw.elapsedMilliseconds < 50, isTrue); // 未被 a 阻塞
    aReleased.complete();
    await aDone;
    expect(await aQueued, 'a2');
  });

  test('handler 级穿透验证：6 并发 tools/call 对同一 server 峰值 ≤ 4', () async {
    final transport = _CountingTransport();
    final face = McpToolFace(client: McpClient(transport), serverId: 'demo');
    await face.listTools();
    final handler = GatewayHandler(faces: {'demo': face});
    await Future.wait([
      for (var i = 0; i < 6; i++)
        handler.toolsCall(
          name: 'demo__echo',
          arguments: {'i': i},
          onProgress: (_) {},
        ),
    ]);
    expect(transport.peakConcurrent, lessThanOrEqualTo(4));
    expect(transport.streamCalls, 6); // 排队者最终全部执行
  });
}

/// 并发计数假传输：sendStream 记录在途峰值（30ms 延迟制造重叠窗口）。
class _CountingTransport implements McpTransport {
  var _inFlight = 0;
  var peakConcurrent = 0;
  var streamCalls = 0; // 仅 sendStream（tools/call 路径）

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
            },
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
    streamCalls++;
    _inFlight++;
    peakConcurrent = peakConcurrent > _inFlight ? peakConcurrent : _inFlight;
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final lines = [
      'data: ${jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': req['id'],
            'result': <String, Object?>{
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': 'ok'},
              ],
            },
          })}',
      '',
    ];
    // 延迟吐流制造并发重叠窗口（等价服务端慢执行）；递减必须放 finally——
    // callWithProgress 消费完终帧即提前 return（取消生成器），yield 之后的
    // 普通尾码不执行，仅 finally 在取消时保证运行。
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'text/event-stream',
      lines: () async* {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          for (final l in lines) {
            yield l;
          }
        } finally {
          _inFlight--;
        }
      }(),
    );
  }

  @override
  void close() {}
}
