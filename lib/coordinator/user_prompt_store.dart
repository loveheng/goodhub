/// user 来源全局 Prompt 管理（prompt-mgmt §3.3 / §8.2.3-8.2.5）：
/// `SkillSource.user` × `SkillScope.global` 的持久化 + 边界清洗 + 注册管道。
/// 规格 SSOT：docs/design/prompt-mgmt.md §3.3（入口）/§8.2.3（fail-closed）/
/// §8.2.4（Token 水位单源）/§8.2.5（存盘边界清洗）。
///
/// - **持久化**：JSON 文件（应用文档目录——与 CoW 覆写同目录同规约，原子写 +
///   按路径串行队列）；**不引入新持久层**（§5 非目标）。
/// - **fail-closed**（§8.2.3）：文件损坏不抛穿启动——备份 + 按空表起步 +
///   `corruptBackupPath` 可见（设置面板警示），禁静默清空。
/// - **注册闸**：`user/<name>` 进 SkillRegistry 过全局唯一闸 + 300 Token
///   硬预算（kGlobalSkillBudgetTokens，fail-fast 不裁剪）；闸不过跳过并通告，
///   不阻断其余 prompt 注册。
/// - **边界清洗**（§8.2.5）：存盘前剥除/转义伪造系统边界标记——① XML/HTML 级
///   （`</system>`/`<tools>` 等，尖括号转全角）；② 组装层与 D-H 真实分区语法
///   （行首 `### Skill:` 等 markdown 分区头、`[System Notice:` 合成通告前缀）。
///   单用户本地 app，不做过度内容清洗（用户即主体）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/storage/keyed_write_queue.dart';
import 'skill_registry.dart';

/// user 全局 prompt 文件名（应用文档目录；与 cow_overrides.json 同规约）。
const kUserGlobalPromptsFileName = 'user_global_prompts.json';

/// user 全局 prompt 名称规约（§8.3 收窄）：注册名 = `user/<name>`（与 `cow/`
/// 对称，利用 SkillRegistry 唯一闸）。裸名限字母/数字/`_`/`-`/CJK——禁 `/`、
/// `:`、空白、`#`、`[` 等会破坏 `### Skill: <name>` 渲染与排序键的字符。
final RegExp kUserPromptNamePattern = RegExp(r'^[\w\u4e00-\u9fff-]{1,40}$');

/// 名称校验（null = 合规）；供 UI 保存前预检与 store 双闸。
String? validateUserPromptName(String name) {
  final n = name.trim();
  if (n.isEmpty) return '名称不能为空';
  if (!kUserPromptNamePattern.hasMatch(n)) {
    return '名称仅限字母/数字/下划线/连字符/中文（1-40 字符）';
  }
  return null;
}

/// XML/HTML 级危险边界标记（§8.2.5 层①）：伪造即劫持 system/tools 分区。
final RegExp _xmlBoundaryPattern =
    RegExp(r'<\s*(/?)\s*(system|tools|user|assistant|human)\s*>', caseSensitive: false);

/// 行首 markdown 分区头（§8.2.5 层②）：伪造即注入假分区——`### Skill:`、
/// `## 宿主 Skills`、`### 可激活` 与组装层 `composeSystemPrompt` 分区语法
/// 同形。整行前导 `#` 段（含行首空白）统一转全角 `＃`。
final RegExp _lineHeaderPattern = RegExp(r'^([ \t]*)(#+)(?=\s|$)', multiLine: true);

/// 合成通告前缀（§8.2.5 层②）：`[System Notice:` 冒充 D-H 系统通告
/// （agent_loop kSyntheticMaskedNotice）。`[` 转全角 `［`——视觉近零差异，
/// 不再是合成标记精确前缀。
const String _kSyntheticNoticePrefix = '[System Notice:';
const String _kSyntheticNoticeEscaped = '［System Notice:';

/// 存盘边界清洗（§8.2.5 纯函数）：返回清洗后正文 + 清洗计数（UI 可见通告
/// 「已清洗 N 处伪造边界标记」）。两层范围：
/// ① XML/HTML 危险标记尖括号转全角；② 行首 markdown 分区头 `#` 段转全角、
/// `[System Notice:` 前缀括号转全角。
({String content, int sanitizedCount}) sanitizeUserPromptContent(String content) {
  var count = 0;
  final xmlSafe = content.replaceAllMapped(_xmlBoundaryPattern, (m) {
    count++;
    return m[0]!.replaceAll('<', '＜').replaceAll('>', '＞');
  });
  final headerSafe = xmlSafe.replaceAllMapped(_lineHeaderPattern, (m) {
    count++;
    return '${m[1]}${m[2]!.replaceAll('#', '＃')}';
  });
  var noticeSafe = headerSafe;
  while (true) {
    final i = noticeSafe.indexOf(_kSyntheticNoticePrefix);
    if (i < 0) break;
    count++;
    noticeSafe = noticeSafe.replaceRange(
      i,
      i + _kSyntheticNoticePrefix.length,
      _kSyntheticNoticeEscaped,
    );
  }
  return (content: noticeSafe, sanitizedCount: count);
}

/// 一条 user 全局 prompt（裸名存储；注册名 = `user/<name>`）。
class UserGlobalPrompt {
  const UserGlobalPrompt({
    required this.name,
    required this.content,
    required this.description,
    required this.updatedAt,
  });

  final String name;
  final String content;
  final String description;
  final DateTime updatedAt;

  /// → SkillRegistry 全局 Skill（source=user；注册闸由 register 承守）。
  Skill toSkill() => Skill(
        name: 'user/$name',
        scope: SkillScope.global,
        description: description.isEmpty ? '用户全局 Prompt' : description,
        content: content,
        source: SkillSource.user,
      );
}

/// user 全局 prompt 存储（持久化 + fail-closed 容灾，口径对齐
/// CowOverridesStore：原子写 + 按路径串行 + 损坏先备份再空表起步）。
class UserGlobalPromptsStore {
  UserGlobalPromptsStore({required this.dir, this.fileName = kUserGlobalPromptsFileName});

  final Directory dir;
  final String fileName;

  Map<String, Object?> _cache = const {};
  bool _loaded = false;

  /// 上次加载发现文件损坏时的备份路径（§8.2.3；null = 未损坏）。
  String? _corruptBackup;

  /// 损坏备份路径（供设置面板警示 + 用户手动找回）。
  String? get corruptBackupPath => _corruptBackup;

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
      // DEGRADE: 配置文件损坏（手改/写坏）——先备份再按空表起步（§8.2.3：
      // 不抛穿启动、非阻塞通告「配置损坏已隔离，建议重置」），留痕。
      debugPrint('[DEGRADE] user-prompt-store: file unreadable, backed up + starting fresh: $e');
      _corruptBackup = await _backupCorrupt();
      _cache = {};
    }
    return _cache;
  }

  /// 损坏文件备份（rename 原子；失败不阻断——原文件未被移动，留痕）。
  Future<String?> _backupCorrupt() async {
    try {
      final backup =
          File('${_file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      await _file.rename(backup.path);
      return backup.path;
    } on Object catch (e) {
      debugPrint('[DEGRADE] user-prompt-store: 损坏文件备份失败（原文件保留）: $e');
      return null;
    }
  }

  Future<void> _save() async {
    // §S4：原子写唯一入口（队列内 tmp→flush→rename；手写副本已收口）。
    await KeyedWriteQueue.instance
        .enqueueAtomicWrite(_file.path, utf8.encode(jsonEncode(_cache)));
  }

  Map<String, Object?>? get _section {
    final v = _cache['prompts'];
    return v is Map ? {for (final e in v.entries) '${e.key}': e.value} : null;
  }

  /// 全部 user 全局 prompt（按名称升序；空库/损坏 = 空表）。
  Future<List<UserGlobalPrompt>> load() async {
    await _load();
    final s = _section;
    if (s == null) return const [];
    final out = <UserGlobalPrompt>[];
    for (final e in s.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final m = {for (final x in v.entries) '${x.key}': x.value};
      final content = m['content'];
      if (content is! String || content.isEmpty) continue;
      out.add(UserGlobalPrompt(
        name: e.key,
        content: content,
        description: m['description'] is String ? m['description'] as String : '',
        updatedAt: DateTime.tryParse(
                m['updated_at'] is String ? m['updated_at'] as String : '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      ));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// 写入（新建/编辑同入口；§8.2.5 边界清洗在存盘前执行——清洗计数回传供
  /// UI 可见通告）。名称不合规抛 [ArgumentError]（UI 侧双闸预检）。
  Future<int> save({
    required String name,
    required String content,
    String description = '',
  }) async {
    final n = name.trim();
    final invalid = validateUserPromptName(n);
    if (invalid != null) throw ArgumentError(invalid);
    final trimmed = content.trim();
    if (trimmed.isEmpty) throw ArgumentError('正文不能为空');
    final sanitized = sanitizeUserPromptContent(trimmed);
    await _load();
    final s = Map<String, Object?>.of(_section ?? const {});
    s[n] = {
      'content': sanitized.content,
      'description': description.trim(),
      'updated_at': DateTime.now().toIso8601String(),
    };
    _cache = {..._cache, 'prompts': s};
    await _save();
    return sanitized.sanitizedCount;
  }

  /// 删除（幂等——不存在即空操作）。
  Future<void> delete(String name) async {
    await _load();
    final s = Map<String, Object?>.of(_section ?? const {});
    if (!s.containsKey(name)) return;
    s.remove(name);
    _cache = {..._cache, 'prompts': s};
    await _save();
  }
}

/// 基础 SkillRegistry 装配产物（chat_page / debug 页共用）：注册表 + 被注册闸
/// 跳过的 prompt 名（fail-fast 通告文本，空 = 全部注册成功）。
final class BaseSkillRegistry {
  BaseSkillRegistry({required this.registry, required this.skipped});

  final SkillRegistry registry;
  final List<String> skipped;
}

/// 装配基础 SkillRegistry：builtin 全集 + user 全局 prompt（§3.3）。
/// [dirResolver] 必填注入位（应用文档目录；UI 装配与测试各自传入——纯 Dart
/// 环境无 path_provider 实现，不提供隐式生产缺省，防测试静默走平台通道）。
/// user prompt 过 SkillRegistry 注册闸（重名/300 Token 预算）——fail-fast
/// 跳过不裁剪，跳过项经 [BaseSkillRegistry.skipped] 回窗口可见通告。
Future<BaseSkillRegistry> buildBaseSkillRegistry({
  required Future<Directory> Function() dirResolver,

  /// S1：应用级单实例来源（生产由窗口经 `lib/app/service_directory` 传入）。
  /// null = 退回 [dirResolver] 就地构造（兼容旧调用方）。
  Future<UserGlobalPromptsStore> Function()? storeProvider,
}) async {
  final registry = SkillRegistry()..registerAll(builtinSkills());
  final skipped = <String>[];
  final store = await (storeProvider?.call() ??
      Future.value(UserGlobalPromptsStore(dir: await dirResolver())));
  for (final p in await store.load()) {
    try {
      registry.register(p.toSkill());
    } on ArgumentError catch (e) {
      // DEGRADE: 单条 user prompt 过不了注册闸（超 300 Token 或被占用）——
      // 跳过并通告，不阻断其余 prompt 与启动。
      debugPrint('[DEGRADE] user-prompt: register skipped ${p.name}: $e');
      skipped.add('user/${p.name}（$e）');
    }
  }
  return BaseSkillRegistry(registry: registry, skipped: skipped);
}
