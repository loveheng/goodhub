/// 任务消费对账账本（M4-2 对账能力，跨会话持久化）。
///
/// 定位：**执行侧对账**——用户点了 goodshare 的 AI 任务后不该「猜有没有被
/// 处理」。本件记录宿主侧实际执行结果（动作 / 条目 / 成功或失败原因），
/// 与 goodshare 侧任务队列页（DB 全量账）分工：那边看历史全量，这边看宿主
/// 执行实况。
///
/// 存储：单文件 JSON + [SequentialFileWriter] 原子重写（互斥粒度 = 文件路径，
/// P0-A 后同路径跨实例串行安全）；量小（最近 N 条）故全量重写而非追加。
/// 损坏文件 → 空账 + DEGRADE 留痕（宁空勿炸，同 WorkspaceStateStore 口径）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/storage/sequential_file_writer.dart';

/// 对账单条明细：一次「认领 → 处理 → 回写」的实况。
class TaskLedgerEntry {
  const TaskLedgerEntry({
    required this.atMs,
    required this.taskId,
    required this.itemId,
    required this.action,
    required this.ok,
    required this.serverId,
    this.serverName,
    this.reason,
  });

  final int atMs;
  final String taskId;

  /// 条目 id——用户据此确认「我那条笔记处理了没有」（真对账锚点）。
  final String itemId;
  final String action;

  /// 成功（apply 回写成功）或失败（含 failed 终态收尾）。
  final bool ok;

  /// 来源 MCP server 标识（按服务领域划分的键；当前恒 goodshare 包名，
  /// 预留多 server 接入）。
  final String serverId;

  /// 来源展示名（可选；null = 取 [serverId] 末段）。
  final String? serverName;

  /// 失败原因（成功为 null）。
  final String? reason;

  Map<String, Object?> toJson() => {
        'at_ms': atMs,
        'task_id': taskId,
        'item_id': itemId,
        'action': action,
        'ok': ok,
        'server_id': serverId,
        if (serverName != null) 'server_name': serverName,
        if (reason != null) 'reason': reason,
      };

  static TaskLedgerEntry? parse(Object? raw) {
    if (raw is! Map) return null;
    final atMs = raw['at_ms'];
    final taskId = raw['task_id'];
    final itemId = raw['item_id'];
    final action = raw['action'];
    final serverId = raw['server_id'];
    if (atMs is! int ||
        taskId is! String ||
        itemId is! String ||
        action is! String ||
        serverId is! String) {
      return null;
    }
    final reason = raw['reason'];
    final serverName = raw['server_name'];
    return TaskLedgerEntry(
      atMs: atMs,
      taskId: taskId,
      itemId: itemId,
      action: action,
      ok: raw['ok'] == true,
      serverId: serverId,
      serverName: serverName is String ? serverName : null,
      reason: reason is String ? reason : null,
    );
  }
}

/// 消费对账账本：今日计数 + 最近 N 条明细。
class TaskConsumeLedger {
  TaskConsumeLedger({required this.dir, this.maxEntries = 20});

  final Directory dir;

  /// 明细保留条数（写入即裁剪，无需 TTL GC）。
  final int maxEntries;

  /// 生产装配：应用支持目录下 `task_ledger` 子目录。
  factory TaskConsumeLedger.underSupportDir(String supportPath) =>
      TaskConsumeLedger(dir: Directory('$supportPath/task_ledger'));

  File get _file => File('${dir.path}/ledger.json');

  final List<TaskLedgerEntry> _entries = <TaskLedgerEntry>[];
  String _date = '';
  int _done = 0;
  int _failed = 0;
  bool _loaded = false;

  /// 全部明细（按追加序，最新在末尾）。
  List<TaskLedgerEntry> get entries => List.unmodifiable(_entries);

  /// 今日可见明细（自然日过滤——对账是近期确认用途，>今天的隐藏；
  /// 持久化保留全量，物理上限由 [maxEntries] 防膨胀，不物理删历史）。
  List<TaskLedgerEntry> get recentEntries =>
      _entries.where((e) => _dateKey(DateTime.fromMillisecondsSinceEpoch(e.atMs)) == _today).toList();

  /// 按来源 server 分组的今日明细（key = serverId；顺序 = 首次出现序）。
  Map<String, List<TaskLedgerEntry>> get groupedByServer {
    final map = <String, List<TaskLedgerEntry>>{};
    for (final e in recentEntries) {
      (map[e.serverId] ??= <TaskLedgerEntry>[]).add(e);
    }
    return map;
  }

  /// 今日成功条数（仅 [recentEntries] 口径）。
  int get todayDone => recentEntries.where((e) => e.ok).length;

  /// 今日失败条数（仅 [recentEntries] 口径）。
  int get todayFailed => recentEntries.where((e) => !e.ok).length;

  static String get _today => _dateKey(DateTime.now());

  static String _dateKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// 读盘（幂等；损坏 → 空账 + DEGRADE 留痕）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await _file.exists()) return;
      final text = await _file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw const FormatException('ledger root not object');
      final date = decoded['date'];
      _date = date is String ? date : _today;
      _done = decoded['done'] is int ? decoded['done'] as int : 0;
      _failed = decoded['failed'] is int ? decoded['failed'] as int : 0;
      final raw = decoded['entries'];
      if (raw is List) {
        for (final e in raw) {
          final entry = TaskLedgerEntry.parse(e);
          if (entry != null) _entries.add(entry);
        }
      }
      _rollDateIfNeeded();
      _trim();
    } on Object catch (e) {
      // 宁空勿炸（可重新沉淀）：损坏文件不阻断启动。
      debugPrint('[DEGRADE] task-ledger load: $e');
      _entries.clear();
      _date = _today;
      _done = 0;
      _failed = 0;
    }
  }

  /// 记账（内存 + 落盘）：裁剪到 [maxEntries]，跨日自动重置今日计数。
  Future<void> record(TaskLedgerEntry entry) async {
    if (!_loaded) await load();
    _rollDateIfNeeded();
    _entries.add(entry);
    if (entry.ok) {
      _done++;
    } else {
      _failed++;
    }
    _trim();
    await _flush();
  }

  /// 清空（设置页「清空对账」入口）。
  Future<void> clear() async {
    _entries.clear();
    _date = _today;
    _done = 0;
    _failed = 0;
    await _flush();
  }

  /// 落盘排空握手（测试确定性：替代固定延迟猜等）。
  Future<void> get ioDrained async {
    await SequentialFileWriter(_file).settled;
  }

  void _rollDateIfNeeded() {
    final today = _today;
    if (_date != today) {
      _date = today;
      _done = 0;
      _failed = 0;
    }
  }

  void _trim() {
    final overflow = _entries.length - maxEntries;
    if (overflow > 0) _entries.removeRange(0, overflow);
  }

  Future<void> _flush() async {
    // 首次记账时持久目录尚不存在（App 首启 / 清数据后）——不建目录则
    // SequentialFileWriter 写 .tmp 抛 PathNotFoundException（真机同发）。
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final payload = jsonEncode({
      'date': _date,
      'done': _done,
      'failed': _failed,
      'entries': [for (final e in _entries) e.toJson()],
    });
    try {
      await SequentialFileWriter(_file).write(payload);
    } on Object catch (e) {
      debugPrint('[DEGRADE] task-ledger flush: $e');
    }
  }
}
