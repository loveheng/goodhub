/// MCP Client：JSON-RPC 2.0 over Streamable HTTP（无状态逐请求，接缝契约前提）。
/// 协议语义住本文件（coding-standards §1 边界纪律：core/network 只放纯传输底座）。
library;

import 'dart:async';
import 'dart:convert' as json;

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:http/http.dart' as http;

import '../core/errors/mcp_error.dart';
import 'json_rpc.dart';
import 'server_capabilities.dart';

class McpClient {
  McpClient({required this.baseUrl, this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// 如 `http://192.168.1.10:8765/mcp`
  final String baseUrl;

  /// goodshare 侧 X-Api-Key（app「MCP 服务」页查看）；空则不带鉴权头。
  final String? apiKey;
  final http.Client _http;

  /// 能力协商缓存（negotiate 幂等的载体）——一个 client 实例 = 一条 server 连接，
  /// 握手一次全程复用（SessionManager 共享连接池语义，architecture §15）。
  Future<ServerCapabilities>? _negotiating;

  /// server→client 反向请求处理器（M3，ai-app-split.md §3.11）：流式调用期间
  /// server 发来的 JSON-RPC request（如 sampling/createMessage）经此分派，
  /// 响应按 id POST 回端点（Streamable HTTP 回程序径）。null = 未启用反向
  /// 请求（server 请求收到 -32601 error 帧，不悬挂）；处理器抛 McpRpcException
  /// 转 error 帧（配额超限等结构化拒绝），其他异常转 -32603。
  Future<Map<String, Object?>?> Function(String method, Object? params)? onServerRequest;

  static const _headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
  };

  Map<String, String> get _requestHeaders => {
        ..._headers,
        if (apiKey != null && apiKey!.isNotEmpty) 'X-Api-Key': apiKey!,
      };

  /// 能力协商（M2.5-T2）：initialize 握手 + notifications/initialized 通知，
  /// 结果按 client 实例缓存（幂等——重复调用不重发请求）；握手失败后允许重试
  /// （缓存置空，下次调用重新握手——协商失败是「连不上/协议坏」，与 Polyfill
  /// 的「server 缺能力」降级语义不同层，后者由 [ServerCapabilities] 字段表达）。
  Future<ServerCapabilities> negotiate() {
    final existing = _negotiating;
    if (existing != null) return existing;
    final f = _doNegotiate().catchError((Object e, StackTrace st) {
      _negotiating = null; // 失败可重试
      throw e;
    });
    _negotiating = f;
    return f;
  }

  Future<ServerCapabilities> _doNegotiate() async {
    final result = await call('initialize', params: {
      'protocolVersion': kMcpProtocolVersion,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'goodhub', 'version': '0.1.0'},
    });
    final caps = ServerCapabilities.parse(result);
    // 规范握手第二步（MCP 2025-06-18：client 必须回 initialized 通知）。
    // DEGRADE: 个别 server 对通知返回 4xx 时不阻断连接（capabilities 已到手，
    // 通知失败仅留痕）——降级为无通知连接，不得让握手整段失败。
    try {
      await notify('notifications/initialized');
    } catch (e) {
      debugPrint('[DEGRADE] mcp-negotiate: initialized notify failed (ignored): $e');
    }
    return caps;
  }

  Future<Object?> call(String method, {Object? params}) async {
    final req = JsonRpcRequest(method, params: params);
    final http.Response resp;
    try {
      resp = await _http.post(Uri.parse(baseUrl),
          headers: _requestHeaders, body: req.encode());
    } on http.ClientException catch (e) {
      throw McpNetworkException('transport failed: ${e.message}');
    } on TimeoutException catch (e) {
      throw McpNetworkException('transport timeout: $e');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw McpNetworkException('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    final body = resp.body.trim();
    if (body.isEmpty) return null; // 202 Accepted（notification）
    final decoded = _decodePayload(body, resp);
    final response = JsonRpcResponse.parse(decoded);
    final err = response.error;
    if (err != null) throw err;
    return response.result;
  }

  static int _progressTokenCounter = 0;

  /// 带进度通告的调用（M2.5-T7，ai-app-split.md §3.9）：自动注入
  /// `_meta.progressToken`，server 回 SSE 帧流时**流式分帧解析**——progress
  /// 通知帧走 [onProgress]，终帧返回 result；server 忽略 token 回单 JSON 时
  /// 原路解析（Tier 2 兼容，opt-in 语义的收侧）。
  /// [onRequestId]（M3-T2）：请求 id 分配即回调——Abort 级联下发
  /// `notifications/cancelled` 需要知道在途请求 id（§3.11 回程同路）。
  /// C-1 缓冲黑洞的收侧兑现：http 包默认全量缓冲响应体，本方法用
  /// `client.send` 逐行消费字节流，progress 帧无需等响应结束即达。
  Future<Object?> callWithProgress(
    String method, {
    Object? params,
    required void Function(Object? progressParams) onProgress,
    void Function(int requestId)? onRequestId,
  }) async {
    final token = ++_progressTokenCounter;
    final p = params is Map<String, Object?>
        ? Map<String, Object?>.of(params)
        : <String, Object?>{};
    p['_meta'] = {
      ...((p['_meta'] as Map<String, Object?>?) ?? const {}),
      'progressToken': token,
    };
    final req = JsonRpcRequest(method, params: p);
    if (onRequestId != null && req.id != null) onRequestId(req.id!);
    final http.StreamedResponse resp;
    try {
      resp = await _http.send(http.Request('POST', Uri.parse(baseUrl))
        ..headers.addAll(_requestHeaders)
        ..body = req.encode());
    } on http.ClientException catch (e) {
      throw McpNetworkException('transport failed: ${e.message}');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      await resp.stream.drain<void>();
      throw McpNetworkException('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    final contentType = resp.headers['content-type'] ?? '';
    if (!contentType.contains('text/event-stream')) {
      // 单 JSON 回退：server 无 progress 感知（Polyfill 语义的收侧）
      final body = (await resp.stream.bytesToString()).trim();
      if (body.isEmpty) return null;
      final response = JsonRpcResponse.parse(_decodePayload(body, null));
      final err = response.error;
      if (err != null) throw err;
      return response.result;
    }

    // SSE 分帧解析：`:` comment（keep-alive 心跳）忽略；`data:` 行累积，
    // 空行断帧——progress 通知即达即回调；server→client 反向请求（M3 §3.11）
    // 分派处理器并回程；其余通知帧忽略；带 id 无 method 的帧为终帧。
    final frame = StringBuffer();
    await for (final line in resp.stream
        .transform(json.utf8.decoder)
        .transform(const json.LineSplitter())) {
      if (line.startsWith(':')) continue;
      if (line.startsWith('data:')) {
        frame
          ..write(line.substring(5).trim())
          ..write('\n');
        continue;
      }
      if (line.isNotEmpty || frame.isEmpty) continue;
      final payload = frame.toString().trim();
      frame.clear();
      final msg = json.jsonDecode(payload);
      if (msg is Map<String, Object?>) {
        final method = msg['method'];
        if (method == 'notifications/progress') {
          onProgress(msg['params']);
          continue;
        }
        if (method is String && method.isNotEmpty && msg['id'] != null) {
          await _answerServerRequest(method, msg['id']!, msg['params']);
          continue;
        }
        if (method != null) continue; // 其他 server 主动通知帧：不消费（订阅通知走 GET 通道）
      }
      final response = JsonRpcResponse.parse(msg);
      final err = response.error;
      if (err != null) throw err;
      return response.result;
    }
    throw const McpProtocolException('SSE stream ended without result frame');
  }

  /// 反向请求回程：handler result → POST {id, result}；McpRpcException →
  /// POST {id, error}（code/message/data 原样）；其他异常 → -32603。回程
  /// 失败仅 [DEGRADE] 留痕——流仍在读终帧，严禁让帧读取中断（server 侧按
  /// 超时兜底）。无论成败 server 侧 completer 必被唤醒，不悬挂。
  Future<void> _answerServerRequest(String method, Object id, Object? params) async {
    Map<String, Object?> frame;
    final handler = onServerRequest;
    if (handler == null) {
      frame = {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': '宿主未启用反向请求处理: $method'},
      };
    } else {
      try {
        final result = await handler(method, params);
        frame = {'jsonrpc': '2.0', 'id': id, 'result': result};
      } on McpRpcException catch (e) {
        frame = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': e.code,
            'message': e.message,
            if (e.data != null) 'data': e.data,
          },
        };
      } catch (e) {
        frame = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32603, 'message': '宿主反向请求处理失败: $e'},
        };
      }
    }
    try {
      await _http.post(Uri.parse(baseUrl),
          headers: _requestHeaders, body: json.jsonEncode(frame));
    } catch (e) {
      debugPrint('[DEGRADE] mcp-client: server-request answer POST failed: $e');
    }
  }

  /// 兼容 JSON 与 SSE 两种响应体（Streamable HTTP 允许服务端回 SSE 帧）。
  Object? _decodePayload(String body, http.BaseResponse? resp) {
    final contentType = resp?.headers['content-type'] ?? '';
    if (contentType.contains('text/event-stream')) {
      for (final line in body.split('\n')) {
        if (line.startsWith('data:')) {
          final data = line.substring(5).trim();
          if (data.isNotEmpty) return json.jsonDecode(data);
        }
      }
      throw const McpProtocolException('SSE response without data frame');
    }
    return json.jsonDecode(body);
  }

  Future<Object?> notify(String method, {Object? params}) async {
    final req = JsonRpcRequest(method, params: params, notify: true);
    final resp = await _http.post(Uri.parse(baseUrl),
        headers: _headers, body: req.encode());
    if (resp.statusCode >= 400) {
      throw McpNetworkException('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    return null;
  }

  /// resources/list（ai-app-split.md §3.8）：只读数据面清单。Tier 2 Server
  /// 无此能力——调用方按 capabilities（hasPrompts/hasResources）先判再调。
  Future<List<Map<String, Object?>>> listResources() async {
    final result = await call('resources/list');
    if (result is! Map) {
      throw const McpProtocolException('resources/list result is not an object');
    }
    final resources = result['resources'];
    if (resources is! List) {
      throw const McpProtocolException('resources/list missing resources array');
    }
    return [
      for (final r in resources)
        if (r is Map<String, Object?>) r,
    ];
  }

  /// resources/read：返回首个 text 内容块的文本（同 claim text 基线的只读注入）。
  Future<String> readResource(String uri) async {
    final result = await call('resources/read', params: {'uri': uri});
    if (result is! Map) {
      throw const McpProtocolException('resources/read result is not an object');
    }
    final contents = result['contents'];
    if (contents is! List || contents.isEmpty) {
      throw const McpProtocolException('resources/read missing contents');
    }
    final first = contents.first;
    if (first is Map && first['text'] is String) {
      return first['text'] as String;
    }
    throw const McpProtocolException('resources/read content missing text');
  }

  /// prompts/list（ai-app-split.md §3.7）：CoW 模板源清单（含版本元数据）。
  /// Tier 2 无此能力——调用方按 capabilities（hasPrompts）先判再调。
  Future<List<Map<String, Object?>>> listPrompts() async {
    final result = await call('prompts/list');
    if (result is! Map) {
      throw const McpProtocolException('prompts/list result is not an object');
    }
    final prompts = result['prompts'];
    if (prompts is! List) {
      throw const McpProtocolException('prompts/list missing prompts array');
    }
    return [
      for (final p in prompts)
        if (p is Map<String, Object?>) p,
    ];
  }

  /// prompts/get 原文通道（不传 arguments → server 回未渲染模板，CoW 同步用）。
  Future<String> getPromptRaw(String name) async {
    final result = await call('prompts/get', params: {'name': name});
    if (result is! Map) {
      throw const McpProtocolException('prompts/get result is not an object');
    }
    final messages = result['messages'];
    if (messages is! List || messages.isEmpty) {
      throw const McpProtocolException('prompts/get missing messages');
    }
    final first = messages.first;
    if (first is Map && first['content'] is Map) {
      final content = first['content'] as Map;
      if (content['text'] is String) return content['text'] as String;
    }
    throw const McpProtocolException('prompts/get message missing text');
  }

  void close() => _http.close();
}
