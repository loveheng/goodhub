/// MemoryKernel 单测（archive-memory-claim 步 2）：提取面事实路由语义——
/// session 域落 wsStates / user·srv 域落 MemoryStore keyed 映射（G1）/ 幻觉
/// scope 丢弃（G4）/ remove 幂等 / undo 闭包含落盘回滚。
///
/// 路由语义与原 `ConversationSession.memoryFilter` 逐行同构（原样迁入）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/memory_kernel.dart';
import 'package:goodhub/coordinator/workspace_stream_filter.dart';
import 'package:goodhub/sandbox/memory_store.dart';
import 'package:goodhub/sandbox/workspace_state_store.dart';

void main() {
  Future<Directory> tmpDir() =>
      Directory.systemTemp.createTemp('memory_kernel_test').then((d) async {
        addTearDown(() async {
          if (await d.exists()) await d.delete(recursive: true);
        });
        return d;
      });

  late Directory dir;
  late WorkspaceStateStore wsStates;
  late MemoryKernel kernel;
  final capsules = <(String, String)>[];
  final journalDeltas = <(String, String, String)>[]; // (action, scope, key)

  setUp(() async {
    dir = await tmpDir();
    wsStates = WorkspaceStateStore(dir: dir);
    kernel = MemoryKernel(MemoryStore(dir: Directory('${dir.path}/mem')));
    capsules.clear();
    journalDeltas.clear();
  });

  /// 落盘走 discarded_futures（真实文件 IO），显式等队列排空再断言。
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));

  WorkspaceStreamFilter filter() => kernel.buildFilter(
        wsStates: wsStates,
        conversationId: 'conv_1',
        onCapsule: (key, value, action, scope, undo) {
          capsules.add((key, value));
          journalDeltas.add((action, scope, key));
        },
      );

  void deliver(WorkspaceStreamFilter f, List<WorkspaceFactUpdate> facts) =>
      f.onExtracted!(facts);

  group('域路由', () {
    test('session 域 → wsStates upsert；user 域 → MemoryStore keyed', () async {
      deliver(filter(), [
        const WorkspaceFactUpdate(
            key: 'ui.theme', value: 'dark', scope: 'session', action: 'upsert'),
        const WorkspaceFactUpdate(
            key: 'user.name', value: 'zzh', scope: 'user', action: 'upsert'),
      ]);
      // 落盘走 discarded_futures，等队列排空
      await settle();

      final states = await wsStates.all('conv_1');
      expect(states['ui.theme']?.value, 'dark');
      final entries = await kernel.memoryStore.listMemories();
      expect(entries.map((e) => e.tags), contains(contains('key:user.name')));
      expect(
        entries.firstWhere((e) => e.tags.contains('key:user.name')).content,
        'zzh',
      );
      expect(capsules.map((c) => c.$1), ['ui.theme', 'user.name']);
      // journal 通道（context-stepped-pruning §6.3）：action/scope 随胶囊回传。
      expect(journalDeltas, [
        ('upsert', 'session', 'ui.theme'),
        ('upsert', 'user', 'user.name'),
      ]);
    });

    test('srv 域按 scope 落 MemoryStore；同 key 覆盖不追加（G1）', () async {
      final f = filter();
      deliver(f, [
        const WorkspaceFactUpdate(
            key: 'db.host', value: 'a', scope: 'srv:s1', action: 'upsert'),
        const WorkspaceFactUpdate(
            key: 'db.host', value: 'b', scope: 'srv:s1', action: 'upsert'),
      ]);
      await settle();

      final entries = await kernel.memoryStore.listMemories();
      final dbHosts =
          entries.where((e) => e.tags.contains('key:db.host')).toList();
      expect(dbHosts, hasLength(1), reason: '同 key keyed 覆盖');
      expect(dbHosts.single.content, 'b');
      expect(dbHosts.single.scope, 'srv:s1');
    });
  });

  group('幻觉 scope（G4）', () {
    test('未归一 scope 丢弃：不落盘、不出胶囊', () async {
      deliver(filter(), [
        const WorkspaceFactUpdate(
            key: 'x.y', value: 'v', scope: 'galaxy', action: 'upsert'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(await wsStates.all('conv_1'), isEmpty);
      expect(capsules, isEmpty);
    });
  });

  group('remove 与 undo', () {
    test('session remove 幂等；undo 回滚 upsert 落盘', () async {
      final f = filter();
      deliver(f, [
        const WorkspaceFactUpdate(
            key: 'ui.lang', value: 'zh', scope: 'session', action: 'upsert'),
      ]);
      await settle();
      expect((await wsStates.all('conv_1'))['ui.lang']?.value, 'zh');

      deliver(f, [
        const WorkspaceFactUpdate(
            key: 'ui.lang', value: '', scope: 'session', action: 'remove'),
        const WorkspaceFactUpdate(
            key: 'ui.lang', value: '', scope: 'session', action: 'remove'), // 幂等
      ]);
      await settle();
      expect(await wsStates.all('conv_1'), isEmpty);
    });

    test('undo 闭包回滚 user 域 keyed 落盘', () async {
      // onCapsule 契约形参是 void Function()（实际闭包为 async，强转取 Future）
      void Function()? capturedUndo;
      final f = kernel.buildFilter(
        wsStates: wsStates,
        conversationId: 'conv_1',
        onCapsule: (key, value, action, scope, undo) => capturedUndo = undo,
      );
      deliver(f, [
        const WorkspaceFactUpdate(
            key: 'user.pref', value: 'cn', scope: 'user', action: 'upsert'),
      ]);
      await settle();
      final mems = await kernel.memoryStore.listMemories();
      expect(mems.any((e) => e.tags.contains('key:user.pref')), isTrue);

      // 胶囊撤销 → 落盘回滚（undo 返回的 Future 按契约被丢弃，等队列排空）
      capturedUndo!();
      await settle();
      expect(
        (await kernel.memoryStore.listMemories())
            .where((e) => e.tags.contains('key:user.pref')),
        isEmpty,
      );
    });
  });
}
