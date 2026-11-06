import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/cloud/anthropic_chat_client.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/cloud/openai_chat_client.dart';

/// 多 Provider 缓存能力标记（SSOT §9.4）：语义钉——Anthropic 显式打点、
/// OpenAI/DeepSeek 仅确定性前缀、Gemini 不并入（无该接口）。
void main() {
  test('Anthropic：supportsExplicitEphemeralCache=true / prefixOnly=false', () {
    final CloudLlmEngine c = AnthropicChatClient(
        baseUrl: 'https://api.anthropic.com', apiKey: 'k', model: 'm');
    expect(c, isA<ProviderCacheCapability>());
    final cap = c as ProviderCacheCapability;
    expect(cap.supportsExplicitEphemeralCache, isTrue);
    expect(cap.requiresDeterministicPrefixOnly, isFalse);
  });

  test('OpenAI：supportsExplicitEphemeralCache=false / prefixOnly=true', () {
    final CloudLlmEngine c = OpenAiChatClient(
        baseUrl: 'https://api.openai.com', apiKey: 'k', model: 'm');
    expect(c, isA<ProviderCacheCapability>());
    final cap = c as ProviderCacheCapability;
    expect(cap.supportsExplicitEphemeralCache, isFalse);
    expect(cap.requiresDeterministicPrefixOnly, isTrue);
  });
}
