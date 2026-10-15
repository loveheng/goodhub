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
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester
        .pumpWidget(MaterialApp(home: SettingsPage(storeOverride: store)));
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
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> enterVisible(WidgetTester tester, Finder finder, String text) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.enterText(finder, text);
  }

  testWidgets('空态渲染 + 新建覆写（setOverride 落库 + 列表出现）', (tester) async {
    await pumpSettings(tester);
    await scrollToCow(tester);
    expect(find.text('（暂无覆写——模板按 server 版生效）'), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('cow-new')));
    await enterVisible(tester, find.byKey(const Key('cow-new-name')), 'weekly_review');
    await enterVisible(tester, find.byKey(const Key('cow-new-content')), '新覆写正文');
    await tapVisible(tester, find.byKey(const Key('cow-create')));
    // 保存 = setOverride 真实文件写 + _reload 读
    await settleIo(tester);
    await scrollToCow(tester);

    expect(find.byKey(const Key('cow-item-weekly_review')), findsOneWidget);
    String? saved;
    await tester
        .runAsync(() async => saved = await store.overrideOf('weekly_review'));
    expect(saved, '新覆写正文');
  });

  testWidgets('列表渲染 + 编辑保存（setOverride 覆盖旧正文）', (tester) async {
    await tester.runAsync(() => store.setOverride('item_digest', '旧正文'));
    await pumpSettings(tester);
    await scrollToCow(tester);
    expect(find.byKey(const Key('cow-item-item_digest')), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('cow-edit-item_digest')));
    expect(find.byKey(const Key('cow-edit-field')), findsOneWidget);
    await enterVisible(tester, find.byKey(const Key('cow-edit-field')), '改后的正文');
    await tapVisible(tester, find.byKey(const Key('cow-save')));
    await settleIo(tester);
    await scrollToCow(tester);

    String? saved;
    await tester
        .runAsync(() async => saved = await store.overrideOf('item_digest'));
    expect(saved, '改后的正文');
    expect(find.byKey(const Key('cow-edit-field')), findsNothing,
        reason: '保存后退出编辑态');
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
    await tester
        .runAsync(() async => saved = await store.overrideOf('item_digest'));
    expect(saved, '旧正文', reason: '空正文被拒，旧覆写保持');
    expect(find.textContaining('覆写正文不能为空'), findsOneWidget,
        reason: 'SnackBar 提示');
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
    expect(
      find.textContaining('关闭——开启后 PC 经 Streamable HTTP'),
      findsOneWidget,
    );
    expect(
      find.textContaining('⚠ 开启后同一局域网的 PC 可经 :8766'),
      findsOneWidget,
      reason: '局域网暴露风险文案必须常驻',
    );
  });
}
