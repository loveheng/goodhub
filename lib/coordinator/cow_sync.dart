/// CoW 继承同步（M2.5-T6）：goodshare prompts 模板 → 宿主 appScoped Skill
/// 的出厂继承管道。规格 SSOT：architecture.md §3（CoW 合并策略）+
/// ai-app-split.md §3.7（template_version / min_hub_version）。
///
/// - **来源收敛**：Skill 来源三分支之一（官方预置 + CoW 同步 + 用户编辑）——
///   同步产物以 `cow/<name>` 注册进 SkillRegistry（name 唯一闸天然防撞）；
/// - **CoW 合并策略（评审部分采纳）**：本地覆写副本最高优先级；`min_hub_version`
///   兼容闸（宿主版本低于声明 → 跳过不导入）；`template_version` **大版本
///   （major）跃迁 → 强制告警**（用户选重置/保留）；否决三路合并引擎；
/// - **一键重置**：删本地副本 → 下次同步回 server 版（[CowOverridesStore.reset]）；
/// - 持久化：JSON 文件（应用文档目录——覆写是持久数据，不进 cacheDir）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/errors/mcp_error.dart';
import '../mcp/mcp_client.dart';
import 'skill_registry.dart';

/// 宿主版本（min_hub_version 兼容闸与 clientInfo 共用）。
const kHostVersion = '0.1.0';

/// 语义化版本比较：a<b → -1，a>b → 1，相等 0。非数字段按 0 处理（防御）。
int compareVersions(String a, String b) {
  int seg(String s, int i) =>
      int.tryParse(s.split('.').length > i ? s.split('.')[i] : '') ?? 0;
  for (var i = 0; i < 3; i++) {
    final ca = seg(a, i);
    final cb = seg(b, i);
    if (ca != cb) return ca.compareTo(cb);
  }
  return 0;
}

/// 大版本（major）跃迁判定——CoW 强制告警触发条件（评审口径：仅 major，
/// minor/patch 静默）。
bool isMajorJump(String from, String to) =>
    compareVersions(to, from) > 0 && seg0(to) > seg0(from);

int seg0(String v) => int.tryParse(v.split('.').first) ?? 0;

/// 本地覆写副本 + 已知版本基线（持久化）。
class CowOverridesStore {
  CowOverridesStore({required this.dir, this.fileName = 'cow_overrides.json'});

  final Directory dir;
  final String fileName;

  Map<String, Object?> _cache = const {};
  bool _loaded = false;

  File get _file => File('${dir.path}/$fileName');

  Future<Map<String, Object?>> _load() async {
    if (_loaded) return _cache;
    _loaded = true;
    try {
      if (await _file.exists()) {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map) {
          _cache = {for (final e in decoded.entries) '${e.key}': e.value};
        }
      }
    } catch (e) {
      // DEGRADE: 覆写文件损坏（手改/写坏）——按空库起步并重写，不阻断同步；留痕。
      debugPrint('[DEGRADE] cow-store: overrides file unreadable, starting fresh: $e');
      _cache = {};
    }
    return _cache;
  }

  Future<void> _save() async {
    await dir.create(recursive: true);
    await _file.writeAsString(jsonEncode(_cache), flush: true);
  }

  Map<String, Object?>? _section(String key) {
    // jsonDecode 嵌套段是 Map<String, dynamic>，泛型不变——显式转换后供读取
    final v = _cache[key];
    return v is Map ? {for (final e in v.entries) '${e.key}': e.value} : null;
  }

  /// 本地覆写副本（content 为覆写后正文；null = 无覆写）。
  Future<String?> overrideOf(String promptName) async {
    await _load();
    final o = _section('overrides');
    final e = o?[promptName];
    if (e is Map) {
      final m = {for (final x in e.entries) '${x.key}': x.value};
      if (m['content'] is String) return m['content'] as String;
    }
    return null;
  }

  Future<void> setOverride(String promptName, String content) async {
    await _load();
    final o = Map<String, Object?>.of(_section('overrides') ?? const {});
    o[promptName] = {
      'content': content,
      'overridden_at': DateTime.now().toIso8601String(),
    };
    _cache = {..._cache, 'overrides': o};
    await _save();
  }

  /// 上次同步见过的 server 版本（major 跃迁检测基线）。
  Future<String?> knownVersion(String promptName) async {
    await _load();
    final k = _section('known_versions');
    final v = k?[promptName];
    return v is String ? v : null;
  }

  Future<void> setKnownVersion(String promptName, String version) async {
    await _load();
    final k = Map<String, Object?>.of(_section('known_versions') ?? const {});
    k[promptName] = version;
    _cache = {..._cache, 'known_versions': k};
    await _save();
  }

  /// 一键重置：删本地副本 → 下次同步回 server 版。
  Future<void> reset(String promptName) async {
    await _load();
    final o = Map<String, Object?>.of(_section('overrides') ?? const {});
    o.remove(promptName);
    _cache = {..._cache, 'overrides': o};
    await _save();
  }

  /// 覆写名单（M3-T4 编辑面）：覆写段键集（无覆写为空表，升序）。
  /// 注意级联不可挂在三元表达式上——`cond ? const [] : list..sort()` 的
  /// `..sort()` 会作用于整个表达式（空表分支对 const 列表排序即抛）。
  Future<List<String>> overrideNames() async {
    await _load();
    final o = _section('overrides');
    if (o == null) return const [];
    final names = o.keys.toList()..sort();
    return names;
  }

  /// 覆写时间（M3-T4 编辑面展示；无记录 null）。
  Future<DateTime?> overriddenAt(String promptName) async {
    await _load();
    final o = _section('overrides')?[promptName];
    if (o is Map) {
      final m = {for (final x in o.entries) '${x.key}': x.value};
      final v = m['overridden_at'];
      if (v is String) return DateTime.tryParse(v);
    }
    return null;
  }
}

/// 单条同步结果（debug 轨迹与联调观测）。
enum CowSyncAction { imported, keptLocal, resetToServer, skippedIncompatible }

class CowSyncItem {
  const CowSyncItem({
    required this.promptName,
    required this.action,
    required this.serverVersion,
    this.fromVersion,
    this.content,
    this.description,
  });

  final String promptName;
  final CowSyncAction action;
  final String serverVersion;
  final String? fromVersion;
  final String? content;
  final String? description;
}

/// major 跃迁告警回调：true = 重置（弃本地副本回 server 版）；false = 保留本地。
/// null 回调 = 保留本地（保守默认，known 版本刷新防重复告警）。
typedef CowMajorJumpDelegate = Future<bool> Function(
    String promptName, String fromVersion, String toVersion);

class CowSyncService {
  CowSyncService({required this.store, this.onMajorJump});

  final CowOverridesStore store;
  final CowMajorJumpDelegate? onMajorJump;

  /// 同步一轮：拉 prompts/list → 逐条原文 → CoW 裁决。返回逐条结果，
  /// imported/resetToServer 的条目由调用方注册进 SkillRegistry（appScoped）。
  Future<List<CowSyncItem>> sync(
    McpClient client, {
    required String serverId,
    String hostVersion = kHostVersion,
  }) async {
    final prompts = await client.listPrompts();
    final out = <CowSyncItem>[];
    for (final p in prompts) {
      final name = p['name'];
      if (name is! String || name.isEmpty) continue;
      final meta = p['_meta'];
      final version =
          meta is Map && meta['template_version'] is String ? meta['template_version'] as String : '0.0.0';
      final minHub =
          meta is Map && meta['min_hub_version'] is String ? meta['min_hub_version'] as String : null;

      // 兼容闸：宿主低于 min_hub_version → 跳过（降级留痕，不抛）
      if (minHub != null && compareVersions(hostVersion, minHub) < 0) {
        out.add(CowSyncItem(
          promptName: name,
          action: CowSyncAction.skippedIncompatible,
          serverVersion: version,
        ));
        continue;
      }

      final known = await store.knownVersion(name);
      final override = await store.overrideOf(name);

      if (override != null &&
          known != null &&
          isMajorJump(known, version)) {
        final reset = await onMajorJump?.call(name, known, version) ?? false;
        if (reset) {
          await store.reset(name);
        } else {
          await store.setKnownVersion(name, version); // 刷新基线防重复告警
          out.add(CowSyncItem(
            promptName: name,
            action: CowSyncAction.keptLocal,
            serverVersion: version,
            fromVersion: known,
          ));
          continue;
        }
      } else if (override != null) {
        out.add(CowSyncItem(
          promptName: name,
          action: CowSyncAction.keptLocal,
          serverVersion: version,
          fromVersion: known,
        ));
        await store.setKnownVersion(name, version);
        continue;
      }

      // 无覆写（或刚重置）→ 导入 server 版
      String content;
      try {
        content = await client.getPromptRaw(name);
      } on McpException catch (e) {
        // DEGRADE: 单条原文拉取失败不阻断整轮同步，留痕跳过。
        debugPrint('[DEGRADE] cow-sync: getPromptRaw($name) failed: $e');
        continue;
      }
      await store.setKnownVersion(name, version);
      out.add(CowSyncItem(
        promptName: name,
        action: override != null
            ? CowSyncAction.resetToServer
            : CowSyncAction.imported,
        serverVersion: version,
        fromVersion: known,
        content: content,
        description: p['description'] is String ? p['description'] as String : null,
      ));
    }
    return out;
  }

  /// 同步产物 → Skill（appScoped 绑来源 server；source=cow）。
  static Skill toSkill(CowSyncItem item, String serverId) => Skill(
        name: 'cow/${item.promptName}',
        scope: SkillScope.appScoped,
        serverId: serverId,
        description: item.description ?? 'goodshare 模板（CoW 同步 v${item.serverVersion}）',
        content: item.content ?? '',
        source: SkillSource.cow,
      );
}
