/// M4-T5 记忆看板单测（MemoryStore 注入 temp dir）：三 Tab 渲染（记忆/教训/
/// 审计）+ 条目编辑（锚点保留）/ 单条删除 / user 级粉碎 / 导出。
/// 纪律：同 settings_page_test——真实文件 I/O 经 [WidgetTester.runAsync]
/// 让路（settleIo 轮询），断言值先捕获再断言。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/sandbox/memory_store.dart';
import 'package:goodhub/ui/memory_board_page.dart';

void main() {
  late Directory tempDir;
  late MemoryStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mem_board_ui_t5');
    store = MemoryStore(dir: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> pumpBoard(WidgetTester tester) async {
    await tester.pumpWidget(
        MaterialApp(home: MemoryBoardPage(storeOverride: store)));
    await settleIo(tester);
  }

  Future<void> goTab(WidgetTester tester, int index) async {
    // TabBarView 页面惰性构建——点击 Tab 后给真实异步（listOpsLog 等）让路。
    await tester.tap(find.text(const ['记忆条目', '踩坑教训', '操作审计'][index]));
    await tester.pumpAndSettle();
    await settleIo(tester);
  }

  testWidgets('三 Tab 渲染：记忆条目 / 踩坑教训 / 操作审计（空态）', (tester) async {
    await pumpBoard(tester);
    expect(find.text('（暂无记忆条目——Agent 写入后将在此出现）'), findsOneWidget);

    await goTab(tester, 1);
    expect(find.text('（暂无教训条目）'), findsOneWidget);

    await goTab(tester, 2);
    expect(find.text('（暂无审计记录）'), findsOneWidget);
  });

  testWidgets('记忆条目渲染（最新在上 + 元信息行）+ 教训 Tab 隔离', (tester) async {
    await tester.runAsync(() async {
      await store.remember('用户偏好深色主题', tags: {'pref'});
      await store.addLesson('Gboard 中文模式输入面交人工', scope: 'srv:goodshare');
    });
    await pumpBoard(tester);

    expect(find.text('用户偏好深色主题'), findsOneWidget);
    expect(find.textContaining('mem_001 · user · [pref]'), findsOneWidget);
    expect(find.textContaining('srv:goodshare'), findsNothing,
        reason: '教训条目不串显记忆 Tab');

    await goTab(tester, 1);
    expect(find.text('Gboard 中文模式输入面交人工'), findsOneWidget);
  });

  testWidgets('编辑条目：改正文落库，锚点 id/scope 保留', (tester) async {
    final e = await tester.runAsync(
        () => store.remember('旧事实', scope: 'srv:goodshare'));
    await pumpBoard(tester);

    await tester.tap(find.byKey(Key('mb-edit-${e!.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('mb-edit-field')), '新事实正文');
    await tester.tap(find.byKey(const Key('mb-edit-save')));
    await settleIo(tester);

    List<MemoryEntry> saved = const [];
    await tester.runAsync(() async => saved = await store.listMemories());
    expect(saved.single.content, '新事实正文');
    expect(saved.single.scope, 'srv:goodshare', reason: '编辑不破坏作用域');
  });

  testWidgets('单条删除：确认弹卡 → 落库移除', (tester) async {
    final e = await tester.runAsync(() => store.remember('待删条目'));
    await pumpBoard(tester);

    await tester.tap(find.byKey(Key('mb-del-${e!.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mb-del-confirm')));
    await settleIo(tester);

    List<MemoryEntry> saved = const [];
    await tester.runAsync(() async => saved = await store.listMemories());
    expect(saved, isEmpty);
    expect(find.text('（暂无记忆条目——Agent 写入后将在此出现）'), findsOneWidget);
  });

  testWidgets('审计 Tab：JSONL 渲染 ok/error 标识', (tester) async {
    await tester.runAsync(() async {
      await store.audit(
          server: 'goodshare', tool: 'get_task', ok: true, durationMs: 20);
      await store.audit(
          server: 'local', tool: 'update_memory', ok: false, error: 'denied');
    });
    await pumpBoard(tester);
    await goTab(tester, 2);

    expect(find.textContaining('get_task @goodshare'), findsOneWidget);
    expect(find.textContaining('20ms'), findsOneWidget);
    expect(find.textContaining('update_memory @local'), findsOneWidget);
    expect(find.textContaining('error: denied'), findsOneWidget);
    expect(find.text('✓'), findsOneWidget);
    expect(find.text('✗'), findsOneWidget);
  });

  testWidgets('粉碎 user 级：确认弹卡 → srv 级保留', (tester) async {
    await tester.runAsync(() async {
      await store.remember('用户条目');
      await store.remember('服务条目', scope: 'srv:goodshare');
    });
    await pumpBoard(tester);

    await tester.tap(find.byKey(const Key('mb-purge')));
    await tester.pumpAndSettle();
    // P1-7：确认框文案去内部指称（user 级/srv: → 个人记忆/按服务绑定）。
    expect(find.text('粉碎全部个人记忆'), findsOneWidget);
    expect(find.textContaining('按服务绑定的记忆'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mb-purge-confirm')));
    await settleIo(tester);

    List<MemoryEntry> saved = const [];
    await tester.runAsync(() async => saved = await store.listMemories());
    expect(saved.single.scope, 'srv:goodshare');
  });

  testWidgets('初始化失败：错误可见 + 重试恢复（P1-7/P0-3 同口径）', (tester) async {
    final flaky = _FlakyMemoryStore(dir: tempDir);
    await tester.pumpWidget(
        MaterialApp(home: MemoryBoardPage(storeOverride: flaky)));
    await settleIo(tester);

    expect(find.textContaining('记忆库初始化失败'), findsOneWidget);
    expect(find.byKey(const Key('mb-retry')), findsOneWidget,
        reason: '失败态带重试入口，不甩原始异常了事');

    await tester.tap(find.byKey(const Key('mb-retry')));
    await settleIo(tester);
    expect(find.textContaining('记忆库初始化失败'), findsNothing);
    expect(find.text('（暂无记忆条目——Agent 写入后将在此出现）'), findsOneWidget);
  });

  testWidgets('审计 Tab 筛选（P1-7）：工具/服务名子串 + 仅看失败 + 计数 + 无匹配态',
      (tester) async {
    await tester.runAsync(() async {
      await store.audit(
          server: 'goodshare', tool: 'get_task', ok: true, durationMs: 20);
      await store.audit(
          server: 'local', tool: 'update_memory', ok: false, error: 'denied');
      await store.audit(server: 'goodshare', tool: 'list_items', ok: true);
    });
    await pumpBoard(tester);
    await goTab(tester, 2);
    expect(find.text('3 / 3 条'), findsOneWidget);

    // 工具名子串过滤（跨 tool/server 两列匹配）。
    await tester.enterText(find.byKey(const Key('ops-filter')), 'update');
    await tester.pump();
    expect(find.text('1 / 3 条'), findsOneWidget);
    expect(find.textContaining('update_memory @local'), findsOneWidget);
    expect(find.textContaining('get_task @goodshare'), findsNothing);

    // 清空 → 仅看失败。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ops-only-fail')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3 条'), findsOneWidget);
    expect(find.textContaining('update_memory @local'), findsOneWidget);
    expect(find.textContaining('get_task @goodshare'), findsNothing);

    // 无匹配空态（与「暂无审计记录」区分）。
    await tester.enterText(find.byKey(const Key('ops-filter')), 'zzz');
    await tester.pump();
    expect(find.text('（无匹配审计记录）'), findsOneWidget);
  });
}

/// 首调失败、之后正常的假记忆库（驱动初始化错误态 → 重试恢复闭环）。
class _FlakyMemoryStore extends MemoryStore {
  _FlakyMemoryStore({required super.dir});

  var failFirst = true;

  @override
  Future<List<MemoryEntry>> listMemories() async {
    if (failFirst) {
      failFirst = false;
      throw Exception('瞬时读取故障');
    }
    return super.listMemories();
  }
}
