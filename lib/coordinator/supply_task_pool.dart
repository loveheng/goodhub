/// 跨 App 端侧供给异步任务池（on-device-residency W6-a，设计 = 该稿第七节）：
/// 冷态调用「入池回执」替代「就地阻塞冷装载」——顺风车/黄金窗口消费，Outbox 交付。
///
/// **契约要点（设计稿 7.3/7.5）**：
/// - 状态机：`queued → running → pendingDelivery → delivered`；终态旁路 =
///   `failedExhausted`（毒丸死信）/ `expired`（24h 未消化）；
/// - **配额（M4）**：per-caller queued 上限 + 全局上限；`expiry_ms` 过期清账；
///   计费点 = 执行时（K22 产出才计），受理入池不计；
/// - **身份绑定（M5）**：status/cancel/markDelivered 一律 callerKey 过滤——
///   A 插件不可见 B 的任务（callerKey = 内核 UID 推导键，S07b 同源）；
/// - **存储**：JSONL 整本原子写（`KeyedWriteQueue`，`task_consume_ledger`
///   先例）——配额约束后量级低，不引 SQLite（评审定案）；
/// - **No Active Polling**：本类零线程零定时器，消费/过期由调用方沿事件触发。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/storage/keyed_write_queue.dart';

/// 任务状态机。
enum SupplyTaskStatus {
  queued, // 已入池待消费
  running, // 已认领执行中（崩溃恢复时视同 queued 重排）
  pendingDelivery, // 产物已落账待交付（Pull/Push）
  delivered, // 已交付（Pull 查询或显式确认）
  failedExhausted, // 毒丸死信（重试超限，对调用方可见不可恢复）
  expired, // 超过保质期未消化（对调用方可见）
}

/// 单条任务记录（落盘形状，字段即契约——调用方经 status 拉取可见子集）。
class SupplyTaskEntry {
  SupplyTaskEntry({
    required this.taskId,
    required this.callerKey,
    required this.instruction,
    required this.input,
    required this.createdAtMs,
    required this.expiryAtMs,
    this.status = SupplyTaskStatus.queued,
    this.result,
    this.failReason,
    this.retries = 0,
    this.deliveredAtMs,
  });

  factory SupplyTaskEntry.fromJson(Map<String, Object?> m) => SupplyTaskEntry(
        taskId: m['taskId'] as String,
        callerKey: m['callerKey'] as String,
        instruction: m['instruction'] as String,
        input: m['input'] as String,
        createdAtMs: m['createdAtMs'] as int,
        expiryAtMs: m['expiryAtMs'] as int,
        status:
            SupplyTaskStatus.values.firstWhere((s) => s.name == m['status'],
                orElse: () => SupplyTaskStatus.queued),
        result: m['result'] as String?,
        failReason: m['failReason'] as String?,
        retries: (m['retries'] as num?)?.toInt() ?? 0,
        deliveredAtMs: m['deliveredAtMs'] as int?,
      );

  final String taskId;
  final String callerKey; // M5：内核 UID 推导键（交付寻址唯一依据）
  final String instruction;
  final String input;
  final int createdAtMs;
  final int expiryAtMs;
  SupplyTaskStatus status;
  String? result; // 产物（pendingDelivery/delivered 态非空）
  String? failReason; // failedExhausted 态非空
  int retries; // 毒丸计数（M6：抢占/失败回池累计）
  int? deliveredAtMs;

  bool get expired => DateTime.now().millisecondsSinceEpoch >= expiryAtMs;

  Map<String, Object?> toJson() => {
        'taskId': taskId,
        'callerKey': callerKey,
        'instruction': instruction,
        'input': input,
        'createdAtMs': createdAtMs,
        'expiryAtMs': expiryAtMs,
        'status': status.name,
        if (result != null) 'result': result,
        if (failReason != null) 'failReason': failReason,
        'retries': retries,
        if (deliveredAtMs != null) 'deliveredAtMs': deliveredAtMs,
      };

  /// 调用方可见投影（status 拉取面）：input/instruction 不回显（提交方自知），
  /// 产物/状态/失败原因可见。
  Map<String, Object?> projection() => {
        'taskId': taskId,
        'status': status.name,
        if (result != null) 'result': result,
        if (failReason != null) 'failReason': failReason,
        'retries': retries,
        'createdAtMs': createdAtMs,
        'expiryAtMs': expiryAtMs,
      };
}

/// 异步任务池（W6-a）：登记 / 认领 / 完成交付 / 撤销 / 过期清账。
///
/// 单例经 [instance]（executor/drain/测试同源）；目录解析器可注入（测试）。
/// 落盘 = JSONL 整本原子写（`KeyedWriteQueue` 按路径互斥）+ 滚动截半防膨胀。
class SupplyTaskPool {
  SupplyTaskPool({Future<Directory> Function()? dirResolver})
      : _dirResolver = dirResolver; // ignore: prefer_initializing_formals

  static final SupplyTaskPool instance =
      SupplyTaskPool(); // 缺省目录解析（懒取 supportDir）

  final Future<Directory> Function()? _dirResolver;
  final List<SupplyTaskEntry> _entries = [];
  bool _loaded = false;
  static const String _fileName = 'supply_tasks.jsonl';
  static const int _maxPerCaller = 8; // M4：per-caller queued 上限
  static const int _maxTotal = 64; // M4：全局 queued 上限
  static const Duration _defaultExpiry = Duration(hours: 24); // 保质期
  static const int _maxLines = 512;

  /// 配额拒绝原因（submit 失败时调用方可见）。
  String? _quotaDenial;

  String? get lastQuotaDenial => _quotaDenial;

  Future<String> _ledgerPath() async {
    final dir = await (_dirResolver?.call() ?? getApplicationSupportDirectory());
    return '${dir.path}/$_fileName';
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final path = await _ledgerPath();
      final f = File(path);
      if (!f.existsSync()) return;
      for (final line in const LineSplitter().convert(f.readAsStringSync())) {
        if (line.isEmpty) continue;
        try {
          final e = SupplyTaskEntry.fromJson(
              jsonDecode(line) as Map<String, Object?>);
          // 崩溃恢复：running 态 = 上次进程死时在途——视同 queued 重排。
          if (e.status == SupplyTaskStatus.running) {
            e.status = SupplyTaskStatus.queued;
          }
          _entries.add(e);
        } on Object catch (e) {
          debugPrint('[DEGRADE] supply-task-pool: bad line skipped: $e');
        }
      }
    } on Object catch (e) {
      debugPrint('[DEGRADE] supply-task-pool load: $e');
    }
  }

  Future<void> _persist() async {
    final path = await _ledgerPath();
    // 滚动截半（终态条目过半时压缩保留最近 256 条，防账本膨胀）。
    final alive = _entries.where((e) => e.status != SupplyTaskStatus.delivered);
    final finished = _entries
        .where((e) => e.status == SupplyTaskStatus.delivered)
        .toList()
      ..sort((a, b) => (b.deliveredAtMs ?? 0).compareTo(a.deliveredAtMs ?? 0));
    final keepFinished = finished.take(128);
    final all = [...alive, ...keepFinished];
    final body = (all.length > _maxLines
            ? all.sublist(all.length - _maxLines)
            : all)
        .map((e) => jsonEncode(e.toJson()))
        .join('\n');
    await KeyedWriteQueue.instance
        .enqueueAtomicWrite(path, utf8.encode('$body\n'));
  }

  /// 登记（M4 配额 + M5 身份绑定）：返回任务条目；配额拒绝抛 [StateError]
  ///（调用方 = executor，转 isError 文案）。callerKey 必填（M5：无身份不受理）。
  Future<SupplyTaskEntry> submit({
    required String callerKey,
    required String instruction,
    required String input,
    Duration? expiry,
  }) async {
    await _load();
    _purgeExpired();
    final queuedTotal =
        _entries.where((e) => e.status == SupplyTaskStatus.queued).length;
    final queuedForCaller = _entries
        .where((e) =>
            e.status == SupplyTaskStatus.queued && e.callerKey == callerKey)
        .length;
    String? denial;
    if (queuedForCaller >= _maxPerCaller) {
      denial = 'caller queued full ($_maxPerCaller)';
    } else if (queuedTotal >= _maxTotal) {
      denial = 'pool queued full ($_maxTotal)';
    }
    if (denial != null) {
      _quotaDenial = denial;
      throw StateError('任务池配额拒绝: $denial');
    }
    _quotaDenial = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = SupplyTaskEntry(
      taskId: 'task_${now}_${_entries.length}',
      callerKey: callerKey,
      instruction: instruction,
      input: input,
      createdAtMs: now,
      expiryAtMs: now + (expiry ?? _defaultExpiry).inMilliseconds,
    );
    _entries.add(entry);
    await _persist();
    return entry;
  }

  /// 认领最旧 queued（顺风车/黄金窗口排空用）：标记 running；无任务返回 null。
  Future<SupplyTaskEntry?> claimNext() async {
    await _load();
    _purgeExpired();
    for (final e in _entries) {
      if (e.status == SupplyTaskStatus.queued && !e.expired) {
        e.status = SupplyTaskStatus.running;
        return e;
      }
    }
    return null;
  }

  /// 执行完成 → 产物落账待交付。
  Future<void> completeTask(String taskId, String result) async {
    final e = _byId(taskId);
    if (e == null) return;
    e
      ..status = SupplyTaskStatus.pendingDelivery
      ..result = result;
    await _persist();
  }

  /// 毒丸死信（M6：重试超限）——对调用方可见不可恢复。
  Future<void> failExhausted(String taskId, String reason) async {
    final e = _byId(taskId);
    if (e == null) return;
    e
      ..status = SupplyTaskStatus.failedExhausted
      ..failReason = reason;
    await _persist();
  }

  /// 回池尾（K11 抢占/执行失败）：retries 累计；达到上限转死信。
  /// 返回 true = 已回池；false = 已转死信（调用方应停止重排）。
  Future<bool> requeue(String taskId) async {
    final e = _byId(taskId);
    if (e == null) return false;
    e
      ..retries = e.retries + 1
      ..status = SupplyTaskStatus.queued;
    if (e.retries >= 3) {
      await failExhausted(taskId, '连续失败/抢占 ${e.retries} 次（毒丸防线）');
      return false;
    }
    await _persist();
    return true;
  }

  /// 拉取（M5：callerKey 过滤——只能见自己的任务）。
  Future<SupplyTaskEntry?> statusFor(String taskId,
      {required String callerKey}) async {
    await _load();
    final e = _byId(taskId);
    if (e == null || e.callerKey != callerKey) return null;
    return e;
  }

  /// Pull 交付确认（真理源）：身份匹配才置 delivered。
  Future<bool> markDelivered(String taskId,
      {required String callerKey}) async {
    final e = await statusFor(taskId, callerKey: callerKey);
    if (e == null) return false;
    e
      ..status = SupplyTaskStatus.delivered
      ..deliveredAtMs = DateTime.now().millisecondsSinceEpoch;
    await _persist();
    return true;
  }

  /// 撤销（queued 态可撤；身份匹配）。
  Future<bool> cancel(String taskId, {required String callerKey}) async {
    final e = await statusFor(taskId, callerKey: callerKey);
    if (e == null || e.status != SupplyTaskStatus.queued) return false;
    e.status = SupplyTaskStatus.expired;
    await _persist();
    return true;
  }

  /// 过期清账（消费契机沿调用；返回清理条数）。
  int purgeExpired() => _purgeExpired();

  int _purgeExpired() {
    final before = _entries.length;
    _entries.removeWhere((e) =>
        e.status == SupplyTaskStatus.queued && e.expired);
    return before - _entries.length;
  }

  SupplyTaskEntry? _byId(String taskId) =>
      _entries.where((e) => e.taskId == taskId).firstOrNull;

  /// 诊断：dump 内存态（排障用）。
  void debugDump(String tag) {
    debugPrint('[RESIDENCY] pool-dump[$tag]: entries=${_entries.length} '
        'loaded=$_loaded '
        '${_entries.map((e) => "${e.taskId.substring(0, 16)}…=${e.status.name}").join(", ")}');
  }

  /// 测试/诊断：重置内存态（不删盘文件）。
  void resetForTest() {
    _entries.clear();
    _loaded = false;
  }
}

