/// JSON-RPC 2.0 请求/响应的最小强类型封装（禁 dynamic 穿越总线）。
library;

import 'dart:convert' as json;

import '../core/errors/mcp_error.dart';

class JsonRpcRequest {
  // 非 const：id 由静态计数器在构造时分配
  JsonRpcRequest(this.method, {this.params, this.notify = false})
      : id = notify ? null : _nextId();

  final String method;
  final Object? params;
  final bool notify;
  final int? id;

  static int _counter = 0;
  static int _nextId() => ++_counter;

  String encode() => json.jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
        if (id != null) 'id': id,
      });
}

class JsonRpcResponse {
  const JsonRpcResponse({this.result, this.error, this.id});

  /// A02（review-fix-2026-10）：id 宽松解析——JSON-RPC 规范允许 string id（部分
  /// server 回 string），此前 `as int?` 对之抛裸 TypeError（违 §5.5 显式错误
  /// 传递）。id 未用于响应关联（调用方单飞语义），int/String 之外一律 null。
  static Object? _parseId(Object? v) => v is int || v is String ? v : null;

  /// 从 Map 严格解析；形状违规抛 McpProtocolException，不静默兜底。
  factory JsonRpcResponse.parse(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      throw const McpProtocolException('response is not a JSON object');
    }
    final error = decoded['error'];
    if (error is Map<String, Object?>) {
      final code = error['code'];
      final message = error['message'];
      if (code is! int || message is! String) {
        throw const McpProtocolException('malformed json-rpc error object');
      }
      return JsonRpcResponse(
        error: McpRpcException(code, message, data: error['data']),
        id: _parseId(decoded['id']),
      );
    }
    return JsonRpcResponse(result: decoded['result'], id: _parseId(decoded['id']));
  }

  final Object? result;
  final McpRpcException? error;

  /// A02：宽松解析后的 id（int/String；畸形置 null）——未用于响应关联。
  final Object? id;
}
