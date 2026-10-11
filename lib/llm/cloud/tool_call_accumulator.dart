/// 流式事件累积器：把 [CloudStreamEvent] 流拼装为完整正文与成品工具调用（M2-T1）。
///
/// architecture §2「正文 Token 与 tool_calls 分离」的结算侧：正文 token 流式渲染
/// 走事件流本身；落上下文的 [AssistantMessage]（文本 + 完整 tool_calls）由本器拼装，
/// T2 coordinator 的多轮回填要用。
library;

import '../../core/errors/cloud_llm_error.dart';
import 'cloud_llm.dart';

class CloudStreamAccumulator {
  final StringBuffer _text = StringBuffer();
  final Map<int, _ToolCallBuilder> _calls = {};

  /// 结算原因（每流恰好一个 CloudDone；缺失在事件源侧已按协议违规抛错）。
  CloudFinishReason? finishReason;
  CloudUsage? usage;

  void add(CloudStreamEvent event) {
    switch (event) {
      case CloudTextDelta(:final text):
        _text.write(text);
      case CloudToolCallDelta(
          :final index,
          :final id,
          :final name,
          :final argumentsDelta,
        ):
        final builder = _calls.putIfAbsent(index, _ToolCallBuilder.new);
        if (id != null) builder.id = id;
        if (name != null) builder.name = name;
        builder.arguments.write(argumentsDelta);
      case CloudDone(:final finishReason, :final usage):
        this.finishReason = finishReason;
        if (usage != null) this.usage = usage;
    }
  }

  /// 顺序消费整个流并累积（协议错误原样透传给调用方）。
  static Future<CloudStreamAccumulator> drain(Stream<CloudStreamEvent> events) async {
    final acc = CloudStreamAccumulator();
    await for (final e in events) {
      acc.add(e);
    }
    return acc;
  }

  String get text => _text.toString();

  /// 成品工具调用（按增量 index 升序）。
  List<AssembledToolCall> get toolCalls {
    final indices = _calls.keys.toList()..sort();
    return [for (final i in indices) _calls[i]!.build()];
  }

  /// 结算为可回填上下文的助手消息。
  AssistantMessage toAssistantMessage() => AssistantMessage(
        content: text.isEmpty ? null : text,
        toolCalls: toolCalls,
      );
}

class _ToolCallBuilder {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  AssembledToolCall build() {
    final i = id;
    final n = name;
    if (i == null || n == null) {
      throw const CloudProtocolException('tool_call 流结束仍缺 id/name，无法结算');
    }
    return AssembledToolCall(id: i, name: n, argumentsJson: arguments.toString());
  }
}
