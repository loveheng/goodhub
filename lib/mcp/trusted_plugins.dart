/// 本地插件信任白名单持久化（thirdconnect §1.2.6）：第三方（非同签名）本地插件首次
/// 接入需经信任卡片确认，确认后包名入白名单（持久化），再次发现即自动信任。
///
/// 同签名私有生态（[LocalPluginInfo.sameSignature]）默认零弹窗自动信任，不走此白名单。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// 信任白名单（持久化于 SharedPreferences）。
/// 插件信任闸门——**装配期的只读面**（2026-10-17 P0-B 引入）。
///
/// 同 [LocalPluginSource] 的引入理由：`TrustedPlugins` 私有构造且绑
/// SharedPreferences，装配侧直依赖它即无法注入预设白名单（债 #14）。
abstract interface class PluginTrustGate {
  /// 该包名是否已入信任白名单（F13：可携签名指纹做一致性复核）。
  bool isTrusted(String packageName, {String signatureSha256 = ''});
}

class TrustedPlugins implements PluginTrustGate {
  TrustedPlugins._(this._prefs);

  static const String _key = 'goodhub.trusted_plugins';

  final SharedPreferences _prefs;
  static TrustedPlugins? _instance;

  /// 进程级单例。F7（review-fix-2026-10）：缓存 **Future** 而非在 `??=` 右侧
  /// await——`await` 会让两个并发首访各自建实例（`??=` 跨 await 非原子），
  /// 双实例各持读写序列，白名单互覆写；future 缓存天然并发去重。
  static Future<TrustedPlugins>? _instanceFuture;
  static Future<TrustedPlugins> get instance =>
      _instanceFuture ??= SharedPreferences.getInstance()
          .then((p) => _instance ??= TrustedPlugins._(p));

  /// 测试卫生：清进程级单例缓存。SharedPreferences 的 mock store 每用例重建，
  /// 静态 future 缓存跨用例持旧视图（读到旧 cache 即跨用例串数据）；生产禁用。
  @visibleForTesting
  static void resetForTest() {
    _instance = null;
    _instanceFuture = null;
  }

  /// 写串行队列（F7）：add/remove 是「同步读内存 → 异步落盘」的复合读改写，
  /// 并发交错后写覆盖前写——最坏情形 remove（撤销 A）被 add(B) 的旧快照复活
  /// = 信任撤销静默失效。对齐 §3.2「复合读改写单元必须串行」。
  Future<void> _writes = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final run = _writes.then((_) => op());
    // 队列尾不吞业务异常（失败不毒化队列，续链照常）。
    _writes = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

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

  /// 是否已信任。F13（review-fix-2026-10）：包名命中后还须**签名指纹一致**——
  /// 此前只查包名（记录的 sha256 无任何消费点），原插件卸载后同包名异签名的
  /// 恶意 App 可冒名免信任卡直接挂载。指纹不匹配 / 记录缺指纹 = 不信任（走
  /// 信任卡重新确认）；[signatureSha256] 为空 = 调用方无指纹数据，维持包名
  /// 口径（渐进迁移，不阻断无指纹扫描面）。
  @override
  bool isTrusted(String packageName, {String signatureSha256 = ''}) {
    final entry = _map()[packageName];
    if (entry == null) return false;
    if (signatureSha256.isEmpty) return true;
    if (entry is! Map) return false;
    final recorded = entry['sha256'];
    return recorded is String && recorded == signatureSha256;
  }

  /// 加入白名单（记录指纹/展示名/时间，便于审计与撤销）。F7：整段读改写经
  /// 写队列串行（见 [_serialized]）。
  Future<void> add(String packageName, String sha256, String title) =>
      _serialized(() async {
        final m = _map();
        m[packageName] = <String, Object?>{
          'sha256': sha256,
          'title': title,
          'at': DateTime.now().toIso8601String(),
        };
        await _save(m);
      });

  /// 撤销信任。F7：与 add 同队列串行——并发撤销不被旧快照复活。
  Future<void> remove(String packageName) => _serialized(() async {
        final m = _map();
        m.remove(packageName);
        await _save(m);
      });

  /// 全量白名单（包名 → 元数据）。
  Map<String, Object?> all() => _map();
}
