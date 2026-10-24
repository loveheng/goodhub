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
import '../core/storage/keyed_write_queue.dart';

/// 隐私分层（chatmessage epic P1-1，SSOT §1.4）：外部服务仅有 `private` /
/// `public` 两档——`host`（宿主内置能力）不进 [ServerEndpoint]，由客户端以
/// `HostNativeTools` 注入（Provider×Tier 两维解耦，D-A/D-B）。
enum ServerPrivacyTier { private, public }

class ServerEndpoint {
  const ServerEndpoint({
    required this.id,
    required this.name,
    required this.endpoint,
    this.hasKey = false,
    this.enabled = true,
    this.tier = ServerPrivacyTier.private,
    this.isDefault = false,
    this.ephemeralKey,
  });

  /// 稳定标识（安全存储键锚点；不含 `__`——ToolRouter 前缀语义约束）。
  final String id;

  /// 展示名（侧边栏/大厅/摘要）。
  final String name;

  /// MCP Endpoint（须含 /mcp 路径）。
  final String endpoint;

  /// 安全存储中是否已有令牌（真值经 [ServerEndpointStore.apiKey] 读取）。
  final bool hasKey;

  /// 挂载位（M4-T5 节点卡开关，ui-design §3.3）：false = 卸载态——`_send`
  /// 装配连接池时跳过；配置与令牌保留，重开开关即恢复挂载。旧 JSON 缺省 true。
  final bool enabled;

  /// 隐私分层（固有属性，与 [enabled] 运行时挂载态正交）：仅外部服务可配，
  /// 缺省兜底 `private`（沉默即安全）。`host` 不在本模型（D-A）。
  final ServerPrivacyTier tier;

  /// 全局默认钉选（v1：会话绑定默认回退用）：单选语义，写回 mcp_servers.json。
  final bool isDefault;

  /// ephemeral 任务侧端点的明文键（window-kernel-split 步 2-3，§8.1-9 凭证
  /// 隔离）：**只入内存，不序列化**——[toJson] 不含此字段，[fromJson] 不还原；
  /// ephemeral 端点不进 Directory 列表、不参与 [ServerEndpointStore.save]。
  final String? ephemeralKey;

  /// 任务侧一次性端点（§8.1-9）：凭证只入内存，与用户服务目录完全隔离。
  const ServerEndpoint.ephemeral({
    required String endpoint,
    String? ephemeralKey,
  }) : this(
          id: 'ephemeral',
          name: 'ephemeral',
          endpoint: endpoint,
          ephemeralKey: ephemeralKey,
        );

  ServerEndpoint copyWith({
    String? name,
    String? endpoint,
    bool? hasKey,
    bool? enabled,
    ServerPrivacyTier? tier,
    bool? isDefault,
    String? ephemeralKey,
  }) =>
      ServerEndpoint(
        id: id,
        name: name ?? this.name,
        endpoint: endpoint ?? this.endpoint,
        hasKey: hasKey ?? this.hasKey,
        enabled: enabled ?? this.enabled,
        tier: tier ?? this.tier,
        isDefault: isDefault ?? this.isDefault,
        ephemeralKey: ephemeralKey ?? this.ephemeralKey,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        // ephemeralKey 有意排除：明文凭证不落盘（§8.1-9）。
        'id': id,
        'name': name,
        'endpoint': endpoint,
        'hasKey': hasKey,
        'enabled': enabled,
        'tier': tier.name,
        'isDefault': isDefault,
      };

  static ServerEndpoint fromJson(Map<String, Object?> j) => ServerEndpoint(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        endpoint: j['endpoint'] as String? ?? '',
        hasKey: j['hasKey'] as bool? ?? false,
        enabled: j['enabled'] as bool? ?? true,
        // 缺字段 / 非法值一律兜底 private（沉默即安全，不抛）。
        tier: ServerPrivacyTier.values.firstWhere(
          (t) => t.name == j['tier'],
          orElse: () => ServerPrivacyTier.private,
        ),
        isDefault: j['isDefault'] as bool? ?? false,
      );
}

class ServerEndpointStore {
  ServerEndpointStore({
    required this.file,
    SecureKeyValue? secure,
    SharedPreferencesLike? prefs,
  })  : _secure = secure ?? FlutterSecureKeyValue(),
        // ignore: prefer_initializing_formals
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

  Future<void> save(List<ServerEndpoint> endpoints) =>
      // window-slim P1-D：裸 tmp→rename 在并发 save 下交错（A.tmp 写一半被 B
      // rename）→ 接进程级 keyed 写队列串行化（P0-A 底座，键=配置文件绝对路径）。
      KeyedWriteQueue.instance.enqueue(KeyedWriteQueue.keyForPath(file.path),
          () async {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert([
            for (final e in endpoints) e.toJson(),
          ]),
          flush: true,
        );
        await tmp.rename(file.path);
      });

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
        // D-B：goodshare 非宿主——普通外部端点，常驻可混用。
        tier: ServerPrivacyTier.public,
      ),
    ];
    await save(migrated);
    // F12（review-fix-2026-10）：迁移成功即清理旧**明文 apiKey**（endpoint 键
    // 非机密保留回滚；密钥残留 = 本地取证即得，违反 §6.3 零明文留痕）。
    // remove 抛错不阻断迁移主链（下次启动重试清理）。
    try {
      await prefs.remove(_legacyApiKeyKey);
    } on Object catch (e) {
      debugPrint('[DEGRADE] server-endpoints: 旧明文密钥清理失败（下次重试）: $e');
    }
    debugPrint('[DEGRADE] server-endpoints: 旧单端点配置已迁移'
        '（endpoint=$endpoint，明文密钥已清理）');
    return migrated;
  }
}

/// SharedPreferences 的最小读取面（避免 sandbox/mcp 层直依插件；生产装配在
/// [flutterPrefsLike] 转接）。[remove] = 迁移后清理明文残留（F12）。
abstract interface class SharedPreferencesLike {
  Future<String?> read(String key);

  Future<void> remove(String key);
}

/// 生产转接：SharedPreferences（async get/remove）→ [SharedPreferencesLike]。
SharedPreferencesLike flutterPrefsLike(
  Future<String?> Function(String key) getter,
  Future<void> Function(String key) remover,
) =>
    _FnPrefsLike(getter, remover);

class _FnPrefsLike implements SharedPreferencesLike {
  _FnPrefsLike(this._get, this._remove);

  final Future<String?> Function(String key) _get;
  final Future<void> Function(String key) _remove;

  @override
  Future<String?> read(String key) => _get(key);

  @override
  Future<void> remove(String key) => _remove(key);
}
