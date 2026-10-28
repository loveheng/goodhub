/// S1 注册中心契约（施工稿 `docs/design/arch-consolidation.md` §S1）：
/// ① 应用级状态单一实例（消费点不再就地构造）；
/// ② `*Override` 注入位优先；
/// ③ `resetAllForTest()` 复位缓存与注入位（防单测跨用例串扰）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/app/service_directory.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/coordinator/user_prompt_store.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';
import 'package:goodhub/sandbox/workspace_state_store.dart';

Future<Directory> _tmp() async {
  final d = await Directory.systemTemp.createTemp('service_directory_test');
  addTearDown(() => d.delete(recursive: true));
  return d;
}

void main() {
  setUp(resetAllForTest);
  tearDown(resetAllForTest);

  group('S1 注册中心 · override 与实例复用', () {
    test('注入位优先：override 非空时恒返回同一实例', () async {
      final dir = await _tmp();
      cowOverridesStoreOverride = CowOverridesStore(dir: dir);
      userGlobalPromptsStoreOverride = UserGlobalPromptsStore(dir: dir);

      final a = await cowOverridesStore();
      final b = await cowOverridesStore();
      expect(identical(a, b), isTrue, reason: '两次取用必须是同一实例');
      expect(identical(await userGlobalPromptsStore(),
          await userGlobalPromptsStore()), isTrue);
    });

    test('resetAllForTest 清空注入位与缓存：之后可取到新注入值', () async {
      final d1 = await _tmp();
      final d2 = await _tmp();
      cowOverridesStoreOverride = CowOverridesStore(dir: d1);
      final first = await cowOverridesStore();

      resetAllForTest();
      cowOverridesStoreOverride = CowOverridesStore(dir: d2);
      final second = await cowOverridesStore();

      expect(identical(first, second), isFalse,
          reason: '复位后取到的是新实例——缓存未跨用例串扰');
    });
  });

  group('S1 第二批 · ByokStore / WorkspaceStateStore', () {
    test('BYOK：注入位优先 + 同步访问器恒返同一实例', () async {
      byokStoreOverride = ByokStore();
      expect(identical(byokStore(), byokStore()), isTrue);

      resetAllForTest();
      final first = byokStore();
      resetAllForTest();
      expect(identical(first, byokStore()), isFalse, reason: '复位后可取新实例');
    });

    test('WS 状态库：注入位优先，两次取用同一实例', () async {
      final dir = await _tmp();
      workspaceStateStoreOverride = WorkspaceStateStore.underSupportDir(dir.path);
      final a = await workspaceStateStore();
      final b = await workspaceStateStore();
      expect(identical(a, b), isTrue);
    });
  });

  group('S1 契约 · 消费点不再就地构造', () {
    test('窗口层零构造（coordinator 侧兼容回退随 S2 profile 化退役）', () {
      final hits = <String>[];
      for (final entity in Directory('lib/ui').listSync(recursive: true)) {
        // 联调页按 §1.4 类别 3 豁免（非生产路径）。
        if (entity.path.endsWith('gateway_loop_debug_page.dart')) continue;
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          if (line.contains('CowOverridesStore(') ||
              line.contains('UserGlobalPromptsStore(') ||
              line.contains('ByokStore(') ||
              line.contains('WorkspaceStateStore(')) {
            hits.add('${entity.path}:${i + 1}');
          }
        }
      }
      expect(hits, isEmpty,
          reason: '窗口层禁就地构造受管 store——一律经注册中心取实例；'
              '（内核侧的 `storeProvider == null` 兼容回退由 S2 装配 profile 化收口）');
    });
  });
}
