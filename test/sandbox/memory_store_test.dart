import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/sandbox/memory_store.dart';

void main() {
  Future<Directory> tmpDir() => Directory.systemTemp
      .createTemp('memory_store_test')
      .then((d) async {
    addTearDown(() async {
      if (await d.exists()) await d.delete(recursive: true);
    });
    return d;
  });

  group('memory.md / lessons.md（FC1 锚点条目面）', () {
    test('写 → 新实例读回：锚点解析 + id 单调 + 字段保真（lessons 装载坑对照用例）',
        () async {
      final dir = await tmpDir();
      final fixed = DateTime.fromMillisecondsSinceEpoch(1760155200000);
      final s = MemoryStore(dir: dir, clock: () => fixed);

      final e1 = await s.remember('用户偏好深色主题', tags: {'pref', 'ui'});
      final e2 = await s.remember('任务先认领再推理');
      expect(e1.id, 'mem_001');
      expect(e1.ts, 1760155200000);
      expect(e2.id, 'mem_002');

      // 写 → 新实例 → 读回：抓装载体空转的关键形态（lessons 持久化教训）。
      final s2 = MemoryStore(dir: dir);
      final list = await s2.listMemories();
      expect(list, hasLength(2));
      expect(list[0].id, 'mem_001');
      expect(list[0].tags, {'pref', 'ui'});
      expect(list[0].content, '用户偏好深色主题');
      expect(list[0].ts, 1760155200000);
      expect(list[1].id, 'mem_002');
      expect(list[1].tags, isEmpty);

      // lessons 独立文件同格式（D5），互不串扰。
      final l1 = await s.addLesson('并发裸写会丢数据');
      expect(l1.id, 'mem_001');
      final lessons = await s2.listLessons();
      expect(lessons, hasLength(1));
      expect(lessons.single.content, '并发裸写会丢数据');
      expect(await s2.listMemories(), hasLength(2));
      expect(File('${dir.path}/lessons.md').existsSync(), isTrue);
    });

    test('并发 remember 串行落盘：FIFO 有序 + id 无冲突', () async {
      final dir = await tmpDir();
      final s = MemoryStore(dir: dir);

      await Future.wait([
        for (var i = 0; i < 10; i++) s.remember('fact-$i'),
      ]);

      final entries = await s.listMemories();
      expect(entries, hasLength(10));
      expect(entries.map((e) => e.id).toSet(), hasLength(10));
      for (var i = 0; i < 10; i++) {
        expect(entries[i].content, 'fact-$i', reason: '串行链应保持 FIFO 顺序');
        expect(entries[i].id, 'mem_${(i + 1).toString().padLeft(3, '0')}');
      }
    });

    test('空内容拒绝（禁静默）', () async {
      final dir = await tmpDir();
      final s = MemoryStore(dir: dir);
      await expectLater(s.remember('   '), throwsArgumentError);
    });

    test('无锚点手写内容不丢不炸，后续 id 从 mem_001 起', () async {
      final dir = await tmpDir();
      File('${dir.path}/memory.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('手写旧内容没有锚点\n');
      final s = MemoryStore(dir: dir);

      expect((await s.listMemories()).single.id, isNull);
      expect((await s.listMemories()).single.content, '手写旧内容没有锚点');

      final e = await s.remember('新事实');
      expect(e.id, 'mem_001');
      final list = await s.listMemories();
      expect(list, hasLength(2));
      expect(list[0].content, '手写旧内容没有锚点');
    });
  });

  group('memoryView（F4.2 预算截断）', () {
    test('整条目丢最旧、保底留最新（D6）、droppedCount 可观测', () async {
      final dir = await tmpDir();
      final s = MemoryStore(dir: dir);
      await s.remember('x' * 100);
      await s.remember('y' * 50);
      await s.remember('z' * 30);

      final v = await s.memoryView(budgetTokens: 90);
      expect(v.truncated, isTrue);
      expect(v.droppedCount, 1, reason: '90T 预算装得下 y*50 + z*30 = 80，只丢最旧 x*100');
      expect(v.entries, hasLength(2));
      expect(v.entries.first.content, 'y' * 50);
      expect(v.entries.last.content, 'z' * 30);
      expect(v.estimatedTokens, v.rendered.length);

      // 单条超预算仍保底留最新一条（kept 不为 0）。
      final v2 = await s.memoryView(budgetTokens: 10);
      expect(v2.entries.single.content, 'z' * 30);
      expect(v2.droppedCount, 2);
    });

    test('预算充足不截断；空库返回空视图', () async {
      final dir = await tmpDir();
      final s = MemoryStore(dir: dir);
      await s.remember('a' * 10);
      await s.remember('b' * 20);

      final v = await s.memoryView();
      expect(v.truncated, isFalse);
      expect(v.droppedCount, 0);
      expect(v.entries.map((e) => e.content), ['a' * 10, 'b' * 20]);
      expect(v.rendered, '${'a' * 10}\n\n${'b' * 20}');

      final empty = await MemoryStore(dir: await tmpDir()).memoryView();
      expect(empty.entries, isEmpty);
      expect(empty.rendered, isEmpty);
      expect(empty.truncated, isFalse);
    });
  });

  group('scope 三层归属（M4-D8）', () {
    test('srv 级写入/读回/锚点渲染；非法 scope 拒绝（禁静默）', () async {
      final dir = await tmpDir();
      final s = MemoryStore(dir: dir);
      final e =
          await s.remember('apply 要带 expected_version', scope: 'srv:goodshare');
      expect(e.scope, 'srv:goodshare');
      expect((await s.listMemories()).single.scope, 'srv:goodshare');
      expect(
        File('${dir.path}/memory.md').readAsStringSync(),
        contains('scope: srv:goodshare'),
      );
      await expectLater(s.remember('x', scope: 'global'), throwsArgumentError);
      await expectLater(
        s.addLesson('x', scope: 'srv:'),
        throwsArgumentError,
      );
    });

    test('视图装配：user 恒注入，serverScope 并入对应 srv 级', () async {
      final dir = await tmpDir();
      final s = MemoryStore(dir: dir);
      await s.remember('偏好深色主题');
      await s.remember('goodshare 教训 A', scope: 'srv:goodshare');
      await s.remember('todo 教训 B', scope: 'srv:todo');

      final userOnly = await s.memoryView();
      expect(userOnly.entries.single.content, '偏好深色主题');

      final withGs = await s.memoryView(serverScopes: ['goodshare']);
      expect(withGs.entries.map((e) => e.content).toList(),
          ['偏好深色主题', 'goodshare 教训 A']);

      final withTodo = await s.memoryView(serverScopes: ['todo']);
      expect(withTodo.entries.last.content, 'todo 教训 B');
    });

    test('purgeServerScope：跨 memory+lessons 清该 srv 级，user/其他 srv 不动', () async {
      final dir = await tmpDir();
      final s = MemoryStore(dir: dir);
      await s.remember('偏好');
      await s.remember('gs 事实', scope: 'srv:goodshare');
      await s.addLesson('gs 教训', scope: 'srv:goodshare');
      await s.addLesson('todo 教训', scope: 'srv:todo');

      expect(await s.purgeServerScope('goodshare'), 2);
      expect((await s.listMemories()).single.content, '偏好');
      expect((await s.listLessons()).single.content, 'todo 教训');
      expect(await s.purgeServerScope('not-exist'), 0);
    });

    test('旧格式锚点（无 scope 段）解析缺省 user（容错）', () async {
      final dir = await tmpDir();
      File('${dir.path}/memory.md')
        ..createSync(recursive: true)
        ..writeAsStringSync(
            '<!-- id: mem_001, tags: [pref], ts: 1760155200000 -->\n旧格式条目\n');
      final s = MemoryStore(dir: dir);
      final e = (await s.listMemories()).single;
      expect(e.id, 'mem_001');
      expect(e.scope, 'user');
      expect(e.tags, {'pref'});
      expect(e.content, '旧格式条目');
    });
  });

  group('ops.log（JSONL 审计 + 10MB 单代轮转）', () {
    test('审计追加 + 超限轮转：行数守恒、JSONL 可解析、单代替换', () async {
      final dir = await tmpDir();
      final fixed = DateTime.fromMillisecondsSinceEpoch(1760155200000);
      final s = MemoryStore(
        dir: dir,
        opsLogMaxBytes: 200,
        clock: () => fixed,
      );
      const n = 6;
      for (var i = 0; i < n; i++) {
        await s.audit(
          server: 'goodshare',
          tool: 'tool_$i',
          ok: i != 2,
          durationMs: i * 10,
          error: i == 2 ? 'boom' : null,
        );
      }

      final log = File('${dir.path}/ops.log');
      final rotated = File('${dir.path}/ops.log.1');
      expect(await rotated.exists(), isTrue, reason: '200B 上限下 6 条必触发轮转');

      final lines = [
        ...await rotated.readAsLines(),
        ...await log.readAsLines(),
      ].where((l) => l.isNotEmpty).toList();
      final records =
          lines.map((l) => jsonDecode(l) as Map<String, Object?>).toList();
      // 单代滚动语义（§11「保留 1 代」）：留存行必须是全序列的时序后缀——
      // 最旧代按设计被第二次轮转覆盖退出，轮转点由行实际字节数决定，不锚定。
      const allTools = ['tool_0', 'tool_1', 'tool_2', 'tool_3', 'tool_4', 'tool_5'];
      expect(records.map((r) => r['tool']),
          allTools.sublist(allTools.length - records.length));
      expect(await rotated.readAsLines(), everyElement(isNotEmpty),
          reason: '备份代与当前档两档都应有内容');
      expect(await log.readAsLines(), everyElement(isNotEmpty));

      // 字段保真抽查（D7）：error 仅失败记录携带，durationMs 照实。
      final boom = records.firstWhere((r) => r['tool'] == 'tool_2');
      expect(boom['ok'], false);
      expect(boom['error'], 'boom');
      expect(boom['durationMs'], 20);
      final okRecord = records.firstWhere((r) => r['tool'] == 'tool_1');
      expect(okRecord['ok'], true);
      expect(okRecord.containsKey('error'), isFalse);
    });

    test('audit 失败路径之外：sweepStartup 清残留 tmp + 启动轮转（§11）', () async {
      final dir = await tmpDir();
      final staleTmp = File('${dir.path}/memory.md.tmp')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"半程崩溃残留');
      File('${dir.path}/ops.log').writeAsStringSync('x' * 500); // 超过 200B 上限

      final s = MemoryStore(dir: dir, opsLogMaxBytes: 200);
      await s.sweepStartup();
      await s.sweepStartup(); // 幂等

      expect(await staleTmp.exists(), isFalse, reason: '残留 tmp 应被清扫');
      expect(await File('${dir.path}/ops.log.1').exists(), isTrue,
          reason: '启动时超限旧档应完成轮转');
      expect((await s.listMemories()), isEmpty, reason: '清扫不得触碰正常数据');
    });
  });
}
