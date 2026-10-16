/// window-slim P1-D 释放卫生契约（2026-10-17）：
///
/// 1. close 幂等：McpClient / BinderTransport 二次调用不抛、传输只关一次；
/// 2. 释放通道：TaskLoopService.close 透传到 GoodshareTaskApi 底层 client
///    （此前 buildApi 建的 client 无任何释放路径）；
/// 3. save 串行化：ServerEndpointStore.save 接 keyed 写队列后并发 save 不交错损坏。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/goodshare_task_api.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:goodhub/task/task_inference.dart';
import 'package:goodhub/task/task_loop_service.dart';

/// 计数假传输：close 可观测（协议面最小实现）。
class _CountingTransport implements McpTransport {
  int closeCount = 0;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final method = (jsonDecode(requestBody) as Map)['method'] as String?;
    final Object result = switch (method) {
      'initialize' => {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake', 'version': '1.0'},
        },
      'tools/list' => {
          'tools': [
            {'name': 'claim_ai_task'},
          ],
        },
      _ => <String, Object?>{},
    };
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: const Stream<String>.empty(),
      );

  @override
  Future<StreamedTransportResponse> getStream() async =>
      StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: const Stream<String>.empty(),
      );

  @override
  void close() => closeCount++;
}

void main() {
  group('close 幂等（P1-D）', () {
    test('McpClient.close 二次调用静默返回、transport.close 只计一次', () {
      final transport = _CountingTransport();
      final client = McpClient(transport);
      client.close();
      client.close();
      client.close();
      expect(transport.closeCount, 1);
    });

    test('TaskLoopService.close 透传释放底层 client（二次调用仍只关一次）', () {
      final transport = _CountingTransport();
      final service = TaskLoopService(
        api: GoodshareTaskApi(McpClient(transport)),
        inference: _NoopInference(),
      );
      service.close();
      service.close();
      expect(transport.closeCount, 1);
    });
  });

  group('save 串行化（P1-D）', () {
    test('并发 save 不交错损坏：队列串行后文件恒为合法 JSON 且条目数正确', () async {
      final dir = await Directory.systemTemp.createTemp('ep-store-test');
      addTearDown(() => dir.delete(recursive: true));
      final store = ServerEndpointStore(file: File('${dir.path}/mcp_servers.json'));

      // 12 路并发 save（每路不同条目数）——修复前裸 tmp→rename 交错可能
      // 把 A 写一半的 .tmp rename 成正式文件 → JSON 截断损坏。
      await Future.wait(<Future<void>>[
        for (var i = 1; i <= 12; i++)
          store.save([
            for (var j = 0; j < i; j++)
              ServerEndpoint(
                id: 'ep-$i-$j',
                endpoint: 'http://10.0.0.1:8765/mcp',
                name: 'ep',
              ),
          ]),
      ]);

      final loaded = await store.load();
      // 最终内容 = 最后完成的一次 save（条目数 1..12 之一），且 load 零异常
      // 即证明文件未损坏（修复合约：串行化，不丢文件级更新）。
      expect(loaded.length, inInclusiveRange(1, 12));
      expect(loaded.first.id, startsWith('ep-'));
    });
  });
}

/// 最小推理桩：TaskLoopService 构造必填，本组用例不触发 runOnce。
class _NoopInference implements TaskInference {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
