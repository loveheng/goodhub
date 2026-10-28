/// S1 前置取证（epic `arch-review-2026-10` 副作用账的 `UNCERTAIN` 项）：
/// 应用级 store 的**多实例**是否在真实读写时序下造成「陈旧内存态覆盖」。
///
/// 结论分档由本件钉死，S1 按此排迁移顺序：
/// - `CowOverridesStore` / `UserGlobalPromptsStore`：读改写跨实例**非原子** → 丢更新（**高危**）
/// - `MemoryStore`：读改写整段入 `KeyedWriteQueue` → 跨实例不丢（**已自保，优先级递减**）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/coordinator/user_prompt_store.dart';
import 'package:goodhub/sandbox/memory_store.dart';

Future<Directory> _tmp() async {
  final d = await Directory.systemTemp.createTemp('multi_instance_test');
  addTearDown(() => d.delete(recursive: true));
  return d;
}

Map<String, Object?> _readJson(File f) =>
    jsonDecode(f.readAsStringSync()) as Map<String, Object?>;

void main() {
  group('取证一 · CowOverridesStore 多实例', () {
    test('实例 B 先读 → 实例 A 写 → 实例 B 写：A 的修改被静默覆盖', () async {
      final dir = await _tmp();
      final a = CowOverridesStore(dir: dir);
      final b = CowOverridesStore(dir: dir);

      await b.overrideNames(); // B 载入（空缓存），此后不再重读
      await a.setOverride('p', 'A 的覆写');
      await b.setOverride('q', 'B 的覆写');

      final onDisk = _readJson(File('${dir.path}/cow_overrides.json'));
      final overrides = onDisk['overrides'] as Map<String, Object?>? ?? {};
      final fresh = await CowOverridesStore(dir: dir).overrideNames();

      expect(identical(a, b), isFalse);
      expect(overrides.containsKey('q'), isTrue, reason: 'B 的写入生效');
      expect(overrides.containsKey('p'), isFalse,
          reason: 'A 的覆写被 B 的陈旧缓存整体覆盖——这就是静默丢失更新');
      expect(fresh, isNot(contains('p')));
    });

    test('对照：同一实例串行写 → 两项都在（丢失是实例级问题，不是写级问题）', () async {
      final dir = await _tmp();
      final a = CowOverridesStore(dir: dir);
      await a.setOverride('p', 'A');
      await a.setOverride('q', 'B');

      final overrides =
          (_readJson(File('${dir.path}/cow_overrides.json'))['overrides']
                  as Map<String, Object?>?)
                  ?.keys
                  .toSet() ??
              {};
      expect(overrides, {'p', 'q'});
    });

    test('并发写不撕裂：两实例同时 save，落盘仍是合法 JSON（队列有效）', () async {
      final dir = await _tmp();
      final a = CowOverridesStore(dir: dir);
      final b = CowOverridesStore(dir: dir);
      await Future.wait([
        a.setOverride('x', '1'),
        b.setOverride('y', '2'),
      ]);
      expect(() => _readJson(File('${dir.path}/cow_overrides.json')), returnsNormally,
          reason: 'KeyedWriteQueue 保住了物理写不交错——丢失发生在语义层，不是文件层');
    });
  });

  group('取证二 · UserGlobalPromptsStore 多实例', () {
    test('同样时序下条目被静默覆盖', () async {
      final dir = await _tmp();
      final a = UserGlobalPromptsStore(dir: dir);
      final b = UserGlobalPromptsStore(dir: dir);

      await b.load(); // B 载入空缓存
      await a.save(name: 'first', content: '第一条正文');
      await b.save(name: 'second', content: '第二条正文');

      final prompts = (_readJson(File('${dir.path}/$kUserGlobalPromptsFileName'))['prompts']
                  as Map<String, Object?>?)
                  ?.keys
                  .toSet() ??
              {};
      expect(prompts, contains('second'));
      expect(prompts, isNot(contains('first')),
          reason: 'first 被 B 的陈旧缓存整体覆盖');
    });
  });

  group('取证三 · MemoryStore 多实例（对照组）', () {
    test('读改写整段入队 → 跨实例不丢条目（已自保，S1 优先级递减）', () async {
      final dir = await _tmp();
      final a = MemoryStore.underSupportDir(dir.path);
      final b = MemoryStore.underSupportDir(dir.path);
      expect(identical(a, b), isFalse, reason: '确实是多实例（构造点未收敛）');

      await a.upsertFacts('k1', 'v1', scope: 'user');
      await b.upsertFacts('k2', 'v2', scope: 'user');

      final entries = await MemoryStore.underSupportDir(dir.path).listMemories();
      final contents = entries.map((e) => e.content).toSet();
      expect(contents, containsAll({'v1', 'v2'}),
          reason: 'MemoryStore 的读改写整段入 KeyedWriteQueue，跨实例安全');
    });
  });
}
