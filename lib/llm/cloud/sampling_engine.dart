/// 云引擎的 sampling 端口适配（arch-hardening ③）：把 [CloudLlmEngine] 的
/// 单发流式推理适配为 mcp 域 [SamplingEngine] 最小端口——转换归模型所有方，
/// mcp 域不 import llm。
library;

import '../../core/chat_message_data.dart';
import '../../mcp/sampling.dart' show SamplingEngine;
import 'chat_message_codec.dart';
import 'cloud_llm.dart';

/// [CloudLlmEngine] → [SamplingEngine] 适配。
///
/// 临时会话语义（architecture §15）：请求只带本条 messages（无历史、无记忆
/// 注入），正文增量经 [CloudTextDelta] 透传为 `Stream<String>`。
final class CloudSamplingEngine implements SamplingEngine {
  const CloudSamplingEngine(this.engine);

  final CloudLlmEngine engine;

  @override
  String get name => engine.name;

  @override
  Stream<String> sendText({
    required List<ChatMessageData> messages,
    required int maxTokens,
  }) async* {
    final req = CloudChatRequest(
      messages: [for (final m in messages) m.toCloud()],
      maxTokens: maxTokens,
    );
    await for (final ev in engine.send(req)) {
      if (ev is CloudTextDelta) yield ev.text;
    }
  }
}
