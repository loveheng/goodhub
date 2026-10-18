/// ResourceCenterSection 段单测（resource-center M1-T2）。
///
/// 覆盖：清单/占用展示（RC5）/导入注入位/重命名/删除/外部打开注入位（RC6，
/// open 走临时副本不触平台）/面板级错误态（P0-3）。内核行为已在
/// test/resources/resource_store_test.dart 钉住——此处只闸段装配与交互分叉。
///
/// **IO 纪律（local_plugins_panel_test 同款）**：testWidgets 的 FakeAsync 区
/// 里真实 IO 永不完成——① 段 bootstrap 的 load 先在真实区 preload 短路；
/// ② 动作回调触发的内核 IO 用 [_settleUntil] 轮询（runAsync 真实延时 +
/// pump 排 microtask，直至条件达成）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/app/service_directory.dart' show resourceStoreOverride;
import 'package:goodhub/resources/resource_store.dart';
import 'package:goodhub/ui/resource_center_page.dart';
import 'package:goodhub/ui/sections/resource_center_section.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

Widget _errorRow(ConsoleTokens t, String message, VoidCallback onRetry,
        {ValueKey<String>? key}) =>
    Text(key: key, '⚠ $message');

const _ioDelay = Duration(milliseconds: 40);

Future<void> _pumpSection(
  WidgetTester tester, {
  required ResourceStore store,
  required String cachePath,
  Future<void> Function(String path)? opener,
  Future<String?> Function()? picker,
  List<String>? flashes,
}) async {
  // 预载：让 bootstrap 的 load() 在 _loaded 短路（FakeAsync 区真实 IO 永不完成）。
  await tester.runAsync(() => store.load());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ResourceCenterSection(
            storeOverride: store,
            cachePathOverride: cachePath,
            externalOpenerOverride: opener,
            filePickerOverride: picker,
            onFlash: (flashes ??= <String>[]).add,
            errorRowBuilder: _errorRow,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 点按段内动作按钮：pump 触发回调（FakeAsync 区）后，轮询等回调里的内核
/// IO 在真实区完成（runAsync 让路 + pump 排 microtask），[done] 达成即收。
Future<void> _tapAction(
  WidgetTester tester,
  Key key,
  bool Function() done, {
  int maxRounds = 30,
}) async {
  await tester.tap(find.byKey(key));
  await tester.pump();
  for (var i = 0; i < maxRounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(_ioDelay));
    await tester.pump();
    if (done()) {
      await tester.pump();
      return;
    }
  }
  await tester.pump();
}

/// 弹窗确认类动作：先 tap 触发并等弹窗渲染，再点 [confirmText] 后轮询 [done]。
Future<void> _tapConfirm(
  WidgetTester tester,
  Key key,
  String confirmText,
  bool Function() done,
) async {
  await tester.tap(find.byKey(key));
  await tester.pump();
  await tester.pump();
  await tester.tap(find.text(confirmText));
  await tester.pump();
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(() => Future<void>.delayed(_ioDelay));
    await tester.pump();
    if (done()) {
      await tester.pump();
      return;
    }
  }
}

void main() {
  late Directory tmp;
  late ResourceStore store;

  setUp(() {
    // 同步建目录：setUp 无 tester，避免在 FakeAsync 区 await 真实 IO。
    tmp = Directory.systemTemp.createTempSync('resource_section_test');
    store = ResourceStore.underSupportDir(tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('空态：0 项 + 已占用展示 + 空态引导文案', (tester) async {
    final flashes = <String>[];
    await _pumpSection(tester,
        store: store, cachePath: '${tmp.path}/cache', flashes: flashes);
    expect(find.text('0 项 · 已占用 0 B'), findsOneWidget);
    expect(find.textContaining('暂无资源'), findsOneWidget);
  });

  testWidgets('清单渲染：条目名 + headPreview + 占用合计（RC5）', (tester) async {
    await tester.runAsync(() => store.importContent('hello 摘要\nrest', 'a.txt'));
    await tester.runAsync(() => store.importContent('x' * 2048, 'b.txt'));
    final flashes = <String>[];
    await _pumpSection(tester,
        store: store, cachePath: '${tmp.path}/cache', flashes: flashes);
    expect(find.text('2 项 · 已占用 2.0 KB'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.textContaining('hello 摘要'), findsOneWidget);
  });

  testWidgets('导入注入位：picker 假件返回路径 → 内核入库 + flash 成功',
      (tester) async {
    final src = File('${tmp.path}/pick.txt');
    src.writeAsStringSync('picked content');
    final flashes = <String>[];
    await _pumpSection(tester,
        store: store,
        cachePath: '${tmp.path}/cache',
        picker: () async => src.path,
        flashes: flashes);
    await _tapAction(tester, const ValueKey('resource-import'),
        () => flashes.isNotEmpty);
    expect(store.entries.single.name, 'pick.txt');
    expect(flashes.single, contains('已导入'));
    expect(find.text('1 项 · 已占用 14 B'), findsOneWidget);
  });

  testWidgets('导入被内核拒收：结构化文案透出到 flash（错误可见性）', (tester) async {
    final flashes = <String>[];
    await _pumpSection(tester,
        store: store,
        cachePath: '${tmp.path}/cache',
        picker: () async => '/nonexistent/nope.txt',
        flashes: flashes);
    await _tapAction(tester, const ValueKey('resource-import'),
        () => flashes.isNotEmpty);
    expect(flashes.single, contains('导入失败'));
    expect(store.entries, isEmpty);
  });

  testWidgets('外部打开注入位：先 prepareExternalOpen 唯一副本再唤起（RC6）',
      (tester) async {
    final entry = (await tester
        .runAsync(() => store.importContent('内容', 'doc.md')))!;
    final opened = <String>[];
    await _pumpSection(tester,
        store: store,
        cachePath: '${tmp.path}/cache',
        opener: (p) async => opened.add(p));
    await _tapAction(
        tester, ValueKey('resource-open-${entry.id}'), () => opened.isNotEmpty);
    expect(opened, hasLength(1));
    expect(opened.single, contains('doc.md'));
    expect(opened.single, isNot(contains(entry.id))); // 不露 uuid 实体路径。
    expect(opened.single.startsWith('${tmp.path}/cache/external/'), isTrue);
  });

  testWidgets('删除：确认弹窗 → 清单移除 + 实体删除', (tester) async {
    final entry = (await tester.runAsync(() => store.importContent('x', 'f.txt')))!;
    await _pumpSection(tester,
        store: store, cachePath: '${tmp.path}/cache');
    final entityFile = File('${tmp.path}/resource_center/${entry.id}');
    await _tapConfirm(
      tester,
      ValueKey('resource-delete-${entry.id}'),
      '删除',
      () => store.entries.isEmpty && !entityFile.existsSync(),
    );
    expect(store.entries, isEmpty);
    expect(entityFile.existsSync(), isFalse);
  });

  testWidgets('重命名：弹窗输入新名 → 清单更新', (tester) async {
    final entry =
        (await tester.runAsync(() => store.importContent('x', 'old.txt')))!;
    await _pumpSection(tester,
        store: store, cachePath: '${tmp.path}/cache');
    await tester.tap(find.byKey(ValueKey('resource-rename-${entry.id}')));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'new.txt');
    await tester.tap(find.text('确定'));
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(_ioDelay));
      await tester.pump();
      if (store.byId(entry.id)!.name == 'new.txt') break;
    }
    expect(store.byId(entry.id)!.name, 'new.txt');
  });

  testWidgets('picker sheet：空库仍可直选系统文件（无「先导入」硬门槛）',
      (tester) async {
    await tester.runAsync(() => store.load());
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            key: const ValueKey('open-picker'),
            onPressed: () async {
              await showResourcePickerSheet(ctx, storeOverride: store);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-picker')));
    await tester.pumpAndSettle();
    expect(find.text('从系统选择…'), findsOneWidget);
    expect(find.textContaining('资源中心暂无资源'), findsOneWidget);
    // 旧口径「请先在设置导入」必须消失——先导入才能用属 UI 自加约束。
    expect(find.textContaining('请先在 设置'), findsNothing);
  });

  testWidgets('picker sheet：直选系统文件 → 经 import 入库 + collected=true',
      (tester) async {
    final src = File('${tmp.path}/pick.txt');
    src.writeAsStringSync('picked content');
    await tester.runAsync(() => store.load());
    ({String id, String name, bool collected})? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            key: const ValueKey('open-picker'),
            onPressed: () async {
              result = await showResourcePickerSheet(
                ctx,
                storeOverride: store,
                filePickerOverride: () async => src.path,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-picker')));
    await tester.pumpAndSettle();
    await _tapAction(
      tester,
      const ValueKey('pick-system'),
      () => result != null,
      maxRounds: 60, // 全量并发跑时 IO 排队更久，预算放宽防 flaky。
    );
    expect(result, isNotNull);
    expect(result!.name, 'pick.txt');
    expect(result!.collected, isTrue);
    expect(store.entries.single.id, result!.id);
  });

  testWidgets('picker sheet：直选被内核拒收 → sheet 内明示文案（闸门不旁路）',
      (tester) async {
    final bad = File('${tmp.path}/bad.bin');
    bad.writeAsBytesSync(<int>[0xFF, 0xFE, 0x00, 0x41]); // 非法 utf8 + NUL
    await tester.runAsync(() => store.load());
    ({String id, String name, bool collected})? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            key: const ValueKey('open-picker'),
            onPressed: () async {
              result = await showResourcePickerSheet(
                ctx,
                storeOverride: store,
                filePickerOverride: () async => bad.path,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-picker')));
    await tester.pumpAndSettle();
    await _tapAction(
      tester,
      const ValueKey('pick-system'),
      () => find.byKey(const ValueKey('pick-error')).evaluate().isNotEmpty,
      maxRounds: 60,
    );
    expect(find.byKey(const ValueKey('pick-error')), findsOneWidget);
    expect(result, isNull); // 被拒收不得进待发项。
    expect(store.entries, isEmpty);
  });

  testWidgets('picker sheet：直选命中同内容 → 复用既有条目（collected=false）',
      (tester) async {
    final src = File('${tmp.path}/pick.txt');
    src.writeAsStringSync('same body');
    await tester.runAsync(() => store.load());
    // 库内先存在同内容条目（「改名」产生的同名不同内容不属此列）。
    final first = (await tester.runAsync(() => store.import(src.path)))!;
    expect(first.reused, isFalse);

    ({String id, String name, bool collected})? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            key: const ValueKey('open-picker'),
            onPressed: () async {
              result = await showResourcePickerSheet(
                ctx,
                storeOverride: store,
                filePickerOverride: () async => src.path,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-picker')));
    await tester.pumpAndSettle();
    await _tapAction(
      tester,
      const ValueKey('pick-system'),
      () => result != null,
      maxRounds: 60,
    );
    expect(result!.id, first.entry.id);
    // 复用不入库 → 宿主不提示「已收入」、不提供撤销。
    expect(result!.collected, isFalse);
    expect(store.entries, hasLength(1));
  });

  testWidgets('资源中心页：抽屉入口 push 直达 + 段清单渲染（IA 归位）',
      (tester) async {
    // 页面经 ServiceDirectory 取单实例 store——注入避免触 path_provider。
    resourceStoreOverride = store;
    addTearDown(() => resourceStoreOverride = null);
    await tester.runAsync(() => store.importContent('hello 摘要', 'a.txt'));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            key: const ValueKey('open-page'),
            onPressed: () {
              Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) => ResourceCenterPage(
                      cachePathOverride: '${tmp.path}/cache'),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-page')));
    await tester.pumpAndSettle();
    expect(find.text('资源中心'), findsWidgets); // AppBar + 段标题。
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.textContaining('hello 摘要'), findsOneWidget);
    expect(find.byKey(const ValueKey('resource-import')), findsOneWidget);
  });
}
