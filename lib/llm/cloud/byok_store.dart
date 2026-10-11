/// BYOK 配置仓（M2-T1）：profile 明文（SharedPreferences）与 API Key（系统安全存储）分离。
///
/// 密钥纪律（architecture §1）：Key 一律走 [SecureKeyValue]（Android =
/// EncryptedSharedPreferences/Keystore），严禁明文落盘与入 context/docs。
/// profile 列表（不含 Key）持久化于 SharedPreferences `cloud_byok_profiles`。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/security/flutter_secure_key_value.dart';
import '../../core/security/secure_key_value.dart';
import 'anthropic_chat_client.dart';
import 'cloud_llm.dart';
import 'openai_chat_client.dart';

/// 单个 BYOK 模型接入配置（不含密钥）。
class ByokProfile {
  const ByokProfile({
    required this.id,
    required this.name,
    required this.protocol,
    required this.baseUrl,
    required this.model,
    this.temperature,
  });

  /// 稳定标识（UUID 等，由调用方生成）；密钥存储按此寻址。
  final String id;

  /// 显示名（服务大厅模型配置面板用）。
  final String name;
  final CloudProtocol protocol;
  final String baseUrl;
  final String model;
  final double? temperature;

  factory ByokProfile.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final baseUrl = json['baseUrl'];
    final model = json['model'];
    final protocol = json['protocol'];
    if (id is! String || id.isEmpty) throw const FormatException('id 缺失');
    if (name is! String || name.isEmpty) throw const FormatException('name 缺失');
    if (baseUrl is! String || baseUrl.isEmpty) {
      throw const FormatException('baseUrl 缺失');
    }
    if (model is! String || model.isEmpty) throw const FormatException('model 缺失');
    if (protocol is! String) throw const FormatException('protocol 缺失');
    final temp = json['temperature'];
    return ByokProfile(
      id: id,
      name: name,
      protocol: CloudProtocol.values.firstWhere(
        (p) => p.name == protocol,
        orElse: () => throw FormatException('protocol 未知: \$protocol'),
      ),
      baseUrl: baseUrl,
      model: model,
      temperature: temp is num ? temp.toDouble() : null,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'baseUrl': baseUrl,
        'model': model,
        if (temperature != null) 'temperature': temperature,
      };
}

/// BYOK 配置仓：profile 列表 + 密钥读写 + 删除时密钥连带清理。
class ByokStore {
  ByokStore({SecureKeyValue? secure})
      : _secure = secure ?? FlutterSecureKeyValue();

  static const _profilesPref = 'cloud_byok_profiles';
  static String _keyFor(String id) => 'cloud_byok_key.$id';

  final SecureKeyValue _secure;

  /// 读 profile 列表；坏条目跳过不拖垮整表（外部输入防御，同 LlmModel 口径）。
  Future<List<ByokProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesPref);
    if (raw == null || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final out = <ByokProfile>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      try {
        out.add(ByokProfile.fromJson(e.cast<String, Object?>()));
      } on FormatException {
        // 单条损坏跳过：不能让一条坏数据毁掉整个配置表
      }
    }
    return out;
  }

  /// 全量保存 profile 列表；被移除 profile 的密钥连带删除（防孤儿密钥滞留安全存储）。
  Future<void> save(List<ByokProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final knownIds = profiles.map((p) => p.id).toSet();
    final previousIds = (await load()).map((p) => p.id).toSet();
    await prefs.setString(
      _profilesPref,
      jsonEncode([for (final p in profiles) p.toJson()]),
    );
    for (final stale in previousIds.difference(knownIds)) {
      await _secure.delete(_keyFor(stale));
    }
  }

  Future<String?> apiKey(String profileId) => _secure.read(_keyFor(profileId));

  /// 写/换密钥（明文仅经过内存与安全存储，禁入日志/文档）。
  Future<void> setApiKey(String profileId, String key) =>
      _secure.write(_keyFor(profileId), key);

  Future<void> deleteApiKey(String profileId) =>
      _secure.delete(_keyFor(profileId));
}

/// 按 profile 协议路由组装云端引擎（T2 coordinator 的装配入口）。
/// [apiKey] 由调用方经 [ByokStore.apiKey] 预取——本函数不触碰安全存储，保持纯装配。
CloudLlmEngine engineFor(
  ByokProfile profile, {
  required String apiKey,
  http.Client? httpClient,
  Duration? connectTimeout,
}) {
  final timeout = connectTimeout ?? const Duration(seconds: 10);
  return switch (profile.protocol) {
    CloudProtocol.openaiCompatible => OpenAiChatClient(
        baseUrl: profile.baseUrl,
        apiKey: apiKey,
        model: profile.model,
        temperature: profile.temperature,
        httpClient: httpClient,
        connectTimeout: timeout,
      ),
    CloudProtocol.anthropic => AnthropicChatClient(
        baseUrl: profile.baseUrl,
        apiKey: apiKey,
        model: profile.model,
        temperature: profile.temperature,
        httpClient: httpClient,
        connectTimeout: timeout,
      ),
  };
}
