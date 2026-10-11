import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/cloud_llm_error.dart';
import 'package:goodhub/llm/cloud/anthropic_chat_client.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/cloud/sse_parser.dart';
import 'package:goodhub/llm/cloud/tool_call_accumulator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('buildAnthropicBody', () {
    test('system 抽取到顶层并以空行合并', () {
      final body = buildAnthropicBody(
        const CloudChatRequest(
          messages: [SystemMessage('a'), SystemMessage('b'), UserMessage('u')],
        ),
        model: 'm',
      );
      expect(body['system'], 'a\n\nb');
      final messages = body['messages']! as List<Object?>;
      expect(messages, hasLength(1));
      expect((messages.single! as Map)['content'], 'u');
    });

    test('assistant 文本 + tool_use（入参解码为 object）；tool_result 归组 user 块', () {
      final body = buildAnthropicBody(
        const CloudChatRequest(
          messages: [
            UserMessage('u'),
            AssistantMessage(
              content: '想一下',
              toolCalls: [
                AssembledToolCall(id: 'toolu_1', name: 'f', argumentsJson: '{"x":1}'),
              ],
            ),
            ToolResultMessage(toolCallId: 'toolu_1', content: 'r1'),
            ToolResultMessage(toolCallId: 'toolu_2', content: 'r2', isError: true),
            AssistantMessage(content: '结论'),
          ],
        ),
        model: 'm',
      );
      final messages = body['messages']! as List<Object?>;
      expect(messages.map((e) => (e! as Map)['role']).toList(),
          ['user', 'assistant', 'user', 'assistant']);

      final assistantBlocks = (messages[1]! as Map)['content']! as List<Object?>;
      expect((assistantBlocks.first! as Map)['type'], 'text');
      final toolUse = assistantBlocks[1]! as Map;
      expect(toolUse['type'], 'tool_use');
      expect(toolUse['id'], 'toolu_1');
      expect(toolUse['input'], {'x': 1});

      // 两条连续 tool_result 合并进同一 user 消息
      final resultBlocks = (messages[2]! as Map)['content']! as List<Object?>;
      expect(resultBlocks, hasLength(2));
      expect((resultBlocks[1]! as Map)['is_error'], true);

      expect(body['max_tokens'], AnthropicChatClient.defaultMaxTokens);
      expect(body.containsKey('temperature'), isFalse);
      expect(body['stream'], true);
    });

    test('maxTokens 覆盖缺省；温度透传', () {
      final body = buildAnthropicBody(
        const CloudChatRequest(messages: [UserMessage('u')], temperature: 0.7, maxTokens: 256),
        model: 'm',
      );
      expect(body['max_tokens'], 256);
      expect(body['temperature'], 0.7);
    });

    test('空 assistant 消息（无文本无工具）→ CloudProtocolException', () {
      expect(
        () => buildAnthropicBody(
          const CloudChatRequest(messages: [AssistantMessage()]),
          model: 'm',
        ),
        throwsA(isA<CloudProtocolException>()),
      );
    });
  });

  group('mapAnthropicSse', () {
    Stream<CloudStreamEvent> map(String raw) =>
        mapAnthropicSse(parseSse(Stream.value(raw)));

    test('text_delta 与 tool_use 流分离 + stop_reason 归一', () async {
      final events = await map(
        'event: message_start\n'
        'data: {"type":"message_start","message":{"role":"assistant"}}\n\n'
        'event: content_block_start\n'
        'data: {"type":"content_block_start","index":0,'
        '"content_block":{"type":"text"}}\n\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":0,'
        '"delta":{"type":"text_delta","text":"你"}}\n\n'
        'event: content_block_start\n'
        'data: {"type":"content_block_start","index":1,'
        '"content_block":{"type":"tool_use","id":"toolu_1","name":"f"}}\n\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":1,'
        '"delta":{"type":"input_json_delta","partial_json":"{\\"x\\":"}}\n\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":1,'
        '"delta":{"type":"input_json_delta","partial_json":"1}"}}\n\n'
        'event: message_delta\n'
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}\n\n'
        'event: message_stop\n'
        'data: {"type":"message_stop"}\n\n',
      ).toList();
      expect(
        events.whereType<CloudTextDelta>().map((e) => e.text).join(),
        '你',
      );
      final deltas = events.whereType<CloudToolCallDelta>().toList();
      expect(deltas, hasLength(3));
      expect(deltas[0].index, 1);
      expect(deltas[0].id, 'toolu_1');
      expect(deltas[0].name, 'f');
      expect(deltas[1].argumentsDelta, '{"x":');
      expect(deltas[2].argumentsDelta, '1}');
      expect(events.whereType<CloudDone>().single.finishReason,
          CloudFinishReason.toolCalls);
    });

    test('stop_reason 归一：end_turn→stop，max_tokens→length', () async {
      final cases = {
        'end_turn': CloudFinishReason.stop,
        'stop_sequence': CloudFinishReason.stop,
        'max_tokens': CloudFinishReason.length,
      };
      for (final entry in cases.entries) {
        final events = await map(
          'event: message_delta\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"${entry.key}"}}\n\n',
        ).toList();
        expect(events.whereType<CloudDone>().single.finishReason, entry.value);
      }
    });

    test('event: error → CloudHttpException', () async {
      await expectLater(
        map('event: error\n'
                'data: {"type":"error","error":{"type":"overloaded_error",'
                '"message":"Overloaded"}}\n\n')
            .toList(),
        throwsA(isA<CloudHttpException>()),
      );
    });

    test('流终止未见 stop_reason → CloudProtocolException', () async {
      await expectLater(
        map('event: content_block_delta\n'
                'data: {"type":"content_block_delta","index":0,'
                '"delta":{"type":"text_delta","text":"x"}}\n\n')
            .toList(),
        throwsA(isA<CloudProtocolException>()),
      );
    });

    test('端到端：URL/协议头/事件产出（MockClient.streaming）', () async {
      http.BaseRequest? captured;
      final client = MockClient.streaming((req, _) async {
        captured = req;
        return http.StreamedResponse(
          Stream.fromIterable([
            utf8.encode(
              'event: content_block_delta\n'
              'data: {"type":"content_block_delta","index":0,'
              '"delta":{"type":"text_delta","text":"hi"}}\n\n'
              'event: message_delta\n'
              'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n',
            ),
          ]),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final engine = AnthropicChatClient(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'ak-test',
        model: 'claude-m',
        httpClient: client,
      );
      final acc = await CloudStreamAccumulator.drain(
        engine.send(const CloudChatRequest(messages: [UserMessage('hi')])),
      );
      expect(captured!.url.toString(), 'https://api.example.com/v1/messages');
      expect(captured!.headers['x-api-key'], 'ak-test');
      expect(captured!.headers['anthropic-version'], '2023-06-01');
      expect(acc.text, 'hi');
      expect(acc.finishReason, CloudFinishReason.stop);
    });
  });
}
