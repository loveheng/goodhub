/// P0-A 文件级互斥回归（2026-10-17）：钉死「互斥粒度 = 文件路径，不是对象」。
///
/// 背景：`SequentialFileWriter` 的互斥链原是实例字段，而 `MemoryStore /
/// WorkspaceStateStore / ConversationStore` 的 `underSupportDir` 全是 factory——
/// 同路径的多个实例各持一条链，「读-改-写」复合单元交错即**静默丢失更新**
/// （生产装配点：main / gateway 重扫 / chat_page 每 Run / 记忆看板，共 5 处）。
///
/// 本组用例的断言对象都是**两个独立实例 + 同一份文件**：修复前必丢数据。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/storage/keyed_write_queue.dart';
import 'package:goodhub/core/storage/sequential_file_writer.dart';
import 'package:goodhub/sandbox/memory_store.dart';
import 'package:goodhub/sandbox/workspace_state_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('keyed_write_queue');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('KeyedWriteQueue（P0-A 文件级互斥）', () {
    test('1 跨实例 append 不丢：两个 writer 实例各追加 50 条 → 文件 100 行',
        () async {
      final f = File('${tmp.path}/ops.log');
      final w1 = SequentialFileWriter(f);
      final w2 = SequentialFileWriter(f);

      await Future.wait([
        for (var i = 0; i < 50; i++) w1.append('A$i\n'),
        for (var i = 0; i < 50; i++) w2.append('B$i\n'),
      ]);
      await w1.settled;

      expect((await f.readAsLines()).where((l) => l.isNotEmpty).length, 100,
          reason: '同路径的两实例必须共用一条链，交错追加即丢行');
    });

    test('2 跨实例读-改-写不丢：两个 MemoryStore 并发 remember → 两条都在',
        () async {
      final dir = Directory('${tmp.path}/memory');
      final a = MemoryStore(dir: dir);
      final b = MemoryStore(dir: dir); // 同路径第二个实例（factory 语义）

      await Future.wait([a.remember('事实A'), b.remember('事实B')]);
      await a.ioDrained;

      final list = await b.listMemories();
      expect(list.length, 2, reason: '复合读-改-写单元交错会整条覆盖');
      expect(list.map((e) => e.content).toSet(), {'事实A', '事实B'});
      expect(list.map((e) => e.id).toSet().length, 2,
          reason: 'id 由「读到的条目数」推导，重复 id 即证明读到了同一份旧内容');
    });

    test('3 跨实例 upsert 不丢：两个 WorkspaceStateStore 并发写不同 key → 都在',
        () async {
      final dir = Directory('${tmp.path}/workspace_states');
      final a = WorkspaceStateStore(dir: dir);
      final b = WorkspaceStateStore(dir: dir);

      await Future.wait([
        a.upsert('conv_1', 'k1', 'v1'),
        b.upsert('conv_1', 'k2', 'v2'),
      ]);
      await a.ioDrained;

      final all = await b.all('conv_1');
      expect(all.keys.toSet(), {'k1', 'k2'});
      expect(all['k1']?.value, 'v1');
      expect(all['k2']?.value, 'v2');
    });

    test('4 settled 跨实例可见：B 实例的链尾能等住 A 实例已入队的写', () async {
      final f = File('${tmp.path}/a.txt');
      final w1 = SequentialFileWriter(f);
      final w2 = SequentialFileWriter(f);

      final write = w1.write('hello'); // 故意不 await
      await w2.settled; // 另一实例的 settled = 同一条路径链

      expect(await f.readAsString(), 'hello');
      await write;
    });

    test('5 不同路径不互相串行（并行度未被误伤）', () async {
      final queue = KeyedWriteQueue.instance;
      final kA = KeyedWriteQueue.keyForPath('${tmp.path}/a.txt');
      final kB = KeyedWriteQueue.keyForPath('${tmp.path}/b.txt');

      final slow = queue.enqueue(kA, () async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final sw = Stopwatch()..start();
      await queue.enqueue(kB, () async {}); // 不同键，不应被 A 的慢任务挡住

      expect(sw.elapsedMilliseconds, lessThan(150),
          reason: '不同路径须并行；若共用一条全局链则会等到 300ms 之后');
      await slow;
    });

    test('6 惰性回收：排空后注册表不留 key', () async {
      final f = File('${tmp.path}/gc.txt');
      final w = SequentialFileWriter(f);
      await w.write('x');
      await w.settled;
      // 除名发生在链完成回调中，让出一个 microtask 再断言
      await Future<void>.delayed(Duration.zero);

      expect(KeyedWriteQueue.instance.keyCount, 0,
          reason: '长会话下不除名会让注册表无界增长');
    });

    test('7 失败不毒化队列：一次抛错后后续任务仍成功', () async {
      final f = File('${tmp.path}/poison.txt');
      final w = SequentialFileWriter(f);
      final key = KeyedWriteQueue.keyForPath(f.path);

      await w.write('a');
      await expectLater(
        KeyedWriteQueue.instance.enqueue(key, () async {
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      await w.write('b');

      expect(await f.readAsString(), 'b');
      await Future<void>.delayed(Duration.zero);
      expect(KeyedWriteQueue.instance.keyCount, 0);
    });

    test('8 ioDrained 两段都排空：复合单元完成后其内部的 writer 写也已落盘',
        () async {
      final dir = Directory('${tmp.path}/memory2');
      final a = MemoryStore(dir: dir);
      final b = MemoryStore(dir: dir);

      unawaited(a.remember('A'));
      unawaited(b.remember('B'));
      await a.ioDrained; // 复合链 + 三个 writer 链，两段都要排空

      // 直读文件（绕过 _enqueue），验证确实落盘而非仅内存态
      final raw = await File('${dir.path}/memory.md').readAsString();
      expect(raw, contains('A'));
      expect(raw, contains('B'));
      expect((await a.listMemories()).length, 2);
    });
  });
}
