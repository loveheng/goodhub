import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 远程配置的本地缓存（M2 自 goodshare 随迁的精简版，2026-10-10）：
/// goodhub 只消费 flags 热更（llm_manifest_url 等），自更新 manifest /
/// 公告 / 口号段属 goodshare 自更新体系，不随迁。
/// 启动时读缓存，检查更新成功后写缓存。
class RemoteConfigStore {
  RemoteConfigStore._();

  static final RemoteConfigStore instance = RemoteConfigStore._();

  RemoteConfig current = RemoteConfig.empty;

  /// [dir] 供测试注入。
  Future<void> load({Directory? dir}) async {
    try {
      final file = await _cacheFile(dir);
      if (!await file.exists()) return;
      current = RemoteConfig.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, Object?>,
      );
    } catch (_) {
      // 缓存损坏时回到空配置，等下次检查更新重建
      current = RemoteConfig.empty;
    }
  }

  Future<void> save(RemoteConfig config, {Directory? dir}) async {
    current = config;
    final file = await _cacheFile(dir);
    await file.writeAsString(jsonEncode({
      if (config.flags.isNotEmpty) 'flags': config.flags,
    }));
  }

  Future<File> _cacheFile(Directory? dir) async {
    final base = dir?.path ?? (await getApplicationDocumentsDirectory()).path;
    return File('$base/remote_config.json');
  }
}

/// 远程下发的功能配置（flags 段；goodhub 仅用 flags）。
class RemoteConfig {
  const RemoteConfig({this.flags = const {}});

  factory RemoteConfig.fromJson(Map<String, Object?> json) => RemoteConfig(
        flags: (json['flags'] as Map?)?.cast<String, Object?>() ?? const {},
      );

  static const empty = RemoteConfig();

  final Map<String, Object?> flags;
}
