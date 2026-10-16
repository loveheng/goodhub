/// CloudChatMessage 编解码（arch-hardening ④：自 sandbox/conversation_store
/// 迁入 llm 域——转换归模型所有方，存储层只认 `core/chat_message_data.dart`
/// 的纯数据契约）。
///
/// - **CloudChatMessage ↔ ChatMessageData**：本文件扩展方法，llm 域自持转换权；
/// - **ChatMessageData ↔ JSON**：transcript 忠实序列化（System 不入 transcript）；
///   存储层（sandbox）只经 `encodeData`/`decodeData` 通道，不 import llm；
/// - 配对完整是恢复前提（architecture §12）——AgentLoop 出口已保证，此处不重排；
/// - 未知类型/缺字段跳过 + 计数返回（禁静默吞——调用方对账）。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/chat_message_data.dart';
import 'cloud_llm.dart';

extension CloudChatMessageDataX on CloudChatMessage {
  /// llm 模型 → 领域纯数据（存储/跨域传递用）。
  ChatMessageData toData() => switch (this) {
        UserMessage(:final content) => UserChatMessage(content),
        AssistantMessage(:final content, :final toolCalls) =>
          AssistantChatMessage(
            content: content,
            toolCalls: [
              for (final c in toolCalls)
                ToolCallData(
                  id: c.id,
                  name: c.name,
                  argumentsJson: c.argumentsJson,
                ),
            ],
          ),
        ToolResultMessage(
          :final toolCallId,
          :final content,
          :final isError,
        ) =>
          ToolResultChatMessage(
            toolCallId: toolCallId,
            content: content,
            isError: isError,
          ),
        SystemMessage(:final content) => SystemChatMessage(content),
      };
}

/// 领域纯数据 → llm 模型（恢复/回注 transcript 用）。
extension ChatMessageDataX on ChatMessageData {
  CloudChatMessage toCloud() => switch (this) {
        UserChatMessage(:final content) => UserMessage(content),
        AssistantChatMessage(:final content, :final toolCalls) =>
          AssistantMessage(
            content: content,
            toolCalls: [
              for (final c in toolCalls)
                AssembledToolCall(
                  id: c.id,
                  name: c.name,
                  argumentsJson: c.argumentsJson,
                ),
            ],
          ),
        ToolResultChatMessage(
          :final toolCallId,
          :final content,
          :final isError,
        ) =>
          ToolResultMessage(
            toolCallId: toolCallId,
            content: content,
            isError: isError,
          ),
        SystemChatMessage(:final content) => SystemMessage(content),
      };
}

/// transcript 编解码通道（LLM 模型形态；存储层经 `encodeData`/`decodeData`）。
final class ChatMessageCodec {
  const ChatMessageCodec._();

  /// 编码 transcript（System 防御编码为占位——恢复侧跳过）。
  static List<Map<String, Object?>> encodeCloud(
          List<CloudChatMessage> messages) =>
      encodeData([for (final m in messages) m.toData()]);

  /// 恢复 transcript：未知类型/缺字段跳过并 DEGRADE 留痕（禁静默吞——计数
  /// 可观测由日志对账）；assistant/toolCalls 配对由 AgentLoop 出口保证，
  /// 此处不重排。
  static List<CloudChatMessage> decodeCloud(List<Map<String, Object?>> raw) {
    final (data, skipped) = _decodeRaw(raw);
    if (skipped > 0) {
      debugPrint(
          '[DEGRADE] chat-message-codec: 消息恢复跳过 $skipped 条（类型未知/缺字段）');
    }
    return [for (final m in data) m.toCloud()];
  }

  /// 领域纯数据形态编码（存储层唯一出口）。
  static List<Map<String, Object?>> encodeData(List<ChatMessageData> ms) => [
        for (final m in ms)
          switch (m) {
            UserChatMessage(:final content) =>
              <String, Object?>{'type': 'user', 'content': content},
            AssistantChatMessage(:final content, :final toolCalls) =>
              <String, Object?>{
                'type': 'assistant',
                'content': ?content,
                'toolCalls': [
                  for (final c in toolCalls)
                    <String, Object?>{
                      'id': c.id,
                      'name': c.name,
                      'argumentsJson': c.argumentsJson,
                    },
                ],
              },
            ToolResultChatMessage(
              :final toolCallId,
              :final content,
              :final isError,
            ) =>
              <String, Object?>{
                'type': 'toolResult',
                'toolCallId': toolCallId,
                'content': content,
                'isError': isError,
              },
            SystemChatMessage() => const <String, Object?>{
                'type': 'system',
              }, // transcript 口径不含 System——防御编码，恢复侧跳过
          },
      ];

  /// 领域纯数据形态解码（存储层唯一入口）：返回 (消息, 跳过数)。
  static (List<ChatMessageData>, int) decodeData(
      List<Map<String, Object?>> raw) {
    final (data, skipped) = _decodeRaw(raw);
    return (data, skipped);
  }

  static (List<ChatMessageData>, int) _decodeRaw(
      List<Map<String, Object?>> raw) {
    final out = <ChatMessageData>[];
    var skipped = 0;
    for (final m in raw) {
      try {
        switch (m['type']) {
          case 'user':
            out.add(UserChatMessage(m['content'] as String? ?? ''));
          case 'assistant':
            out.add(AssistantChatMessage(
              content: m['content'] as String?,
              toolCalls: [
                for (final c in m['toolCalls'] as List? ?? const [])
                  if (c is Map)
                    ToolCallData(
                      id: c['id'] as String? ?? '',
                      name: c['name'] as String? ?? '',
                      argumentsJson: c['argumentsJson'] as String? ?? '{}',
                    ),
              ],
            ));
          case 'toolResult':
            out.add(ToolResultChatMessage(
              toolCallId: m['toolCallId'] as String? ?? '',
              content: m['content'] as String? ?? '',
              isError: m['isError'] as bool? ?? false,
            ));
          case 'system':
            break; // transcript 口径不含 System
          default:
            skipped++;
        }
      } on Object {
        skipped++;
      }
    }
    return (out, skipped);
  }
}
