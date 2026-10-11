/// 云端 LLM 引擎领域异常（coding-standards §4：显式错误传递，禁裸抛）。
/// 与 MCP 总线的 [McpException] 平行：出站 BYOK 推理路径的独立错误域。
library;

sealed class CloudLlmException implements Exception {
  const CloudLlmException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// 传输层失败：连接建立失败 / 连接超时 / 流中断。
class CloudNetworkException extends CloudLlmException {
  const CloudNetworkException(super.message);
}

/// 云端 API 层失败：非 2xx 状态码，或流内 API error 事件。
/// [statusCode] 为 HTTP 状态码；流内错误事件无状态码时为 null。
/// T2 降级控制器据 [statusCode] 计数「连续 2 次 5xx/429」（architecture §2）。
class CloudHttpException extends CloudLlmException {
  const CloudHttpException(super.message, {this.statusCode});

  final int? statusCode;
}

/// 响应形状不符合协议契约（缺字段/类型不符/流异常终止）——契约违规立即暴露，
/// 禁猜测性兜底（ai-sideeffect-guard DEGRADE 禁区同口径）。
class CloudProtocolException extends CloudLlmException {
  const CloudProtocolException(super.message);
}
