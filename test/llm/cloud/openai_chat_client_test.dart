import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/cloud_llm_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/cloud/sse_parser.dart';
import 'package:goodhub/llm/cloud/openai_chat_client.dart';
import 'package:goodhub/llm/cloud/tool_call_accumulator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('buildOpenAiBody', () {
    test('完整形状：四类消息/工具/温度/max_tokens/stream', () {
      final body = buildOpenAiBody(
        const CloudChatRequest(
          messages: [
            SystemMessage('sys'),
            UserMessage('u'),
            AssistantMessage(
              content: 'a',
              toolCalls: [
                AssembledToolCall(id: 'call_1', name: 'f', argumentsJson: '{"x":1}'),
              ],
            ),
            ToolResultMessage(toolCallId: 'call_1', content: 'r'),
          ],
          tools: [
            CloudToolSchema(name: 'f', description: 'd', parametersSchema: {'type': 'object'}),
          ],
          temperature: 0.3,
          maxTokens: 128,
        ),
        model: 'm1',
      );
      expect(body['model'], 'm1');
      expect(body['stream'], true);
      expect(body['temperature'], 0.3);
      expect(body['max_tokens'], 128);

      final messages = body['messages']! as List<Object?>;
      expect((messages[0]! as Map)['role'], 'system');
      expect((messages[1]! as Map)['role'], 'user');
      final assistant = messages[2]! as Map;
      final call = (assistant['tool_calls']! as List).single! as Map;
      expect(call['id'], 'call_1');
      expect((call['function']! as Map)['arguments'], '{"x":1}');
      final toolMsg = messages[3]! as Map;
      expect(toolMsg['role'], 'tool');
      expect(toolMsg['tool_call_id'], 'call_1');

      final tools = body['tools']! as List;
      expect(((tools.single! as Map)['function']! as Map)['name'], 'f');
    });

    test('温度与 maxTokens 全缺省时不下发字段', () {
      final body = buildOpenAiBody(
        const CloudChatRequest(messages: [UserMessage('u')]),
        model: 'm',
      );
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('tools'), isFalse);
    });
  });

  group('mapOpenAiSse', () {
    Stream<CloudStreamEvent> map(String raw) =>
        mapOpenAiSse(parseSse(Stream.value(raw)));

    test('正文与 tool_calls 分离 + finish_reason 结算', () async {
      final events = await map(
        'data: {"choices":[{"delta":{"role":"assistant","content":"你"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"好"}}]}\n\n'
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",'
        '"function":{"name":"f","arguments":"{\\"a\\""}}]}}]}\n\n'
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
        '"function":{"arguments":":1}"}}]}}]}\n\n'
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n'
        'data: [DONE]\n\n',
      ).toList();
      expect(
        events.whereType<CloudTextDelta>().map((e) => e.text).join(),
        '你好',
      );
      final deltas = events.whereType<CloudToolCallDelta>().toList();
      expect(deltas, hasLength(2));
      expect(deltas.first.id, 'call_1');
      expect(deltas.first.name, 'f');
      expect(deltas.last.argumentsDelta, ':1}');
      expect(events.whereType<CloudDone>().single.finishReason,
          CloudFinishReason.toolCalls);
    });

    test('finish_reason 归一映射', () async {
      final cases = {
        'stop': CloudFinishReason.stop,
        'length': CloudFinishReason.length,
        'content_filter': CloudFinishReason.contentFilter,
      };
      for (final entry in cases.entries) {
        final events = await map(
          'data: {"choices":[{"delta":{},"finish_reason":"${entry.key}"}]}\n\n'
          'data: [DONE]\n\n',
        ).toList();
        expect(events.whereType<CloudDone>().single.finishReason, entry.value);
      }
    });

    test('流内 error 对象 → CloudHttpException', () async {
      await expectLater(
        map('data: {"error":{"message":"quota exceeded"}}\n\n').toList(),
        throwsA(isA<CloudHttpException>()),
      );
    });

    test('data 非 JSON → CloudProtocolException', () async {
      await expectLater(
        map('data: not-json\n\n').toList(),
        throwsA(isA<CloudProtocolException>()),
      );
    });

    test('[DONE] 前未见 finish_reason → CloudProtocolException（禁猜测性兜底）', () async {
      await expectLater(
        map('data: {"choices":[{"delta":{"content":"x"}}]}\n\ndata: [DONE]\n\n')
            .toList(),
        throwsA(isA<CloudProtocolException>()),
      );
    });
  });

  group('OpenAiChatClient.send', () {
    test('端到端：URL/鉴权头/事件产出（MockClient.streaming）', () async {
      http.BaseRequest? captured;
      final client = MockClient.streaming((req, _) async {
        captured = req;
        return http.StreamedResponse(
          Stream.fromIterable([
            utf8.encode('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'),
            utf8.encode(
              'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
              'data: [DONE]\n\n',
            ),
          ]),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final engine = OpenAiChatClient(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'm1',
        httpClient: client,
      );
      final acc = await CloudStreamAccumulator.drain(
        engine.send(const CloudChatRequest(messages: [UserMessage('hi')])),
      );
      expect(captured!.url.toString(), 'https://api.example.com/v1/chat/completions');
      expect(captured!.headers['Authorization'], 'Bearer sk-test');
      expect(captured!.headers['Accept'], 'text/event-stream');
      expect(acc.text, 'hi');
      expect(acc.finishReason, CloudFinishReason.stop);
    });

    test('非 2xx → CloudHttpException 且带 statusCode（T2 降级计数依据）', () async {
      final client = MockClient.streaming((req, _) async {
        return http.StreamedResponse(
          Stream.fromIterable([utf8.encode('{"error":{"message":"quota"}}')]),
          429,
        );
      });
      final engine = OpenAiChatClient(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'k',
        model: 'm',
        httpClient: client,
      );
      await expectLater(
        engine
            .send(const CloudChatRequest(messages: [UserMessage('u')]))
            .toList(),
        throwsA(isA<CloudHttpException>()
            .having((e) => e.statusCode, 'statusCode', 429)),
      );
    });
  });
}
