/// Anthropic Messages 协议客户端（M2-T1）：与 OpenAI 形状独立的第二条协议线。
///
/// [AnthropicChatClient.baseUrl] 约定到 `/v1` 级（如 `https://api.anthropic.com/v1`），
/// 本类拼 `/messages`。
///
/// 契约差异（相对 OpenAI）：
/// - system 走顶层参数（非消息列表成员）；
/// - `max_tokens` 必填——请求缺省时兜 [AnthropicChatClient.defaultMaxTokens]；
/// - 工具入参 `input` 是 object（非 JSON 字符串）；
/// - 工具结果以 user 消息内的 `tool_result` 块回传，紧跟 tool_use 助手消息。
library;

import 'package:http/http.dart' as http;

import '../../core/errors/cloud_llm_error.dart';
import 'cloud_http.dart';
import 'cloud_llm.dart';
import 'sse_parser.dart' show SseEvent;

class AnthropicChatClient implements CloudLlmEngine {
  AnthropicChatClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature,
    http.Client? httpClient,
    this.connectTimeout = const Duration(seconds: 10),
  }) : _http = httpClient ?? http.Client();

  /// BaseURL（到 /v1 级）。
  final String baseUrl;
  final String apiKey;
  final String model;

  /// profile 级缺省温度；请求未带温度时使用（都缺省则不下发该字段）。
  final double? temperature;

  /// 连接超时（架构 §2 判据「连接 >5s」的起量初值，T2 降级控制器调参）。
  final Duration connectTimeout;

  final http.Client _http;

  /// Anthropic 契约必填 max_tokens 的协议缺省。
  static const defaultMaxTokens = 4096;

  @override
  String get name => '云端引擎 · $model（Anthropic）';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request) => mapAnthropicSse(
        sendSseRequest(
          client: _http,
          url: '$baseUrl/messages',
          headers: {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'},
          body: buildAnthropicBody(request, model: model, defaultTemperature: temperature),
          connectTimeout: connectTimeout,
        ),
      );
}

/// Anthropic 请求体构造（纯函数，独立导出供单测断言线格式）。
Map<String, Object?> buildAnthropicBody(
  CloudChatRequest request, {
  required String model,
  double? defaultTemperature,
}) {
  final systemLines = <String>[];
  final messages = <Object?>[];
  final toolResults = <Map<String, Object?>>[];

  // tool_result 必须整组落在一条 user 消息里，且紧跟 tool_use 助手消息——
  // 累积到下一条非结果消息（或流末尾）时统一 flush
  void flushToolResults() {
    if (toolResults.isNotEmpty) {
      messages.add({'role': 'user', 'content': List.of(toolResults)});
      toolResults.clear();
    }
  }

  for (final m in request.messages) {
    switch (m) {
      case SystemMessage(:final content):
        systemLines.add(content);
      case UserMessage(:final content):
        flushToolResults();
        messages.add({'role': 'user', 'content': content});
      case AssistantMessage(:final content, :final toolCalls):
        flushToolResults();
        final blocks = <Object?>[
          if (content != null && content.isNotEmpty)
            {'type': 'text', 'text': content},
          for (final c in toolCalls)
            {
              'type': 'tool_use',
              'id': c.id,
              'name': c.name,
              'input': decodeToolArguments(c.argumentsJson),
            },
        ];
        if (blocks.isEmpty) {
          throw const CloudProtocolException('assistant 消息既无文本也无 tool_use（Anthropic 拒绝空 content）');
        }
        messages.add({'role': 'assistant', 'content': blocks});
      case ToolResultMessage(:final toolCallId, :final content, :final isError):
        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': toolCallId,
          'content': content,
          if (isError) 'is_error': true,
        });
    }
  }
  flushToolResults();
  final temp = request.temperature ?? defaultTemperature;
  return {
    'model': model,
    if (systemLines.isNotEmpty) 'system': systemLines.join('\n\n'),
    'messages': messages,
    if (request.tools.isNotEmpty)
      'tools': [
        for (final t in request.tools)
          {
            'name': t.name,
            'description': t.description,
            'input_schema': t.parametersSchema,
          },
      ],
    'temperature': ?temp,
    'max_tokens': request.maxTokens ?? AnthropicChatClient.defaultMaxTokens,
    'stream': true,
  };
}

/// 工具入参 JSON → object（tool_use.input 契约为 object，非字符串）。
Map<String, Object?> decodeToolArguments(String argumentsJson) {
  if (argumentsJson.trim().isEmpty) return const {};
  return decodeJsonObject(argumentsJson, '工具入参 JSON');
}

/// Anthropic SSE → 引擎事件流（纯映射，独立导出供单测）。
///
/// 契约：`message_delta` 携带 stop_reason 结算，`message_stop` 收尾。
/// 流终止仍未结算 → [CloudProtocolException]（同 OpenAI 侧口径：禁猜测性兜底）。
Stream<CloudStreamEvent> mapAnthropicSse(Stream<SseEvent> events) async* {
  var settled = false;
  await for (final e in events) {
    final m = decodeJsonObject(e.data, 'Anthropic SSE data');
    if (m['type'] == 'error') {
      final err = m['error'];
      throw CloudHttpException(
        '云端流内错误: ${err is Map ? err['message'] ?? err : err}',
      );
    }
    switch (m['type']) {
      case 'content_block_start':
        final index = m['index'];
        if (index is! int) {
          throw const CloudProtocolException('content_block 缺 index');
        }
        final block = m['content_block'];
        if (block is Map && block['type'] == 'tool_use') {
          final id = block['id'];
          final name = block['name'];
          if (id is! String || name is! String) {
            throw const CloudProtocolException('tool_use 块缺 id/name');
          }
          yield CloudToolCallDelta(index: index, id: id, name: name);
        }
      case 'content_block_delta':
        final delta = m['delta'];
        if (delta is! Map) break;
        final index = m['index'];
        if (index is! int) {
          throw const CloudProtocolException('content_block_delta 缺 index');
        }
        switch (delta['type']) {
          case 'text_delta':
            final text = delta['text'];
            if (text is String && text.isNotEmpty) yield CloudTextDelta(text);
          case 'input_json_delta':
            final part = delta['partial_json'];
            yield CloudToolCallDelta(
              index: index,
              argumentsDelta: part is String ? part : '',
            );
          default:
            break; // thinking_delta 等扩展类型：T1 不消费
        }
      case 'message_delta':
        final delta = m['delta'];
        final stop = delta is Map ? delta['stop_reason'] : null;
        if (stop is String && !settled) {
          settled = true;
          yield CloudDone(finishReason: CloudFinishReason.fromAnthropic(stop));
        }
      default:
        break; // message_start / message_stop / ping / content_block_stop：无事件产出
    }
  }
  if (!settled) {
    throw const CloudProtocolException('流终止未交付 stop_reason（Anthropic 契约要求 message_delta 结算）');
  }
}
