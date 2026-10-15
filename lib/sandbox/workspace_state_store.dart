/// 会话级（workspace）事实库——G3（chatmessage P2-1，SSOT §9.5）。
///
/// 只承 `session` 域（任务临时决策）：per-conversation 键值对，
/// `upsert` = 主键冲突整行替换（等价 `INSERT OR REPLACE`）、
/// `remove` = 等价 `DELETE`；无行级锁（D-K 已砍，用户纠错走 UI 删除）。
///
/// **物理实现偏离 SSOT §9.5 的 SQLite DDL**（待确认决策点）：全仓无 sqlite
/// 依赖，MemoryStore 亦为纯文件栈——本 store 用「每会话一 JSON 文件 +
/// SequentialFileWriter 原子重写」实现同语义（键级覆盖/删除、updated_at 毫秒
/// 时间戳），零新依赖。若后续出现键序范围查询诉求再评估迁 sqlite3。
///
/// 损坏文件：返空表 + DEGRADE 留痕（宁空勿炸，可重新沉淀）；
/// conversation_id 即文件名锚，含路径分隔符 / `..` 拒绝（防御性校验）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/storage/sequential_file_writer.dart';

/// 单条会话事实（key → value + 更新时间）。
class WorkspaceStateEntry {
  const WorkspaceStateEntry({required this.key, required this.value, required this.updatedAtMs});

  final String key;
  final String value;

  /// 更新时刻（epoch 毫秒，等价 DDL `updated_at INTEGER`）。
  final int updatedAtMs;
}

class WorkspaceStateStore {
  WorkspaceStateStore({required this.dir});

  /// 持久目录（注入：生产 = 应用支持目录下 `workspace_states` 子目录；
  /// 测试 = 临时目录）。路径以 String 传入——UI 层禁 dart:io（coding-standards
  /// Rule 1），Directory 构造收在本层。
  final Directory dir;

  /// 生产装配入口：应用支持目录下的 `workspace_states` 子目录。
  factory WorkspaceStateStore.underSupportDir(String supportPath) =>
      WorkspaceStateStore(dir: Directory('$supportPath/workspace_states'));

  final Map<String, SequentialFileWriter> _writers = {};

  /// 操作串行链：所有「读-改-写」复合单元在此排队，杜绝同会话交错。
  Future<void> _tail = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    // 吞错仅为续链（错误已透传 result），与 MemoryStore 同口径。
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  SequentialFileWriter _writerFor(String conversationId) => _writers
      .putIfAbsent(conversationId, () => SequentialFileWriter(_fileFor(conversationId)));

  File _fileFor(String conversationId) {
    if (conversationId.isEmpty ||
        conversationId.contains('/') ||
        conversationId.contains(r'\') ||
        conversationId.contains('..')) {
      throw ArgumentError('conversation_id 非法（作文件名锚须无路径分隔符）: $conversationId');
    }
    return File('${dir.path}/$conversationId.json');
  }

  /// 读全量：该会话的事实快照（注入 prompt 尾部 / UI 胶囊列表用）。
  Future<Map<String, WorkspaceStateEntry>> all(String conversationId) async {
    final file = _fileFor(conversationId);
    if (!await file.exists()) return {};
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) throw const FormatException('root is not an object');
      final out = <String, WorkspaceStateEntry>{};
      data.forEach((key, row) {
        if (row is Map && row['v'] is String) {
          out[key as String] = WorkspaceStateEntry(
            key: key,
            value: row['v'] as String,
            updatedAtMs: row['ts'] is int ? row['ts'] as int : 0,
          );
        }
      });
      return out;
    } on Object catch (err) {
      debugPrint('[DEGRADE] workspace-states: $conversationId 状态文件损坏按空表: $err');
      return {};
    }
  }

  /// upsert（action = "upsert"）：同 key 整条覆盖（等价 `INSERT OR REPLACE`）。
  Future<void> upsert(String conversationId, String key, String value) =>
      _enqueue(() async {
        final states = await all(conversationId);
        states[key] = WorkspaceStateEntry(
          key: key,
          value: value,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        await _ensureDir();
        await _writerFor(conversationId).write(_encode(states));
      });

  /// remove（action = "remove"）：按 key 删除（等价 `DELETE`；key 不存在为幂等）。
  Future<void> remove(String conversationId, String key) => _enqueue(() async {
        final states = await all(conversationId);
        if (!states.containsKey(key)) return;
        states.remove(key);
        await _ensureDir();
        await _writerFor(conversationId).write(_encode(states));
      });

  /// 持久目录懒创建（幂等）——SequentialFileWriter 的 .tmp 原子替换要求父目录在位。
  Future<void> _ensureDir() => dir.create(recursive: true);

  String _encode(Map<String, WorkspaceStateEntry> states) => const JsonEncoder.withIndent('  ')
      .convert({
        for (final e in states.values)
          e.key: {'v': e.value, 'ts': e.updatedAtMs},
      });
}
