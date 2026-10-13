/// 本地插件信任白名单持久化（thirdconnect §1.2.6）：第三方（非同签名）本地插件首次
/// 接入需经信任卡片确认，确认后包名入白名单（持久化），再次发现即自动信任。
///
/// 同签名私有生态（[LocalPluginInfo.sameSignature]）默认零弹窗自动信任，不走此白名单。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 信任白名单（持久化于 SharedPreferences）。
class TrustedPlugins {
  TrustedPlugins._(this._prefs);

  static const String _key = 'goodhub.trusted_plugins';

  final SharedPreferences _prefs;
  static TrustedPlugins? _instance;

  /// 进程级单例（首次 await 触发 SharedPreferences 加载）。
  static Future<TrustedPlugins> get instance async =>
      _instance ??= TrustedPlugins._(await SharedPreferences.getInstance());

  Map<String, Object?> _map() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      // 必须返回可变副本：add/remove 对返回值原地变更，const/共享 map 会抛
      // UnsupportedError（白名单为空时首次信任第三方插件即崩，e2e 绕闸门未踩到）。
      return decoded is Map<String, Object?>
          ? Map<String, Object?>.of(decoded)
          : <String, Object?>{};
    } on Object {
      return <String, Object?>{};
    }
  }

  Future<void> _save(Map<String, Object?> m) =>
      _prefs.setString(_key, jsonEncode(m));

  /// 是否已信任该包名。
  bool isTrusted(String packageName) => _map().containsKey(packageName);

  /// 加入白名单（记录指纹/展示名/时间，便于审计与撤销）。
  Future<void> add(String packageName, String sha256, String title) async {
    final m = _map();
    m[packageName] = <String, Object?>{
      'sha256': sha256,
      'title': title,
      'at': DateTime.now().toIso8601String(),
    };
    await _save(m);
  }

  /// 撤销信任。
  Future<void> remove(String packageName) async {
    final m = _map();
    m.remove(packageName);
    await _save(m);
  }

  /// 全量白名单（包名 → 元数据）。
  Map<String, Object?> all() => _map();
}
