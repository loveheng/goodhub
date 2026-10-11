/// 云端 BYOK LLM 引擎契约与数据模型（M2-T1，architecture §2 混合推理编排）。
///
/// 与端侧 OnDeviceLlmEngine（lib/llm/llm.dart，单发提取式）相对：
/// 云端引擎承担 Agent Loop 主环的对话式推理——多轮消息、工具 Schema 下发、
/// 流式产出（正文 token 与 tool_calls 分离）、finish_reason 结算
/// （§10「L2 拦截即结算流」的地基）。
///
/// 流式契约（实现必须满足）：
/// - 每个 send 流**恰好产出一个** [CloudDone]；
/// - 协议/传输失败以 [CloudLlmException] 子类作为流的错误终止，禁裸异常穿透；
/// - 取消 = 调用方 cancel 流订阅（§10 Abort 级联①步的云端路径，T2 接线）。
library;

/// BYOK 协议族。openaiCompatible 一套覆盖 OpenAI / DeepSeek / Qwen
/// （DashScope compatible-mode）——差异仅 BaseURL 与模型名。
enum CloudProtocol { openaiCompatible, anthropic }

/// 结算原因（跨协议归一）。
enum CloudFinishReason {
  /// 自然结束（OpenAI 'stop' / Anthropic 'end_turn'/'stop_sequence'）。
  stop,

  /// 要求执行工具后继续（OpenAI 'tool_calls' / Anthropic 'tool_use'）。
  toolCalls,

  /// 输出触达 token 上限。
  length,

  /// 内容安全拦截（OpenAI 'content_filter'）。
  contentFilter,

  /// 未识别的收尾原因（原样保底，禁丢弃——审计可见）。
  other;

  static CloudFinishReason fromOpenAi(String raw) => switch (raw) {
        'stop' => stop,
        'tool_calls' => toolCalls,
        'length' => length,
        'content_filter' => contentFilter,
        _ => other,
      };

  static CloudFinishReason fromAnthropic(String raw) => switch (raw) {
        'end_turn' || 'stop_sequence' => stop,
        'tool_use' => toolCalls,
        'max_tokens' => length,
        _ => other,
      };
}

/// 完整工具调用（流式 delta 拼接后的成品，见 tool_call_accumulator.dart）。
class AssembledToolCall {
  const AssembledToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;

  /// 工具入参原文（JSON 字符串）。解码交由 T2 执行环——网关校验在前，decode 在后。
  final String argumentsJson;
}

/// Token 用量（可缺省：部分兼容端不下发 usage）。
class CloudUsage {
  const CloudUsage({required this.promptTokens, required this.completionTokens});

  final int promptTokens;
  final int completionTokens;
}

/// 会话消息（协议无关形状，各客户端自行映射到 OpenAI/Anthropic 线格式）。
sealed class CloudChatMessage {
  const CloudChatMessage();
}

class SystemMessage extends CloudChatMessage {
  const SystemMessage(this.content);

  final String content;
}

class UserMessage extends CloudChatMessage {
  const UserMessage(this.content);

  final String content;
}

/// 助手消息：纯文本，或（Agent Loop 多轮态）带成品 tool_calls 的结算消息。
class AssistantMessage extends CloudChatMessage {
  const AssistantMessage({this.content, this.toolCalls = const []});

  final String? content;
  final List<AssembledToolCall> toolCalls;
}

/// 工具执行结果回传（OpenAI role=tool / Anthropic tool_result 块）。
class ToolResultMessage extends CloudChatMessage {
  const ToolResultMessage({
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });

  final String toolCallId;
  final String content;

  /// Anthropic 专用标记（is_error）；OpenAI 侧错误以 content 文本表达。
  final bool isError;
}

/// 下发给模型的工具声明（MCP tools/list Schema 直通形状）。
class CloudToolSchema {
  const CloudToolSchema({
    required this.name,
    required this.description,
    required this.parametersSchema,
    this.annotations,
  });

  final String name;
  final String description;

  /// JSON Schema 对象（`{"type":"object","properties":{...}}`）。
  final Map<String, Object?> parametersSchema;

  /// MCP annotations 原文（如 readOnlyHint）——客户端权限网关的建议值源，
  /// 不进云端请求序列化（客户端本地裁决用，见 coordinator/permission_gateway）。
  final Map<String, Object?>? annotations;
}

/// 一次对话推理请求。
class CloudChatRequest {
  const CloudChatRequest({
    required this.messages,
    this.tools = const [],
    this.temperature,
    this.maxTokens,
  });

  final List<CloudChatMessage> messages;
  final List<CloudToolSchema> tools;
  final double? temperature;

  /// 输出上限 token。OpenAI 可省略；Anthropic 必填（客户端兜协议缺省）。
  final int? maxTokens;
}

/// 流式事件：正文 token 与 tool_calls 分离（architecture §2）。
sealed class CloudStreamEvent {
  const CloudStreamEvent();
}

class CloudTextDelta extends CloudStreamEvent {
  const CloudTextDelta(this.text);

  final String text;
}

/// 工具调用增量：按 [index] 拼接；id/name 仅在首个增量出现，
/// [argumentsDelta] 逐片追加（JSON 字符串片段）。
class CloudToolCallDelta extends CloudStreamEvent {
  const CloudToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.argumentsDelta = '',
  });

  final int index;
  final String? id;
  final String? name;
  final String argumentsDelta;
}

/// 结算事件：finish_reason 落定，每流恰好一次（缺失 = 协议违规）。
class CloudDone extends CloudStreamEvent {
  const CloudDone({required this.finishReason, this.usage});

  final CloudFinishReason finishReason;
  final CloudUsage? usage;
}

/// 云端引擎接口（协议无关）。实现见 openai_chat_client.dart /
/// anthropic_chat_client.dart；装配入口 byok_store.dart [engineFor]。
abstract interface class CloudLlmEngine {
  /// 实现名（日志 / 设置页展示）。
  String get name;

  /// 流式对话推理。懒执行：监听时才发起请求。
  Stream<CloudStreamEvent> send(CloudChatRequest request);
}
