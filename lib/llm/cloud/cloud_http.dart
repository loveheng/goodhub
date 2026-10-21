/// 云端协议客户端共享接线：HTTP-SSE 传输 + 共享 JSON 解析（M2-T1）。
/// 协议语义（OpenAI/Anthropic 线格式）各住自己的 client 文件，
/// 本文件只做传输层（coding-standards §1.2 边界纪律的 llm 侧同构）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../../core/errors/cloud_llm_error.dart';
import 'sse_parser.dart';

/// POST JSON → SSE 事件流。懒执行：返回流被监听时才发起请求。
///
/// - 连接超时（[connectTimeout]，超时或连接失败）→ [CloudNetworkException]；
/// - 非 2xx → 读错误体（截 500 字符）抛 [CloudHttpException]，
///   T2 降级控制器据 statusCode 计「连续 2 次 5xx/429」（architecture §2）；
/// - 2xx → 响应体 UTF-8 解码后经 [parseSse] 产出事件流。
Stream<SseEvent> sendSseRequest({
  required http.Client client,
  required String url,
  required Map<String, String> headers,
  required Map<String, Object?> body,
  Duration connectTimeout = const Duration(seconds: 10),
  void Function()? onActivity,
}) async* {
  final req = http.Request('POST', Uri.parse(url))
    ..headers.addAll(headers)
    ..headers['Content-Type'] = 'application/json'
    ..headers['Accept'] = 'text/event-stream'
    ..body = jsonEncode(body);
  final http.StreamedResponse resp;
  try {
    resp = await client.send(req).timeout(
          connectTimeout,
          onTimeout: () => throw const CloudNetworkException('云端连接超时'),
        );
  } on CloudLlmException {
    rethrow;
  } on Exception catch (e) {
    throw CloudNetworkException('云端连接失败: $e');
  }
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    final errorBody = await resp.stream.bytesToString();
    throw CloudHttpException(
      '云端 HTTP ${resp.statusCode}: ${_clip(errorBody)}',
      statusCode: resp.statusCode,
    );
  }
  // 流式消费段包错（2026-10-21 真机实测教训）：对端在**响应体读到一半**时
  // 关闭连接（SiliconFlow 实证 `Connection closed while receiving data`）——
  // dart:io 的 HttpException 经 package:http 包装成 ClientException 从
  // **响应流**抛出（io_client.dart stream onError 分支，非 send 时抛出，
  // 故发送处的 try 捕不到）；utf8 解码遇截断多字节序列另抛 FormatException。
  // 三类统一收口为 CloudNetworkException，让上层既有分支接管（降级判据 /
  // 端侧兜底 / 白话错误卡「连不上推理服务」）——严禁裸异常穿透炸整轮会话。
  // 注：必须显式 `await for` 而非 `yield*`——后者把内层流的错误事件直接
  // 转发给消费者，不在生成器体内抛出，外围 try 捕不到（实测证实）。
  try {
    await for (final e
        in parseSse(resp.stream.transform(utf8.decoder), onActivity: onActivity)) {
      yield e;
    }
  } on http.ClientException catch (e) {
    throw CloudNetworkException(
        '云端流连接中断（响应接收中被对端关闭）: ${e.message}');
  } on SocketException catch (e) {
    throw CloudNetworkException('云端流连接中断: $e');
  } on FormatException catch (e) {
    throw CloudNetworkException('云端流数据不完整（连接在响应中途关闭）: ${e.message}');
  }
}

/// SSE data / 工具入参等 JSON 文本 → object；形状违规抛
/// [CloudProtocolException]（契约违规立即暴露，禁猜测性兜底）。
Map<String, Object?> decodeJsonObject(String data, String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(data);
  } on FormatException catch (e) {
    throw CloudProtocolException('$source 非 JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw CloudProtocolException('$source 非 JSON object');
  }
  return decoded.cast<String, Object?>();
}

String _clip(String s) => s.length <= 500 ? s : '${s.substring(0, 500)}…';
