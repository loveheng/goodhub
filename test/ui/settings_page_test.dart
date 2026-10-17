/// M3-T4 设置页（2026-10-16 由「服务大厅」改名）Skill 覆写管理面板单测
/// （CowOverridesStore 注入 temp dir）：
/// 列表渲染 / 编辑保存（setOverride 落库）/ 一键重置 / 新建覆写 / 空态。
/// 纪律：页面 _init 与 store 读写走**真实文件 I/O**——widget 测试 fake async
/// 不驱动真实事件，所有 store 操作与页内 I/O 等待一律经 [WidgetTester.runAsync]
/// 让路，断言值先捕获再在测试区断言。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/ui/settings_page.dart';

void main() {
  late Directory tempDir;
  late CowOverridesStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hall_t4');
    store = CowOverridesStore(dir: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// 真实 I/O 等待窗：页面 _init/_reload 与 store 读写走真实文件 I/O——
  /// fake async 不驱动真实事件，用 runAsync 轮询让真实事件循环完成后再收帧
  /// （固定 2s 预算，快路径毫秒级即完成，慢路径也不会假失败）。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(storeOverride: store)),
    );
    await settleIo(tester);
  }

  /// 面板重排（模型→节点→本地插件→网关→覆写→授权）后 cow 面板位于第五段：
  /// 先滚到可见，
  /// 否则 ListView 懒构建下 finder 匹配不到（点/断言全落空）。
  Future<void> scrollToCow(WidgetTester tester) async {
    await tester.dragUntilVisible(
      find.text('Skill 覆写管理'),
      find.byType(ListView).first,
      const Offset(0, -60),
      maxIteration: 50,
    );
    await tester.pumpAndSettle();
    // 真实文件 I/O 不经 fake async，须 runAsync 让路（本文件纪律）。Cow 面板
    // 滚动入场后才触发 _bootstrap 读盘——此处 flush，免其加载态卡住断言。
    await settleIo(tester);
  }

  /// 目标可能落在 ListView 懒构建视口外：已构建 → ensureVisible；未构建 →
  /// 先回列表顶部再向下逐屏找（finder 只匹配已构建 widget）。
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      return;
    }
    await tester.drag(find.byType(ListView).first, const Offset(0, 600));
    await tester.pumpAndSettle();
    if (finder.evaluate().isNotEmpty) return;
    await tester.dragUntilVisible(
      finder,
      find.byType(ListView).first,
      const Offset(0, -60),
      maxIteration: 50,
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> enterVisible(
    WidgetTester tester,
    Finder finder,
    String text,
  ) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.enterText(finder, text);
  }

  testWidgets('空态渲染 + 新建覆写（setOverride 落库 + 列表出现）', (tester) async {
    await pumpSettings(tester);
    await scrollToCow(tester);
    expect(find.text('（暂无覆写——模板按 server 版生效）'), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('cow-new')));
    await enterVisible(
      tester,
      find.byKey(const Key('cow-new-name')),
      'weekly_review',
    );
    await enterVisible(
      tester,
      find.byKey(const Key('cow-new-content')),
      '新覆写正文',
    );
    await tapVisible(tester, find.byKey(const Key('cow-create')));
    // 保存 = setOverride 真实文件写 + _reload 读
    await settleIo(tester);
    await scrollToCow(tester);

    expect(find.byKey(const Key('cow-item-weekly_review')), findsOneWidget);
    String? saved;
    await tester.runAsync(
      () async => saved = await store.overrideOf('weekly_review'),
    );
    expect(saved, '新覆写正文');
  });

  testWidgets('列表渲染 + 编辑保存（setOverride 覆盖旧正文）', (tester) async {
    await tester.runAsync(() => store.setOverride('item_digest', '旧正文'));
    await pumpSettings(tester);
    await scrollToCow(tester);
    expect(find.byKey(const Key('cow-item-item_digest')), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('cow-edit-item_digest')));
    expect(find.byKey(const Key('cow-edit-field')), findsOneWidget);
    await enterVisible(
      tester,
      find.byKey(const Key('cow-edit-field')),
      '改后的正文',
    );
    await tapVisible(tester, find.byKey(const Key('cow-save')));
    await settleIo(tester);
    await scrollToCow(tester);

    String? saved;
    await tester.runAsync(
      () async => saved = await store.overrideOf('item_digest'),
    );
    expect(saved, '改后的正文');
    expect(
      find.byKey(const Key('cow-edit-field')),
      findsNothing,
      reason: '保存后退出编辑态',
    );
  });

  testWidgets('一键重置（确认弹卡 → reset 落库 → 列表消失）', (tester) async {
    await tester.runAsync(() => store.setOverride('item_digest', '正文'));
    await pumpSettings(tester);
    await scrollToCow(tester);

    await tapVisible(tester, find.byKey(const Key('cow-reset-item_digest')));
    expect(find.text('重置覆写'), findsOneWidget, reason: '确认弹卡先出');
    await tester.tap(find.widgetWithText(FilledButton, '重置'));
    await settleIo(tester);
    await scrollToCow(tester);

    List<String> names = const [];
    await tester.runAsync(() async => names = await store.overrideNames());
    expect(names, isEmpty);
    expect(find.text('（暂无覆写——模板按 server 版生效）'), findsOneWidget);
  });

  testWidgets('保存校验：空正文不落库（防呆 SnackBar）', (tester) async {
    await tester.runAsync(() => store.setOverride('item_digest', '旧正文'));
    await pumpSettings(tester);
    await scrollToCow(tester);
    await tapVisible(tester, find.byKey(const Key('cow-edit-item_digest')));
    await enterVisible(tester, find.byKey(const Key('cow-edit-field')), '   ');
    await tapVisible(tester, find.byKey(const Key('cow-save')));
    await tester.pump(); // SnackBar 出现帧（无真实 I/O——校验在写盘前拒绝）
    await tester.pump(const Duration(milliseconds: 300)); // SnackBar 退出动画收口

    String? saved;
    await tester.runAsync(
      () async => saved = await store.overrideOf('item_digest'),
    );
    expect(saved, '旧正文', reason: '空正文被拒，旧覆写保持');
    expect(
      find.textContaining('覆写正文不能为空'),
      findsOneWidget,
      reason: 'SnackBar 提示',
    );
  });

  testWidgets('PC 远程网关面板：默认关闭态 + Token 输入 + 风险文案', (tester) async {
    await pumpSettings(tester);
    await tester.dragUntilVisible(
      find.text('PC 远程网关'),
      find.byType(ListView).first,
      const Offset(0, -60),
      maxIteration: 50,
    );
    await tester.pumpAndSettle();

    expect(find.text('PC 远程网关'), findsOneWidget);
    expect(find.byKey(const Key('gateway-toggle')), findsOneWidget);
    expect(find.byKey(const Key('gateway-token')), findsOneWidget);
    // 未起服：running=false，展示「关闭」态与开启后效果说明。
    expect(find.textContaining('关闭——开启后 PC 经 Streamable HTTP'), findsOneWidget);
    expect(
      find.textContaining('⚠ 开启后同一局域网的 PC 可经 :8766'),
      findsOneWidget,
      reason: '局域网暴露风险文案必须常驻',
    );
  });

  testWidgets('关于面板：版本占位 + 检查更新常驻 + 长按标题唤出 debug 联调入口', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, find.byKey(const Key('about-title')));

    expect(find.text('关于'), findsOneWidget);
    // 检查更新是正式功能（release 也要能用），不藏进长按。
    expect(find.byKey(const Key('about-check-update')), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    // 测试环境无 PackageInfo 通道：版本按占位（宁空勿炸，不阻断面板）。
    expect(find.textContaining('GoodHub'), findsOneWidget);

    // 长按「关于」→ debug 联调菜单（flutter test 下 kDebugMode = true）。
    await tester.longPress(find.byKey(const Key('about-title')));
    await tester.pumpAndSettle();
    expect(find.text('网关/熔断联调'), findsOneWidget);
    // 注：M1 任务循环（ClaimLoopPage）已于 2026-10-17 归档至 archive/，
    // 其 debug 入口同步从本菜单摘除——菜单仅保留网关/熔断联调。
  });

  testWidgets('面板级错误隔离 + 重试恢复（ux-hardening P0-3）：一处初始化失败不再打死整页', (
    tester,
  ) async {
    final flaky = _FlakyCowStore(dir: tempDir);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(storeOverride: flaky)),
    );
    await settleIo(tester);
    await scrollToCow(tester);

    // 失败面板自持错误态（Rose 文案 + 重试），页面骨架照常——历史病是一处
    // 失败把整页替换成一句错误文本（其余面板可用也被打死）。
    expect(find.textContaining('覆写库读取失败'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget, reason: 'AppBar 在，页面没被打死');
    expect(find.byKey(const Key('cow-error-retry')), findsOneWidget);

    // 重试 → 恢复：错误消失，空态出现（面板自愈路径闭环）。
    await tapVisible(tester, find.byKey(const Key('cow-error-retry')));
    await settleIo(tester);
    await scrollToCow(tester);
    expect(find.textContaining('覆写库读取失败'), findsNothing);
    expect(find.text('（暂无覆写——模板按 server 版生效）'), findsOneWidget);
  });
  testWidgets('P2-1：覆写文件损坏 → 面板警示 + 备份路径明示（不再无声按空库）', (tester) async {
    // 真实文件 I/O 必须经 runAsync 让路（本文件纪律：fake async 不驱动真实事件）。
    await tester.runAsync(() async {
      await File('${tempDir.path}/cow_overrides.json')
          .writeAsString('{ 手改坏了的覆写文件');
    });
    final corrupt = CowOverridesStore(dir: tempDir);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(storeOverride: corrupt)),
    );
    await settleIo(tester);
    await scrollToCow(tester);

    expect(find.textContaining('覆写文件损坏，已备份为'), findsOneWidget);
    expect(
      find.textContaining('.corrupt-'),
      findsOneWidget,
      reason: '备份路径明示，用户可手动找回',
    );
    expect(
      find.text('（暂无覆写——模板按 server 版生效）'),
      findsOneWidget,
      reason: '按空库显示（行为不变），但有警示',
    );
  });
}

/// 首调失败、之后正常的假覆写库（驱动面板错误态 → 重试恢复闭环）。
class _FlakyCowStore extends CowOverridesStore {
  _FlakyCowStore({required super.dir});

  var failFirst = true;

  @override
  Future<List<String>> overrideNames() async {
    if (failFirst) {
      failFirst = false;
      throw Exception('瞬时磁盘故障');
    }
    return super.overrideNames();
  }
}
