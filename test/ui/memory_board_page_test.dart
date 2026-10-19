/// M4-T5 记忆看板单测（MemoryStore 注入 temp dir）：四 Tab 渲染（记忆/教训/
/// 审计/提示词）+ 条目编辑（锚点保留）/ 单条删除 / user 级粉碎 / 导出。
/// 纪律：同 settings_page_test——真实文件 I/O 经 [WidgetTester.runAsync]
/// 让路（settleIo 轮询），断言值先捕获再断言。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/coordinator/user_prompt_store.dart';
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
    await tester.tap(find.text(
        const ['记忆条目', '踩坑教训', '操作审计', '提示词'][index]));
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

  // —— Tab ④：提示词总览（prompt-mgmt §3.3 透明面）——

  testWidgets('提示词 Tab 基线态：官方预置恒可见（无会话也不空）', (tester) async {
    // 注入空 store（纯 Dart 环境无 path_provider 实现，与兄弟段测试同口径）。
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryBoardPage(
          storeOverride: store,
          userStoreOverride: UserGlobalPromptsStore(dir: tempDir),
          cowStoreOverride: CowOverridesStore(dir: tempDir),
        ),
      ),
    );
    await settleIo(tester);
    await goTab(tester, 3);

    // 官方预置 global（常驻）+ appScoped（连 goodshare 时注入）恒在——
    // 修复「基线态全是空」：最不可见的内置 prompt 首先可见。
    expect(find.text('ref-pipeline'), findsOneWidget);
    expect(find.text('task-discipline'), findsOneWidget);
    expect(find.text('goodshare-data'), findsOneWidget);
    expect(find.textContaining('拾贝是用户的收集器'), findsOneWidget);
    expect(find.text('官方预置'), findsNWidgets(3));
    expect(find.byKey(const Key('prompts-baseline-note')), findsOneWidget,
        reason: '无活态会话须明示展示的是官方预置 + 落盘基线而非实际注入面');
    expect(find.text('（暂无全局 Prompt——官方预置与用户自建将在此列出）'),
        findsNothing,
        reason: '官方预置 global 恒在，全局区不为空');
  });

  testWidgets('提示词 Tab：全局 Prompt 落盘渲染（user/<name> + Token 水位 + 正文）',
      (tester) async {
    final userStore = UserGlobalPromptsStore(dir: tempDir);
    await tester.runAsync(() async {
      await userStore.save(
        name: 'my-tone',
        content: '回答保持简洁克制。',
        description: '语气偏好',
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryBoardPage(
          storeOverride: store,
          userStoreOverride: userStore,
          cowStoreOverride: CowOverridesStore(dir: tempDir),
        ),
      ),
    );
    await settleIo(tester);
    await goTab(tester, 3);

    expect(find.text('user/my-tone'), findsOneWidget);
    expect(find.text('语气偏好'), findsOneWidget);
    expect(find.text('回答保持简洁克制。'), findsOneWidget);
    // 全局区：2 条官方预置（ref-pipeline/task-discipline）+ 1 条 user 自建，
    // 各带 Token 水位——精确断言 user 卡片的「9/300 Tokens · 更新于」。
    expect(find.textContaining('9/300 Tokens · 更新于'), findsOneWidget,
        reason: 'Token 水位与注册闸同源（core/tokens estimateTokens）');
    expect(find.text('用户'), findsOneWidget,
        reason: '来源徽标区分 user 自建与官方预置');
  });

  testWidgets('提示词 Tab：MCP 服务 Prompt 落盘基线（覆写正文可见 + 未覆写占位）',
      (tester) async {
    final cowStore = CowOverridesStore(dir: tempDir);
    await tester.runAsync(() async {
      await cowStore.setKnownVersion('weekly-review', '1.2.0');
      await cowStore.setOverride('weekly-review', '本地覆写正文');
      await cowStore.setKnownVersion('item-digest', '2.0.0'); // 无覆写
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryBoardPage(
          storeOverride: store,
          userStoreOverride: UserGlobalPromptsStore(dir: tempDir),
          cowStoreOverride: cowStore,
        ),
      ),
    );
    await settleIo(tester);
    await goTab(tester, 3);

    // 覆写模板：正文即生效内容（持久数据，直接可见）——不再显示占位空文。
    expect(find.text('cow/weekly-review'), findsOneWidget);
    expect(find.text('v1.2.0'), findsOneWidget);
    expect(find.text('本地覆写'), findsOneWidget);
    expect(find.text('本地覆写正文'), findsOneWidget);

    // 未覆写模板：正文来自服务端、不落盘——占位说明，不伪装成空。
    expect(find.text('cow/item-digest'), findsOneWidget);
    expect(find.text('v2.0.0'), findsOneWidget);
    expect(find.text('（正文来自服务端，未覆写时不落盘——连接后展示实际注入内容）'),
        findsOneWidget);
  });

  testWidgets('提示词 Tab：活态注册表面（global + appScoped 实际注入面）',
      (tester) async {
    final registry = SkillRegistry()..registerAll(builtinSkills());
    registry.register(
      Skill(
        name: 'cow/weekly-review',
        scope: SkillScope.appScoped,
        serverId: 'goodshare',
        description: '周回顾模板',
        content: '逐条回顾本周收集条目。',
        source: SkillSource.cow,
      ),
    );
    registry.register(
      Skill(
        name: 'user/tone',
        scope: SkillScope.global,
        description: '语气偏好',
        content: '回答保持简洁克制。',
        source: SkillSource.user,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryBoardPage(
          storeOverride: store,
          userStoreOverride: UserGlobalPromptsStore(dir: tempDir),
          cowStoreOverride: CowOverridesStore(dir: tempDir),
          skillsProvider: () => registry,
        ),
      ),
    );
    await settleIo(tester);
    await goTab(tester, 3);

    // global 面：官方预置 ×2 + user 自建（来源徽标区分）。
    expect(find.text('ref-pipeline'), findsOneWidget);
    expect(find.text('user/tone'), findsOneWidget);
    expect(find.text('回答保持简洁克制。'), findsOneWidget);
    expect(find.text('用户'), findsOneWidget);

    // appScoped 面：builtin（goodshare-data）与 CoW 同步产物同台展示。
    expect(find.text('goodshare-data'), findsOneWidget);
    expect(find.text('cow/weekly-review'), findsOneWidget);
    expect(find.text('CoW 同步'), findsOneWidget);
    expect(find.text('逐条回顾本周收集条目。'), findsOneWidget);
    expect(find.text('官方预置'), findsNWidgets(3));
    expect(find.byKey(const Key('prompts-baseline-note')), findsNothing,
        reason: '活态面展示实际注入面，不再展示落盘基线提示');
  });

  testWidgets('提示词 Tab：活态空注册表 → 两区空态（无基线回落）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryBoardPage(
          storeOverride: store,
          userStoreOverride: UserGlobalPromptsStore(dir: tempDir),
          cowStoreOverride: CowOverridesStore(dir: tempDir),
          skillsProvider: () => SkillRegistry(),
        ),
      ),
    );
    await settleIo(tester);
    await goTab(tester, 3);

    expect(find.text('（暂无全局 Prompt——官方预置与用户自建将在此列出）'),
        findsOneWidget);
    expect(find.text('（暂无 MCP 服务 Prompt——Tier 1 服务连接后经 CoW 同步注入）'),
        findsOneWidget);
    expect(find.byKey(const Key('prompts-baseline-note')), findsNothing,
        reason: '活态面（哪怕空的）不走落盘基线回落');
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
