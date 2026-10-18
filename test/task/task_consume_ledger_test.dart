/// 对账账本单测（M4-2）：记账 / 裁剪 / 持久化恢复 / 跨日重置 / 损坏兜底 / 清空 /
/// 按服务分组 / 按天过滤。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/task/task_consume_ledger.dart';

String _ymd(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ledger_test'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  TaskConsumeLedger ledger({int max = 20}) =>
      TaskConsumeLedger(dir: Directory('${dir.path}/l'), maxEntries: max);

  TaskLedgerEntry entry(
    String id, {
    bool ok = true,
    String? reason,
    String serverId = 'com.zzh.goodshare',
  }) =>
      TaskLedgerEntry(
        atMs: DateTime.now().millisecondsSinceEpoch,
        taskId: 't-$id',
        itemId: 'i-$id',
        action: 'llm_summarize',
        ok: ok,
        serverId: serverId,
        reason: reason,
      );

  test('记账：计数与明细同步累积', () async {
    final l = ledger();
    await l.load();
    await l.record(entry('1'));
    await l.record(entry('2', ok: false, reason: '推理失败'));
    expect(l.todayDone, 1);
    expect(l.todayFailed, 1);
    expect(l.entries.length, 2);
    expect(l.entries.last.reason, '推理失败');
    await l.ioDrained;
  });

  test('裁剪：超出 maxEntries 只留最近 N 条', () async {
    final l = ledger(max: 3);
    await l.load();
    for (var i = 0; i < 5; i++) {
      await l.record(entry('$i'));
    }
    expect(l.entries.length, 3);
    expect(l.entries.last.taskId, 't-4', reason: '保留最新');
    await l.ioDrained;
  });

  test('持久化：新实例 load 恢复计数与明细', () async {
    final first = ledger();
    await first.load();
    await first.record(entry('1'));
    await first.record(entry('2'));
    await first.ioDrained;

    final second = ledger();
    await second.load();
    expect(second.todayDone, 2);
    expect(second.entries.length, 2);
  });

  test('跨日：昨日明细不计入今日（todayDone 按自然日过滤）', () async {
    final f = File('${dir.path}/l/ledger.json');
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final payload = jsonEncode({
      'date': _ymd(DateTime.now()),
      'done': 1,
      'failed': 0,
      'entries': [
        {
          'at_ms': yesterday.millisecondsSinceEpoch,
          'task_id': 't-1',
          'item_id': 'i-1',
          'action': 'llm_summarize',
          'ok': true,
          'server_id': 'com.zzh.goodshare',
        },
      ],
    });
    await f.parent.create(recursive: true);
    await f.writeAsString(payload);

    final reloaded = ledger();
    await reloaded.load();
    expect(reloaded.todayDone, 0, reason: '昨日明细不计今日');
    expect(reloaded.entries.length, 1, reason: '全量保留供对账');
  });

  test('损坏文件：返空账不抛出（宁空勿炸）', () async {
    final f = File('${dir.path}/l/ledger.json');
    await f.parent.create(recursive: true);
    await f.writeAsString('{ not json');
    final l = ledger();
    await l.load();
    expect(l.entries, isEmpty);
    expect(l.todayDone, 0);
  });

  test('按服务分组：不同 serverId 进不同组', () async {
    final l = ledger();
    await l.load();
    await l.record(entry('1', serverId: 'com.zzh.goodshare'));
    await l.record(entry('2', serverId: 'com.other.plugin'));
    final groups = l.groupedByServer;
    expect(groups.keys, containsAll(['com.zzh.goodshare', 'com.other.plugin']));
    await l.ioDrained;
  });

  test('按天过滤：>今天的明细不出现在 recentEntries（保留持久化全量）', () async {
    final f = File('${dir.path}/l/ledger.json');
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    final payload = jsonEncode({
      'date': _ymd(now),
      'done': 2,
      'failed': 0,
      'entries': [
        {
          'at_ms': yesterday.millisecondsSinceEpoch,
          'task_id': 't-old',
          'item_id': 'i-old',
          'action': 'llm_summarize',
          'ok': true,
          'server_id': 'com.zzh.goodshare',
        },
        {
          'at_ms': now.millisecondsSinceEpoch,
          'task_id': 't-new',
          'item_id': 'i-new',
          'action': 'llm_summarize',
          'ok': true,
          'server_id': 'com.zzh.goodshare',
        },
      ],
    });
    await f.parent.create(recursive: true);
    await f.writeAsString(payload);

    final l = ledger();
    await l.load();
    final recent = l.recentEntries;
    expect(recent, hasLength(1), reason: '只可见今天');
    expect(recent.single.taskId, 't-new');
    // 持久化全量仍保留（不物理删历史）
    expect(l.entries, hasLength(2));
  });

  test('清空：计数与明细归零并落盘', () async {
    final l = ledger();
    await l.load();
    await l.record(entry('1'));
    await l.clear();
    expect(l.entries, isEmpty);
    expect(l.todayDone, 0);
    await l.ioDrained;

    final reloaded = ledger();
    await reloaded.load();
    expect(reloaded.entries, isEmpty);
  });
}
