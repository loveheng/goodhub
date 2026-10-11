/// MCP 服务端点目录（M4-T6-1，F1.1 多 Server 挂载的配置面）。
///
/// - **密钥纪律（F1.12）**：endpoint/name 等非敏感字段 JSON 文件；**apiKey 走
///   [SecureKeyValue]**（Android = EncryptedSharedPreferences/Keystore），
///   严禁明文落盘——文件里只存 `hasKey` 布尔（UI 展示「已存令牌」）；
/// - **旧配置迁移**：T3 及以前为单端点 SharedPreferences（`chat.mcp.*` 键）——
///   [load] 时文件缺失且旧键在位 → 迁移为一条记录（id='goodshare'，沿用旧
///   令牌写安全存储），旧键保留不删（回滚无损，双写一个版本期）；
/// - 损坏文件：返空目录 + DEGRADE 留痕（配置面宁空勿炸，用户可重新添加）；
/// - id 稳定性：创建时生成（`srv_<epoch>`），改名/改端点不换 id——安全存储
///   键以其为锚。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/security/flutter_secure_key_value.dart';
import '../core/security/secure_key_value.dart';

class ServerEndpoint {
  const ServerEndpoint({
    required this.id,
    required this.name,
    required this.endpoint,
    this.hasKey = false,
  });

  /// 稳定标识（安全存储键锚点；不含 `__`——ToolRouter 前缀语义约束）。
  final String id;

  /// 展示名（侧边栏/大厅/摘要）。
  final String name;

  /// MCP Endpoint（须含 /mcp 路径）。
  final String endpoint;

  /// 安全存储中是否已有令牌（真值经 [ServerEndpointStore.apiKey] 读取）。
  final bool hasKey;

  ServerEndpoint copyWith({String? name, String? endpoint, bool? hasKey}) =>
      ServerEndpoint(
        id: id,
        name: name ?? this.name,
        endpoint: endpoint ?? this.endpoint,
        hasKey: hasKey ?? this.hasKey,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'endpoint': endpoint,
        'hasKey': hasKey,
      };

  static ServerEndpoint fromJson(Map<String, Object?> j) => ServerEndpoint(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        endpoint: j['endpoint'] as String? ?? '',
        hasKey: j['hasKey'] as bool? ?? false,
      );
}

class ServerEndpointStore {
  ServerEndpointStore({
    required this.file,
    SecureKeyValue? secure,
    SharedPreferencesLike? prefs,
  })  : _secure = secure ?? FlutterSecureKeyValue(),
        _prefs = prefs;

  /// 非敏感配置文件（注入：生产 = 应用支持目录/mcp_servers.json）。
  final File file;

  final SecureKeyValue _secure;

  /// 旧单端点 SharedPreferences 读取口（迁移用；测试注入假件，生产缺省 =
  /// FlutterSharedPreferences 适配，见 [flutterPrefsLike]）。
  final SharedPreferencesLike? _prefs;

  static const _keyPrefix = 'mcpserver.key.';

  /// 旧版单端点键（T3 及以前，chat_page 写入）。
  static const _legacyEndpointKey = 'chat.mcp.endpoint';
  static const _legacyApiKeyKey = 'chat.mcp.apiKey';
  static const _legacyId = 'goodshare';

  Future<List<ServerEndpoint>> load() async {
    if (!await file.exists()) {
      final migrated = await _migrateLegacyIfNeeded();
      return migrated;
    }
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! List) throw const FormatException('root is not a list');
      final out = <ServerEndpoint>[];
      for (final e in data) {
        if (e is! Map) continue;
        final endpoint = ServerEndpoint.fromJson(Map<String, Object?>.from(e));
        if (endpoint.id.isNotEmpty && endpoint.endpoint.isNotEmpty) {
          out.add(endpoint);
        }
      }
      return out;
    } on Object catch (err) {
      debugPrint('[DEGRADE] server-endpoints: 配置文件损坏按空目录: $err');
      return [];
    }
  }

  Future<void> save(List<ServerEndpoint> endpoints) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert([
        for (final e in endpoints) e.toJson(),
      ]),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  Future<String?> apiKey(String id) => _secure.read('$_keyPrefix$id');

  Future<void> setApiKey(String id, String? key) async {
    if (key == null || key.isEmpty) {
      await _secure.delete('$_keyPrefix$id');
      return;
    }
    await _secure.write('$_keyPrefix$id', key);
  }

  /// 旧单端点迁移（文件缺失且旧键在位才走一次；旧键保留不删，回滚无损）。
  Future<List<ServerEndpoint>> _migrateLegacyIfNeeded() async {
    final prefs = _prefs;
    if (prefs == null) return [];
    final endpoint = await prefs.read(_legacyEndpointKey);
    if (endpoint == null || endpoint.isEmpty) return [];
    final key = await prefs.read(_legacyApiKeyKey);
    if (key != null && key.isNotEmpty) {
      await setApiKey(_legacyId, key);
    }
    final migrated = [
      ServerEndpoint(
        id: _legacyId,
        name: 'goodshare',
        endpoint: endpoint,
        hasKey: key != null && key.isNotEmpty,
      ),
    ];
    await save(migrated);
    debugPrint('[DEGRADE] server-endpoints: 旧单端点配置已迁移'
        '（endpoint=$endpoint，旧键保留）');
    return migrated;
  }
}

/// SharedPreferences 的最小读取面（避免 sandbox/mcp 层直依插件；生产装配在
/// [flutterPrefsLike] 转接）。
abstract interface class SharedPreferencesLike {
  Future<String?> read(String key);
}

/// 生产转接：SharedPreferences（async get）→ [SharedPreferencesLike]。
SharedPreferencesLike flutterPrefsLike(
        Future<String?> Function(String key) getter) =>
    _FnPrefsLike(getter);

class _FnPrefsLike implements SharedPreferencesLike {
  _FnPrefsLike(this._get);

  final Future<String?> Function(String key) _get;

  @override
  Future<String?> read(String key) => _get(key);
}
