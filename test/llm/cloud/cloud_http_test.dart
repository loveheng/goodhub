/// `lib/llm/cloud/cloud_http.dart` 单测：SSE 传输层错误契约。
///
/// 回归背景（2026-10-21 真机实测，SiliconFlow「Connection closed while
/// receiving data」）：对端在**响应体读到一半**时关闭连接，package:http 把
/// dart:io 的 HttpException 包装成 ClientException 从**响应流**抛出
/// （io_client.dart stream onError 分支，非 send 时抛出）——发送处的 try
/// 捕不到，旧行为裸异常穿透 HybridCloudEngine → agent_loop → 炸整轮会话。
/// 本组钉子「流内异常 → CloudNetworkException」映射（撤修复即红）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/cloud_llm_error.dart';
import 'package:goodhub/llm/cloud/cloud_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  http.Client clientReturning(Stream<List<int>> body, int status) =>
      MockClient.streaming((_, _) async => http.StreamedResponse(
            body,
            status,
            headers: const {'content-type': 'text/event-stream'},
          ));

  const url = 'https://api.example.com/v1/chat/completions';

  test('正常 SSE 流：事件逐帧产出 + onActivity 透传', () async {
    var activity = 0;
    final events = await sendSseRequest(
      client: clientReturning(
        Stream.fromIterable([
          utf8.encode('data: {"a":1}\n\n'),
          utf8.encode('data: {"b":2}\n\n'),
        ]),
        200,
      ),
      url: url,
      headers: const {},
      body: const {},
      onActivity: () => activity++,
    ).toList();
    expect(events.map((e) => e.data), ['{"a":1}', '{"b":2}']);
    expect(activity, greaterThan(0));
  });

  test('流内 ClientException（响应读到一半被对端关闭）→ CloudNetworkException', () async {
    // 真机实证文案（SiliconFlow）：uri 指向 LLM 提供商而非本地服务——
    // 证明 Binder 会话里的 HTTP 暴露面只剩云端引擎 SSE 流。
    Stream<List<int>> body() async* {
      yield utf8.encode('data: {"a":1}\n\n');
      throw http.ClientException(
        'Connection closed while receiving data, '
        'uri=https://api.siliconflow.cn/v1/chat/completions',
      );
    }

    final events = sendSseRequest(
      client: clientReturning(body(), 200),
      url: url,
      headers: const {},
      body: const {},
    );
    await expectLater(
      events.toList(),
      throwsA(isA<CloudNetworkException>()
          .having((e) => e.message, 'message', contains('Connection closed'))),
    );
  });

  test('流内截断 UTF-8（连接中途关闭致 FormatException）→ CloudNetworkException', () async {
    // 「好」= E5 A5 BD 三字节序列，只送前两字节后关流——
    // utf8.decoder 流末遇不完整序列抛 FormatException（旧行为同样裸奔）。
    final truncated = <int>[
      ...utf8.encode('data: {"text":"'),
      ...utf8.encode('好').sublist(0, 2),
    ];
    final events = sendSseRequest(
      client: clientReturning(Stream.fromIterable([truncated]), 200),
      url: url,
      headers: const {},
      body: const {},
    );
    await expectLater(
      events.toList(),
      throwsA(isA<CloudNetworkException>()),
    );
  });

  test('非 2xx → CloudHttpException 且带 statusCode（T2 降级计数依据）', () async {
    final events = sendSseRequest(
      client: clientReturning(
        Stream.fromIterable([utf8.encode('{"error":{"message":"quota"}}')]),
        429,
      ),
      url: url,
      headers: const {},
      body: const {},
    );
    await expectLater(
      events.toList(),
      throwsA(isA<CloudHttpException>()
          .having((e) => e.statusCode, 'statusCode', 429)),
    );
  });
}
