/// MCP 传输底座抽象（thirdconnect T-trans-1）。
///
/// 纯传输：把一段已编码的 JSON-RPC 请求体送到对端并取回原始响应，**不含**
/// 协议语义（握手/解帧/反向请求回程住在 [McpClient]，见 mcp_client.dart 头注释
/// 的边界纪律）。[HttpTransport] 为远端实现；同机 Binder 实现规划于 T-trans-2/3。
library;

import 'dart:async';
import 'dart:convert' show utf8, LineSplitter;

import 'package:http/http.dart' as http;

import '../../core/errors/mcp_error.dart';

/// 单请求-响应结果（状态码 + content-type + 原始响应体）。
class TransportResponse {
  const TransportResponse({
    required this.statusCode,
    required this.contentType,
    required this.body,
  });

  final int statusCode;
  final String contentType;
  final String body;
}

/// 流式请求结果（状态码 + content-type + 逐行解码流，供 SSE 分帧）。
class StreamedTransportResponse {
  const StreamedTransportResponse({
    required this.statusCode,
    required this.contentType,
    required this.lines,
  });

  final int statusCode;
  final String contentType;
  final Stream<String> lines;
}

/// 纯传输抽象：把请求体送到对端取回响应。状态码/网络异常语义由实现决定
/// （HTTP = 真实状态码；Binder = 成功映射 200、失败映射 4xx），协议层据此裁决。
abstract class McpTransport {
  /// 单请求-响应：发送已编码请求体，返回原始响应。
  Future<TransportResponse> send(String requestBody);

  /// 流式请求（callWithProgress 用）：返回逐行解码流。
  Future<StreamedTransportResponse> sendStream(String requestBody);

  /// 订阅通知下行通道（Streamable HTTP GET SSE）：server 主动帧（如
  /// `notifications/resources/updated`）经独立 GET 长连接推送，与请求-响应通道
  /// 分离（MCP §3.10 / ai-app-split.md §3.10）。Binder 等同机传输无此独立通道
  /// （通知走回程），实现应抛 [UnsupportedError]，由协议层退化为不监听。
  Future<StreamedTransportResponse> getStream();

  void close();
}

/// HTTP 传输实现（Streamable HTTP，无状态逐请求）。
class HttpTransport implements McpTransport {
  HttpTransport({required this.baseUrl, this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// 如 `http://192.168.1.10:8765/mcp`
  final String baseUrl;

  /// X-Api-Key（空则不带鉴权头）。
  final String? apiKey;
  final http.Client _http;

  static const _headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
  };

  Map<String, String> get _requestHeaders => {
        ..._headers,
        if (apiKey != null && apiKey!.isNotEmpty) 'X-Api-Key': apiKey!,
      };

  @override
  Future<TransportResponse> send(String requestBody) async {
    final resp = await _post(requestBody);
    return TransportResponse(
      statusCode: resp.statusCode,
      contentType: resp.headers['content-type'] ?? '',
      body: resp.body,
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final resp = await _sendRaw(http.Request('POST', Uri.parse(baseUrl))
      ..headers.addAll(_requestHeaders)
      ..body = requestBody);
    return StreamedTransportResponse(
      statusCode: resp.statusCode,
      contentType: resp.headers['content-type'] ?? '',
      lines: resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() async {
    final resp = await _sendRaw(http.Request('GET', Uri.parse(baseUrl))
      ..headers.addAll({..._requestHeaders, 'Accept': 'text/event-stream'}));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      await resp.stream.drain<void>();
      throw McpNetworkException('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    return StreamedTransportResponse(
      statusCode: resp.statusCode,
      contentType: resp.headers['content-type'] ?? '',
      lines: resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
  }

  Future<http.Response> _post(String body) async {
    try {
      final resp = await _http.post(Uri.parse(baseUrl),
          headers: _requestHeaders, body: body);
      return resp;
    } on http.ClientException catch (e) {
      throw McpNetworkException('transport failed: ${e.message}');
    } on TimeoutException catch (e) {
      throw McpNetworkException('transport timeout: $e');
    }
  }

  /// 统一发送入口（POST 请求 / GET SSE 共用）：处理 ClientException/Timeout →
  /// [McpNetworkException]，状态码语义交给调用方裁决。
  Future<http.StreamedResponse> _sendRaw(http.Request req) async {
    try {
      return await _http.send(req);
    } on http.ClientException catch (e) {
      throw McpNetworkException('transport failed: ${e.message}');
    } on TimeoutException catch (e) {
      throw McpNetworkException('transport timeout: $e');
    }
  }

  @override
  void close() => _http.close();
}
