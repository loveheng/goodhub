/// 通用领域消息模型（arch-hardening ④：自 sandbox/conversation_store 的
/// CloudChatMessage 编解码解耦）。
///
/// 纯数据契约——只含 role/content/toolCalls 原语，**不感知任何 LLM 域类型**
/// （云端 CloudChatMessage 或端侧模型消息）。存储层（sandbox）只落本模型与
/// JSON 映射；各 LLM 域自行提供与自有类型的双向转换（云端见
/// `llm/cloud/chat_message_codec.dart`）。
library;

/// 工具调用原语（assistant 消息携带）。
class ToolCallData {
  const ToolCallData({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  final String argumentsJson;
}

/// 领域消息（transcript 序列的条目形态）。
sealed class ChatMessageData {
  const ChatMessageData();
}

class UserChatMessage extends ChatMessageData {
  const UserChatMessage(this.content);

  final String content;
}

class AssistantChatMessage extends ChatMessageData {
  const AssistantChatMessage({this.content, this.toolCalls = const []});

  final String? content;
  final List<ToolCallData> toolCalls;
}

class ToolResultChatMessage extends ChatMessageData {
  const ToolResultChatMessage({
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });

  final String toolCallId;
  final String content;
  final bool isError;
}

class SystemChatMessage extends ChatMessageData {
  const SystemChatMessage(this.content);

  /// 系统提示词内容（sampling 反向请求携带；transcript 口径不持久化）。
  final String content;
}
