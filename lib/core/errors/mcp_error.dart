/// MCP 层领域异常基类（coding-standards §5.5：显式错误传递，禁裸抛）。
sealed class McpException implements Exception {
  const McpException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// 网络层失败：连接拒绝、超时、非 2xx 状态码。
class McpNetworkException extends McpException {
  const McpNetworkException(super.message, {this.statusCode});
  final int? statusCode;
}

/// 服务端返回的 JSON-RPC error 对象（code/message/data）。
class McpRpcException extends McpException {
  const McpRpcException(this.code, super.message, {this.data});
  final int code;
  final Object? data;
}

/// 响应形状不符合契约（缺字段/类型不符）——契约违规立即暴露，禁猜测性兜底。
class McpProtocolException extends McpException {
  const McpProtocolException(super.message);
}

/// 步数墙超限（M1.5；原 turn_wall 内定义，sealed 边界收敛至此）。
class TurnWallExceeded extends McpException {
  const TurnWallExceeded(super.message);
}
