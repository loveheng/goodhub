/// OpenAI Chat Completions 协议客户端（M2-T1，architecture §2 云端 BYOK）。
///
/// 同协议族覆盖 OpenAI / DeepSeek / Qwen（DashScope compatible-mode）：
/// 差异仅 BaseURL 与模型名（[CloudProtocol.openaiCompatible]）。
/// [OpenAiChatClient.baseUrl] 约定到 `/v1` 级（如 `https://api.openai.com/v1`），
/// 本类拼 `/chat/completions`。
library;

import 'package:http/http.dart' as http;

import '../../core/errors/cloud_llm_error.dart';
import 'cloud_http.dart';
import 'cloud_llm.dart';
import 'sse_parser.dart' show SseEvent;

class OpenAiChatClient implements CloudLlmEngine {
  OpenAiChatClient({
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

  @override
  String get name => '云端引擎 · $model';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) =>
      mapOpenAiSse(
        sendSseRequest(
          client: _http,
          url: '$baseUrl/chat/completions',
          headers: {'Authorization': 'Bearer $apiKey'},
          body: buildOpenAiBody(request, model: model, defaultTemperature: temperature),
          connectTimeout: connectTimeout,
          onActivity: onActivity,
        ),
      );
}

/// OpenAI 请求体构造（纯函数，独立导出供单测断言线格式）。
Map<String, Object?> buildOpenAiBody(
  CloudChatRequest request, {
  required String model,
  double? defaultTemperature,
}) {
  final temp = request.temperature ?? defaultTemperature;
  return {
    'model': model,
    'messages': [for (final m in request.messages) _encodeOpenAiMessage(m)],
    if (request.tools.isNotEmpty)
      'tools': [
        for (final t in request.tools)
          {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              // G5/§8.2：递归字典序归一，键序不随上游 MCP 返回漂移。
              'parameters': CloudToolSchema.canonicalParameters(t.parametersSchema),
            },
          },
      ],
    'temperature': ?temp,
    if (request.maxTokens != null) 'max_tokens': request.maxTokens,
    'stream': true,
  };
}

Object? _encodeOpenAiMessage(CloudChatMessage m) => switch (m) {
      SystemMessage(:final content) => {'role': 'system', 'content': content},
      UserMessage(:final content) => {'role': 'user', 'content': content},
      AssistantMessage(:final content, :final toolCalls) => {
          'role': 'assistant',
          'content': ?content,
          if (toolCalls.isNotEmpty)
            'tool_calls': [
              for (final c in toolCalls)
                {
                  'id': c.id,
                  'type': 'function',
                  'function': {'name': c.name, 'arguments': c.argumentsJson},
                },
            ],
        },
      // OpenAI 无 is_error 字段：错误结果以 content 文本表达（契约如此）
      ToolResultMessage(:final toolCallId, :final content) => {
          'role': 'tool',
          'tool_call_id': toolCallId,
          'content': content,
        },
    };

/// OpenAI SSE → 引擎事件流（正文与 tool_calls 分离；纯映射，独立导出供单测）。
///
/// 契约：收尾 chunk 携带 finish_reason，`[DONE]` 哨兵终止。流终止仍未结算
/// → [CloudProtocolException]（禁猜测性兜底——部分兼容端漏发收尾属于
/// 必须显式暴露的契约违规，静默补 stop 会污染 T2 熔断与结算语义）。
Stream<CloudStreamEvent> mapOpenAiSse(Stream<SseEvent> events) async* {
  var settled = false;
  await for (final e in events) {
    if (e.data == '[DONE]') break;
    final m = decodeJsonObject(e.data, 'OpenAI SSE data');
    final err = m['error'];
    if (err != null) {
      throw CloudHttpException(
        '云端流内错误: ${err is Map ? err['message'] ?? err : err}',
      );
    }
    final choices = m['choices'];
    if (choices is! List || choices.isEmpty) continue; // usage-only 等无 choices 帧
    final choice = choices.first;
    if (choice is! Map) {
      throw const CloudProtocolException('choices[0] 非 object');
    }
    final delta = choice['delta'];
    if (delta is Map) {
      final content = delta['content'];
      if (content is String && content.isNotEmpty) yield CloudTextDelta(content);
      // 思考过程（2026-10-21 M1）：OpenAI 兼容侧推理型模型的
      // `reasoning_content`（SiliconFlow/DeepSeek/Qwen/GLM 等）——展示 only，
      // 契约见 [CloudThinkingDelta]：不进 accumulator、不过滤、不入历史。
      // 缺失即普通模型（非推理型），零副作用。
      final reasoning = delta['reasoning_content'];
      if (reasoning is String && reasoning.isNotEmpty) {
        yield CloudThinkingDelta(reasoning);
      }
      final calls = delta['tool_calls'];
      if (calls is List) {
        for (final c in calls) {
          if (c is! Map) {
            throw const CloudProtocolException('tool_calls 增量非 object');
          }
          final index = c['index'];
          if (index is! int) {
            throw const CloudProtocolException('tool_calls 增量缺 index');
          }
          final fn = c['function'];
          yield CloudToolCallDelta(
            index: index,
            id: c['id'] is String ? c['id'] as String : null,
            name: fn is Map && fn['name'] is String ? fn['name'] as String : null,
            argumentsDelta: fn is Map && fn['arguments'] is String
                ? fn['arguments'] as String
                : '',
          );
        }
      }
    }
    final finish = choice['finish_reason'];
    if (finish is String && !settled) {
      settled = true;
      yield CloudDone(finishReason: CloudFinishReason.fromOpenAi(finish));
    }
  }
  if (!settled) {
    throw const CloudProtocolException('流终止未交付 finish_reason（OpenAI 契约要求收尾 chunk 结算）');
  }
}
