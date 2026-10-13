/// 记忆沙盒内核（Memory Sandbox，M4-T1）。
/// 规格 SSOT：architecture.md §4（三件套/串行写队列/原子替换/预算截断）、
/// §11（ops.log 10MB 单代轮转/启动清理）、future-considerations.md FC1
/// （结构化块锚点）、coding-standards.md §5.1（File Mutex 降格实现）；
/// 施工设计与拍板 D4~D7 = docs/design/m4.md §3-T1/§4。
///
/// - 三件套：memory.md（长期事实）/ lessons.md（踩坑教训）/ ops.log（Tool Call
///   审计）；memory/lessons 条目带 FC1 锚点 `<!-- id, tags, ts -->`（D5：lessons
///   同格式，一套解析器共用），ops.log 为 JSONL（D7）；
/// - 写路径：memory/lessons 为「读文件 → 改 → 全量重写落盘」复合单元（§5.1
///   「全量重写内存态后落盘」）， ops.log 为追加 + 超限轮转——两者全部经本类
///   操作串行链（read-modify-write 原子性 + §5.1「轮转入队串行执行」）与
///   [SequentialFileWriter]（串行 + 原子替换）双层执行；
/// - 预算截断（F4.2 截断半边）按**整条目丢最旧**——锚点完整性是 FC1 免清洗
///   迁移前提，严禁截半条；单条超预算保底保留最新一条（D6），超量代价由
///   [MemoryView.droppedCount] 可观测；归纳压缩随端侧解锁（m4.md C-1），本期不实现；
/// - 读路径不缓存（每次直读落盘态）：M4-T5 记忆看板会引入用户编辑，缓存失效
///   面不值得引入；文件体量数千条目内读放大可忽略；
/// - 锚点行为宿主保留字：正文行恰好匹配锚点格式会被解析为新条目（未定义行为，
///   T5 编辑面校验），写入侧不做转义；
/// - 作用域三层归属（M4-D8 拍板）：user 全局 / `srv:` 前缀 + serverId 绑定
///   （卸载即清）/ 数据快照不进记忆——防「全局错乱」与「按服务过时」双失效模式。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/storage/sequential_file_writer.dart';
import '../core/tokens.dart';

/// 单条记忆/教训条目（FC1 锚点 + 正文）。
class MemoryEntry {
  const MemoryEntry({
    required this.content,
    this.id,
    this.scope = 'user',
    this.tags = const {},
    this.ts,
  });

  /// 条目 id（`mem_001` 起单调分配）；外部手写的无锚点条目为 null。
  final String? id;

  /// 作用域（M4-D8 三层归属）：`user` 全局（偏好/纠错，恒注入）｜
  /// `srv:` 前缀 + serverId（如 `srv:goodshare`）服务绑定（会话涉及时注入，
  /// server 卸载即清——防过时）。
  /// 数据级快照不进记忆（走 resources/read + 订阅失效感知）。
  final String scope;

  /// 标签集（FC1 迁移锚的元数据位；空集渲染 `[]`）。
  final Set<String> tags;

  /// 写入时刻（epoch 毫秒）；无锚点条目为 null。
  final int? ts;

  /// 条目正文（多行，写入时首尾 trim）。
  final String content;
}

/// ops.log 单行渲染模型（M4-T5 看板消费；D7 JSONL 的类型化读面）。
class OpsLogLine {
  const OpsLogLine({
    required this.ts,
    required this.server,
    required this.tool,
    required this.ok,
    this.durationMs,
    this.error,
  });

  final String ts; // ISO8601
  final String server;
  final String tool;
  final bool ok;
  final int? durationMs;
  final String? error;
}

/// 预算截断视图（T2 system prompt 注入消费）。
class MemoryView {
  const MemoryView({
    required this.entries,
    required this.rendered,
    required this.estimatedTokens,
    required this.droppedCount,
  });

  /// 保留条目（原始顺序 = 旧 → 新）。
  final List<MemoryEntry> entries;

  /// 注入用 Markdown：正文按条目空行连接（锚点剥除——注释行不进 prompt）。
  final String rendered;

  /// [rendered] 的 token 粗估（core/tokens.dart 字符级口径，与上下文治理同族）。
  final int estimatedTokens;

  /// 因预算被丢的最旧条目数；>0 即超限（可观测面，T2 接提示）。
  final int droppedCount;

  bool get truncated => droppedCount > 0;
}

/// 记忆沙盒（三件套持久化 + 预算视图 + 审计 + 启动清扫）。
class MemoryStore {
  MemoryStore({
    required this.dir,
    this.memoryBudgetTokens = 2000,
    this.opsLogMaxBytes = 10 << 20,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _memoryWriter = SequentialFileWriter(File('${dir.path}/$memoryFileName'));
    _lessonsWriter = SequentialFileWriter(File('${dir.path}/$lessonsFileName'));
    _opsWriter = SequentialFileWriter(File('${dir.path}/$opsLogFileName'));
  }

  /// 沙盒持久目录（注入：生产 = 应用支持目录下子目录，T2 接线定；测试 = 临时目录）。
  final Directory dir;

  /// memory.md 注入预算初值（token 字符级口径；T7 调参惯例随真机）。
  final int memoryBudgetTokens;

  /// ops.log 单文件上限（architecture §11 初值 10MB）。
  final int opsLogMaxBytes;

  final DateTime Function() _clock;

  static const memoryFileName = 'memory.md';
  static const lessonsFileName = 'lessons.md';
  static const opsLogFileName = 'ops.log';
  static const _opsRotatedSuffix = '.1';

  /// 生产装配入口：应用支持目录下的 `memory` 子目录（App 冷启动清扫与各
  /// 装配点共用同一路径口径）。路径以 String 传入——UI 层禁 dart:io
  /// （coding-standards Rule 1），Directory 构造收在本层。
  factory MemoryStore.underSupportDir(String supportPath) =>
      MemoryStore(dir: Directory('$supportPath/memory'));

  late final SequentialFileWriter _memoryWriter;
  late final SequentialFileWriter _lessonsWriter;
  late final SequentialFileWriter _opsWriter;

  /// 操作串行链：所有「读-改-写」复合单元与轮转在此排队，杜绝交错。
  Future<void> _tail = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    // 吞错仅为续链（错误已透传 result），与 SequentialFileWriter 同口径。
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  // ---------------------------------------------------------------------------
  // memory.md / lessons.md（FC1 锚点条目面）
  // ---------------------------------------------------------------------------

  /// 写入一条长期事实，返回分配好 id/ts 的条目。空内容拒绝（禁静默）。
  ///
  /// [scope] 写入门槛纪律（D8）：user 级只收与服务无关的稳定事实（偏好/纠错）；
  /// srv 级收该服务的交互教训/工具怪癖；**会话临时数据快照禁入**（易变事实
  /// 走 resources/read 实时读，T2 写入工具 description 主动引导此口径）。
  Future<MemoryEntry> remember(
    String content, {
    Set<String> tags = const {},
    String scope = 'user',
  }) =>
      _appendAnchored(_memoryWriter, memoryFileName, content, tags, scope);

  /// 写入一条踩坑教训（与 memory 同格式同解析器，D5）。
  Future<MemoryEntry> addLesson(
    String content, {
    Set<String> tags = const {},
    String scope = 'user',
  }) =>
      _appendAnchored(_lessonsWriter, lessonsFileName, content, tags, scope);

  Future<MemoryEntry> _appendAnchored(
    SequentialFileWriter writer,
    String fileName,
    String content,
    Set<String> tags,
    String scope,
  ) =>
      _enqueue(() async {
        final trimmed = content.trim();
        if (trimmed.isEmpty) throw ArgumentError('记忆条目内容不能为空');
        if (!_scopeRegExp.hasMatch(scope)) {
          throw ArgumentError('scope 必须为 user 或 srv:<serverId>：$scope');
        }
        await dir.create(recursive: true);
        final entries = await _readEntries(fileName);
        final entry = MemoryEntry(
          id: _nextId(entries),
          scope: scope,
          tags: Set.of(tags),
          ts: _clock().millisecondsSinceEpoch,
          content: trimmed,
        );
        entries.add(entry);
        await writer.write(_renderFile(entries));
        return entry;
      });

  /// 全量列出 memory 条目（落盘态直读，无缓存）。
  Future<List<MemoryEntry>> listMemories() =>
      _enqueue(() => _readEntries(memoryFileName));

  /// 全量列出 lessons 条目。
  Future<List<MemoryEntry>> listLessons() =>
      _enqueue(() => _readEntries(lessonsFileName));

  /// 卸载清扫（D8 生命周期绑定）：清除 memory + lessons 中该 server 绑定
  /// 条目，返回清除总数。仅接受 serverId（内部构造 srv: 前缀），杜绝误清
  /// user 级——user 级粉碎归记忆看板（T5），不走本方法。
  Future<int> purgeServerScope(String serverId) => _enqueue(() async {
        if (serverId.isEmpty) throw ArgumentError('serverId 不能为空');
        final target = 'srv:$serverId';
        var purged = 0;
        for (final (fileName, writer) in [
          (memoryFileName, _memoryWriter),
          (lessonsFileName, _lessonsWriter),
        ]) {
          final entries = await _readEntries(fileName);
          final kept = entries.where((e) => e.scope != target).toList();
          purged += entries.length - kept.length;
          if (kept.length != entries.length) {
            await dir.create(recursive: true);
            await writer.write(_renderFile(kept));
          }
        }
        return purged;
      });

  /// 预算截断视图：整条目丢最旧（锚点完整性），单条超预算保底留最新（D6）。
  ///
  /// 作用域装配（D8 三层归属）：[serverScopes] 空 → 仅 user 级（与任何服务
  /// 无关的偏好/纠错）；非空 → user 级 + 各 server 绑定条目并入（M4-T6 多
  /// Server：传全部已连 id）。droppedCount 按 scope 内条目计。
  Future<MemoryView> memoryView(
      {int? budgetTokens, List<String> serverScopes = const []}) =>
      _enqueue(() async {
        final scopes = {
          for (final id in serverScopes) 'srv:$id',
        };
        final scoped = (await _readEntries(memoryFileName)).where((e) {
          if (e.scope == 'user') return true;
          return scopes.contains(e.scope);
        }).toList();
        final budget = budgetTokens ?? memoryBudgetTokens;
        // 最新优先圈定保留集，输出回原序（旧 → 新）。
        final kept = <MemoryEntry>[];
        var used = 0;
        for (final e in scoped.reversed) {
          final cost = estimateTokens(e.content);
          if (used + cost > budget && kept.isNotEmpty) break;
          used += cost;
          kept.add(e);
        }
        final keptOrdered = kept.reversed.toList(growable: false);
        final rendered = keptOrdered.map((e) => e.content).join('\n\n');
        return MemoryView(
          entries: keptOrdered,
          rendered: rendered,
          estimatedTokens: estimateTokens(rendered),
          droppedCount: scoped.length - keptOrdered.length,
        );
      });

  // ---------------------------------------------------------------------------
  // 看板编辑面（M4-T5/F5.3：查看/编辑/导出/粉碎；读写走同一串行链）
  // ---------------------------------------------------------------------------

  /// 编辑一条记忆/教训正文（看板用户编辑）。锚点保留（id/scope/tags 不变，
  /// 防止编辑破坏 D8 作用域与 FC1 迁移锚），ts 刷新为编辑时刻。
  /// 返回 false = 条目不存在（未找到不静默成功）。
  Future<bool> updateEntry(String entryId, String content,
          {bool lessons = false}) =>
      _enqueue(() async {
        final trimmed = content.trim();
        if (trimmed.isEmpty) throw ArgumentError('记忆条目内容不能为空');
        final fileName = lessons ? lessonsFileName : memoryFileName;
        final entries = await _readEntries(fileName);
        final idx = entries.indexWhere((e) => e.id == entryId);
        if (idx < 0) return false;
        entries[idx] = MemoryEntry(
          id: entries[idx].id,
          scope: entries[idx].scope,
          tags: entries[idx].tags,
          ts: _clock().millisecondsSinceEpoch,
          content: trimmed,
        );
        await dir.create(recursive: true);
        await (lessons ? _lessonsWriter : _memoryWriter)
            .write(_renderFile(entries));
        return true;
      });

  /// 删除单条记忆/教训（看板条目级粉碎）。返回 false = 条目不存在。
  Future<bool> deleteEntry(String entryId, {bool lessons = false}) =>
      _enqueue(() async {
        final fileName = lessons ? lessonsFileName : memoryFileName;
        final entries = await _readEntries(fileName);
        final kept = entries.where((e) => e.id != entryId).toList();
        if (kept.length == entries.length) return false;
        await dir.create(recursive: true);
        await (lessons ? _lessonsWriter : _memoryWriter)
            .write(_renderFile(kept));
        return true;
      });

  /// user 级全量粉碎（看板危险区，F4.3/F5.3「粉碎」；对 [purgeServerScope]
  /// 注记的归属收口——user 级清空是用户显式行为，不走卸载清扫通道）。
  /// 清 memory + lessons 两文件中 scope=='user' 的条目，返回清除总数。
  Future<int> purgeUserScope() => _enqueue(() async {
        var purged = 0;
        for (final (fileName, writer) in [
          (memoryFileName, _memoryWriter),
          (lessonsFileName, _lessonsWriter),
        ]) {
          final entries = await _readEntries(fileName);
          final kept =
              entries.where((e) => e.scope != 'user').toList();
          purged += entries.length - kept.length;
          if (kept.length != entries.length) {
            await dir.create(recursive: true);
            await writer.write(_renderFile(kept));
          }
        }
        return purged;
      });

  /// 导出记忆+教训全量原文（锚点行保留——FC1 免清洗迁移前提，备份可恢复）。
  /// 两个文件均缺失时返回空串；单文件缺失跳过。
  Future<String> exportAll() => _enqueue(() async {
        final buf = StringBuffer();
        for (final (title, fileName) in [
          ('宿主记忆（memory.md）', memoryFileName),
          ('踩坑教训（lessons.md）', lessonsFileName),
        ]) {
          final f = File('${dir.path}/$fileName');
          if (!await f.exists()) continue;
          buf
            ..writeln('# $title')
            ..writeln(await f.readAsString())
            ..writeln();
        }
        return buf.toString().trimRight();
      });

  // ---------------------------------------------------------------------------
  // ops.log（JSONL 审计 + 10MB 单代轮转，N4 / architecture §11）
  // ---------------------------------------------------------------------------

  /// 追加一条 Tool Call 审计记录（JSONL，D7）。轮转检查同单元串行执行。
  Future<void> audit({
    required String server,
    required String tool,
    required bool ok,
    int? durationMs,
    String? error,
  }) =>
      _enqueue(() async {
        await dir.create(recursive: true);
        await _rotateOpsLogIfNeeded();
        final line = jsonEncode(<String, Object?>{
          'ts': _clock().toIso8601String(),
          'server': server,
          'tool': tool,
          'ok': ok,
          'durationMs': ?durationMs,
          'error': ?error,
        });
        await _opsWriter.append('$line\n');
      });

  /// 超限轮转：ops.log → ops.log.1（POSIX rename 原子覆盖旧档 = 单代滚动）。
  /// 失败不阻断审计追加（ops.log 暂超限至下次成功），DEGRADE 留痕可观测。
  Future<void> _rotateOpsLogIfNeeded() async {
    final f = _opsFile;
    if (!await f.exists()) return;
    if (await f.length() < opsLogMaxBytes) return;
    try {
      await f.rename('${f.path}$_opsRotatedSuffix');
    } catch (e) {
      debugPrint('[DEGRADE] memory-store: ops.log rotate failed: $e');
    }
  }

  File get _opsFile => File('${dir.path}/$opsLogFileName');

  /// ops.log 审计行（D7 JSONL 的看板渲染模型；坏行跳过不炸——审计面宁缺勿炸）。
  Future<List<OpsLogLine>> listOpsLog({int limit = 200}) =>
      _enqueue(() async {
        final f = _opsFile;
        if (!await f.exists()) return const [];
        final lines = (await f.readAsString())
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        final out = <OpsLogLine>[];
        // 新审计在后，倒序取最新 limit 条（看板默认视角 = 最近优先）。
        for (final line in lines.reversed) {
          if (out.length >= limit) break;
          try {
            final j = jsonDecode(line);
            if (j is! Map) continue;
            out.add(OpsLogLine(
              ts: j['ts'] as String? ?? '',
              server: j['server'] as String? ?? '?',
              tool: j['tool'] as String? ?? '?',
              ok: j['ok'] as bool? ?? false,
              durationMs: j['durationMs'] is num
                  ? (j['durationMs'] as num).toInt()
                  : null,
              error: j['error'] as String?,
            ));
          } on FormatException {
            continue; // 半行/脏行跳过
          }
        }
        return out;
      });

  // ---------------------------------------------------------------------------
  // 启动维护（architecture §11「启动时清理超限旧档」；T2 挂冷启动流程）
  // ---------------------------------------------------------------------------

  /// 启动幂等清扫：清写残留临时文件（崩溃半程产物）+ ops.log 超限轮转。
  Future<void> sweepStartup() => _enqueue(() async {
        if (!await dir.exists()) return;
        final staleTemps = {
          '$memoryFileName.tmp',
          '$lessonsFileName.tmp',
          '$opsLogFileName.tmp',
        };
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (!staleTemps.contains(name)) continue;
          try {
            await entity.delete();
          } catch (e) {
            // DEGRADE: 单文件清理失败不阻断启动（下次启动重试），留痕。
            debugPrint('[DEGRADE] memory-store: stale tmp sweep failed: $name ($e)');
          }
        }
        await _rotateOpsLogIfNeeded();
      });

  // ---------------------------------------------------------------------------
  // FC1 锚点渲染/解析
  // ---------------------------------------------------------------------------

  /// 锚点行（scope 段 D8 扩展；`(?:…)?` 可选组兼收旧格式无 scope 锚点，
  /// 解析缺省 = user——外部手写/历史文件容错）。
  static final RegExp _anchorRegExp = RegExp(
    r'^<!-- id: (mem_\d+)(?:, scope: (\S+))?, tags: \[([^\]]*)\], ts: (\d+) -->$',
  );
  static final RegExp _idRegExp = RegExp(r'^mem_(\d+)$');
  static final RegExp _scopeRegExp = RegExp(r'^(user|srv:[A-Za-z0-9_-]+)$');

  String _renderAnchor(MemoryEntry e) =>
      '<!-- id: ${e.id}, scope: ${e.scope}, tags: [${e.tags.join(',')}], '
      'ts: ${e.ts ?? 0} -->';

  String _renderFile(List<MemoryEntry> entries) {
    final buf = StringBuffer();
    for (final e in entries) {
      if (e.id != null) buf.writeln(_renderAnchor(e));
      buf.writeln(e.content);
      buf.writeln();
    }
    return buf.toString();
  }

  Future<List<MemoryEntry>> _readEntries(String fileName) async {
    final f = File('${dir.path}/$fileName');
    if (!await f.exists()) return [];
    return _parseEntries(await f.readAsString());
  }

  /// 解析落盘文本为条目：锚点行开新条目，其余行为正文；无锚点前置内容归
  /// id=null 条目（用户手写容错，不丢不炸）；无 scope 段旧锚点缺省 user。
  List<MemoryEntry> _parseEntries(String text) {
    final entries = <MemoryEntry>[];
    String? id;
    var scope = 'user';
    var tags = const <String>{};
    int? ts;
    final content = <String>[];

    void flush() {
      final body = content.join('\n').trim();
      if (id != null || body.isNotEmpty) {
        entries.add(
          MemoryEntry(id: id, scope: scope, tags: tags, ts: ts, content: body),
        );
      }
      id = null;
      scope = 'user';
      tags = const <String>{};
      ts = null;
      content.clear();
    }

    for (final line in text.split('\n')) {
      final m = _anchorRegExp.firstMatch(line.trim());
      if (m != null) {
        flush();
        id = m.group(1);
        scope = m.group(2) ?? 'user';
        final rawTags = m.group(3)?.trim() ?? '';
        tags = rawTags.isEmpty
            ? const <String>{}
            : rawTags.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toSet();
        ts = int.tryParse(m.group(4)!);
      } else {
        content.add(line);
      }
    }
    flush();
    return entries;
  }

  /// id 单调分配：存量锚点 id 取数值 max + 1（mem_001 起，三位零填充自然进位）。
  String _nextId(List<MemoryEntry> entries) {
    var maxNum = 0;
    for (final e in entries) {
      final id = e.id;
      if (id == null) continue;
      final m = _idRegExp.firstMatch(id);
      if (m == null) continue;
      final n = int.parse(m.group(1)!);
      if (n > maxNum) maxNum = n;
    }
    return 'mem_${(maxNum + 1).toString().padLeft(3, '0')}';
  }
}

/// system prompt 记忆节组装（M4-T2 注入口径，读型组装）：memory 预算视图
/// （D8 三层作用域：user 恒注入 + [serverScopes] 各已连服务的 srv 级并入，
/// M4-T6 多 Server 起收列表）+ lessons 全量（M 阶段踩坑流水量级小，随量级
/// 增长并入预算治理——T7 调参）。
///
/// 落位在组装尾部（skills 之后拼接）：记忆是动态增长面，置于 prompt 尾部
/// 与 JIT 工具 Schema 同区，护住前缀缓存（architecture §2）。
/// 全空返回空串（不出节）；超限时尾部注记 droppedCount（模型可见，引导走
/// query_memory 检索——预算外记忆仍可达，禁「截断即失联」）。
Future<String> memoryPromptSection(
  MemoryStore store, {
  int? budgetTokens,
  List<String> serverScopes = const [],
}) async {
  final view = await store.memoryView(
      budgetTokens: budgetTokens, serverScopes: serverScopes);
  final lessons = await store.listLessons();
  if (view.entries.isEmpty && lessons.isEmpty) return '';
  final b = StringBuffer('\n\n## 宿主记忆（长期事实；user 全局 + 当前服务绑定）\n');
  b.write(view.rendered.isEmpty ? '（暂无事实条目）' : view.rendered);
  if (view.truncated) {
    b.write('\n\n（另有 ${view.droppedCount} 条较早记忆超出注入预算，'
        '可用 query_memory 按关键词检索。）');
  }
  if (lessons.isNotEmpty) {
    b.write('\n\n### 踩坑教训\n');
    b.write([for (final l in lessons) '- ${l.content}'].join('\n'));
  }
  return b.toString();
}
