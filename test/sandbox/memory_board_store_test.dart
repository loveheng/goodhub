/// M4-T5 记忆看板 store 增量单测：条目编辑（锚点保留/ts 刷新）/ 单条删除 /
/// user 级全量粉碎 / ops.log 容错读取 / 导出原文含锚点。
/// 编辑面纪律（T1 注记）：读路径不缓存，全部真实文件 I/O。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/sandbox/memory_store.dart';

void main() {
  late Directory tmp;
  late MemoryStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mem_board_t5');
    store = MemoryStore(dir: tmp, clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000));
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('updateEntry：改正文保锚点（id/scope/tags 不变，ts 刷新）', () async {
    final e = await store.remember('旧事实', scope: 'srv:goodshare', tags: {'t1'});
    final ok = await store.updateEntry(e.id!, '新事实正文');
    expect(ok, isTrue);

    final list = await store.listMemories();
    expect(list.single.content, '新事实正文');
    expect(list.single.id, e.id, reason: '锚点完整性：编辑不换 id');
    expect(list.single.scope, 'srv:goodshare', reason: '编辑不破坏 D8 作用域');
    expect(list.single.tags, {'t1'});
    expect(list.single.ts, 1700000000000, reason: 'ts 刷新为编辑时刻（固定钟）');
  });

  test('updateEntry：不存在返回 false；lessons 文件隔离编辑', () async {
    await store.remember('记忆条');
    final l = await store.addLesson('教训条');
    expect(await store.updateEntry('mem_999', 'x'), isFalse);
    expect(await store.updateEntry(l.id!, '教训改', lessons: true), isTrue);

    final lessons = await store.listLessons();
    final memories = await store.listMemories();
    expect(lessons.single.content, '教训改');
    expect(memories.single.content, '记忆条', reason: 'lessons 编辑不串写 memory');
  });

  test('deleteEntry：单条删除返回真；不存在返回假', () async {
    final a = await store.remember('条A');
    await store.remember('条B');
    expect(await store.deleteEntry(a.id!), isTrue);
    expect((await store.listMemories()).map((e) => e.content), ['条B']);
    expect(await store.deleteEntry(a.id!), isFalse);
  });

  test('purgeUserScope：仅清 user 级，srv 级保留（memory+lessons 双文件）',
      () async {
    await store.remember('用户偏好');
    await store.remember('服务绑定', scope: 'srv:goodshare');
    await store.addLesson('用户教训');
    await store.addLesson('服务教训', scope: 'srv:other');

    final purged = await store.purgeUserScope();
    expect(purged, 2);

    expect((await store.listMemories()).single.scope, 'srv:goodshare');
    expect((await store.listLessons()).single.scope, 'srv:other');
  });

  test('listOpsLog：JSONL 解析 + 倒序（最新在前）+ 脏行跳过', () async {
    await store.audit(
        server: 'goodshare', tool: 'get_task', ok: true, durationMs: 12);
    await store.audit(server: 'local', tool: 'update_memory', ok: false,
        error: 'boom');

    // 手写脏行混入（模拟崩溃半行）
    final f = File('${tmp.path}/ops.log');
    await f.writeAsString('${await f.readAsString()}{"ts":"broken"\n');

    final lines = await store.listOpsLog();
    expect(lines.length, 2, reason: '脏行跳过');
    expect(lines.first.tool, 'update_memory', reason: '最新在前');
    expect(lines.first.ok, isFalse);
    expect(lines.first.error, 'boom');
    expect(lines.last.tool, 'get_task');
    expect(lines.last.durationMs, 12);
  });

  test('exportAll：原文导出含锚点行（FC1 备份可恢复）；缺文件跳过', () async {
    await store.remember('导出条目', tags: {'tag'});
    final text = await store.exportAll();
    expect(text, contains('# 宿主记忆（memory.md）'));
    expect(text, contains('导出条目'));
    expect(text, contains('<!-- id: mem_001'), reason: '锚点行保留');

    final empty = MemoryStore(
        dir: await Directory.systemTemp.createTemp('mem_board_empty'),
        clock: () => DateTime.now());
    expect(await empty.exportAll(), isEmpty);
  });
}
