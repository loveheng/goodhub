import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/cloud_llm_error.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/llm/cloud/anthropic_chat_client.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/cloud/openai_chat_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ByokStore store;
  late InMemorySecureKeyValue secure;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = InMemorySecureKeyValue();
    store = ByokStore(secure: secure);
  });

  const profile = ByokProfile(
    id: 'p1',
    name: 'OpenAI 主力',
    protocol: CloudProtocol.openaiCompatible,
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-test',
    temperature: 0.2,
  );

  test('profile 全量存取 round-trip', () async {
    await store.save([profile]);
    final loaded = await store.load();
    expect(loaded.single.toJson(), profile.toJson());
  });

  test('坏条目跳过不拖垮整表', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_byok_profiles':
          '[{"id":"ok","name":"n","protocol":"openaiCompatible",'
          '"baseUrl":"https://x/v1","model":"m"}, {"id":"bad"}, '
          '"not-a-map", {"id":"ok2","name":"n2","protocol":"unknown-proto",'
          '"baseUrl":"https://x/v1","model":"m"}]',
    });
    final list = await store.load();
    expect(list.map((p) => p.id), ['ok']);
  });

  test('密钥走 SecureKeyValue，profile 不落密钥', () async {
    await store.save([profile]);
    await store.setApiKey('p1', 'sk-secret');
    expect(await store.apiKey('p1'), 'sk-secret');
    expect(
      (await SharedPreferences.getInstance()).getString('cloud_byok_profiles')!,
      isNot(contains('sk-secret')),
    );
    await store.deleteApiKey('p1');
    expect(await store.apiKey('p1'), isNull);
  });

  test('save 移除 profile 时连带清理残留密钥（防孤儿密钥）', () async {
    await store.save([profile]);
    await store.setApiKey('p1', 'sk-old');
    await store.save([]);
    expect(await secure.read('cloud_byok_key.p1'), isNull);
  });

  test('fromJson 缺字段抛 FormatException（调用方跳过坏条目）', () {
    expect(
      () => ByokProfile.fromJson({'id': 'x'}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ByokProfile.fromJson({
        'id': 'x', 'name': 'n', 'protocol': 'nope',
        'baseUrl': 'https://x/v1', 'model': 'm',
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('engineFor 按协议路由实现', () {
    expect(
      engineFor(profile, apiKey: 'k'),
      isA<OpenAiChatClient>(),
    );
    expect(
      engineFor(
        const ByokProfile(
          id: 'p2',
          name: 'Claude',
          protocol: CloudProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com/v1',
          model: 'claude-test',
        ),
        apiKey: 'k',
      ),
      isA<AnthropicChatClient>(),
    );
  });

  test('CloudLlmException 为 sealed 基类（错误域分层冒烟）', () {
    expect(const CloudNetworkException('x'), isA<CloudLlmException>());
    expect(const CloudHttpException('x', statusCode: 500), isA<CloudLlmException>());
    expect(const CloudProtocolException('x'), isA<CloudLlmException>());
  });
}
