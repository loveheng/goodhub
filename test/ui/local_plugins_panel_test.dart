/// 本地插件面板 widget 测试（settings_page 本地插件段，2026-10-15 新增）：
/// Binder 发现项渲染（标题/包名/transportId/已挂载）+ 信任态 pill（同签名私有生态
/// 自动信任 / 第三方待信任按钮）+ 信任卡片确认后转「已信任」+ 包变更流热刷新
/// + 默认私有服务钉选（2026-10-16 方案 A：独立 radio 面板撤销，降级为卡片图钉）。
/// 纪律：store 读写走真实异步，全部经 [WidgetTester.runAsync] 让路（settleIo 轮询）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/tool_catalog.dart';
import 'package:goodhub/core/tool_visibility.dart';
import 'package:goodhub/mcp/default_private_server.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/trusted_plugins.dart';
import 'package:goodhub/ui/components/panel_error_row.dart';
import 'package:goodhub/ui/sections/local_plugins_section.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pin_harness.dart';

/// 回归用假目录：按 serverId 预设工具，不触真实挂载原语。
class _ToolFakeCatalog extends McpCatalog {
  _ToolFakeCatalog(this._tools)
      : super(endpointStore: ({String? supportPath}) async {
          throw UnsupportedError('假目录不走端点装配');
        });
  final Map<String, List<McpCatalogTool>> _tools;

  @override
  Future<List<McpCatalogTool>> loadServerTools(McpCatalogService s) async =>
      _tools[s.serverId] ?? const [];
}

void main() {
  late Directory tmp;

  final sameSig = LocalPluginInfo(
    serverId: 'priv',
    serverTitle: '私有插件',
    packageName: 'com.zzh.goodhub.priv',
    serviceClassName: 'com.zzh.goodhub.priv.PrivService',
    signatureSha256: 'deadbeef',
    sameSignature: true,
  );
  final thirdParty = LocalPluginInfo(
    serverId: 'ext',
    serverTitle: '外部插件',
    packageName: 'com.example.ext',
    serviceClassName: 'com.example.ext.ExtService',
    signatureSha256: 'cafe',
    sameSignature: false,
  );

  late List<LocalPluginInfo> discovered;
  late StreamController<void> changesCtrl;
  var scanCalls = 0;

  Future<List<LocalPluginInfo>> fakeScan() async {
    scanCalls++;
    return discovered;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TrustedPlugins.resetForTest();
    tmp = await Directory.systemTemp.createTemp('local_plugins_panel_test');
    discovered = [sameSig, thirdParty];
    changesCtrl = StreamController<void>.broadcast();
    scanCalls = 0;
  });

  tearDown(() async {
    await changesCtrl.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    // 直泵段（2026-11-02 能力中心拍板：本地插件卡自设置页迁入资源中心
    // 「节点与插件」tab——回归网直泵 section，注入位同构）。
    // 钉选回调经 [_PinHarness] 走真实持久化（读写 SharedPreferences）。
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          PinHarness(builder: (isDefaultPrivate, onPinToggle) => LocalPluginsSection(
            catalog: FakeCatalog(),
            scan: fakeScan,
            changes: changesCtrl.stream,
            isDefaultPrivate: isDefaultPrivate,
            onPinToggle: onPinToggle,
            onFlash: (_) {},
            errorRowBuilder: panelErrorRow,
          )),
        ]),
      ),
    ));
    await settleIo(tester);
  }

  /// 面板重排（2026-10-16 六段）后目标常落在 ListView 懒构建视口外：
  /// 已构建 → ensureVisible；未构建 → 先回列表顶部（内容下移）再向下逐屏找。
  /// （finder 只匹配已构建 widget，单向 dragUntilVisible 在目标位于上方时会超时。）
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

  testWidgets('渲染本地插件卡：标题/包名/transportId/已挂载', (tester) async {
    await pumpPanel(tester);

    expect(
      find.byKey(const Key('local-plugin-local:com.zzh.goodhub.priv_priv')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('local-plugin-local:com.example.ext_ext')),
      findsOneWidget,
    );
    expect(find.text('私有插件'), findsOneWidget);
    expect(find.textContaining('com.zzh.goodhub.priv'), findsOneWidget);
    expect(
      find.textContaining('local:com.zzh.goodhub.priv_priv'),
      findsOneWidget,
    );
    expect(find.text('已挂载（自动）'), findsNWidgets(2));
  });

  testWidgets('同签名插件显「私有生态 · 自动信任」，第三方显「待信任」+按钮',
      (tester) async {
    await pumpPanel(tester);

    expect(find.text('私有生态 · 自动信任'), findsOneWidget);
    expect(find.text('待信任'), findsOneWidget);
    expect(
      find.byKey(const Key('local-trust-local:com.example.ext_ext')),
      findsOneWidget,
    );
    // 仅第三方有「信任」按钮（同签名免确认，无按钮）。
    expect(find.text('信任'), findsOneWidget);
  });

  testWidgets('信任第三方插件：弹卡确认后转「已信任」', (tester) async {
    await pumpPanel(tester);
    expect(find.text('待信任'), findsOneWidget);

    await scrollTo(
        tester, find.byKey(const Key('local-trust-local:com.example.ext_ext')));
    await tester.tap(
      find.byKey(const Key('local-trust-local:com.example.ext_ext')),
    );
    await settleIo(tester);
    // 信任卡片弹窗。
    expect(find.text('信任本地插件？'), findsOneWidget);
    await tester.tap(find.text('信任并挂载'));
    await settleIo(tester);

    await scrollTo(tester, find.text('已信任'));
    expect(find.text('已信任'), findsOneWidget);
    expect(find.text('待信任'), findsNothing);
  });

  testWidgets('撤销信任：确认后第三方回落「待信任」（2026-10-16 自 ⚙ 迁入）',
      (tester) async {
    await pumpPanel(tester);
    // 跨用例隔离：[TrustedPlugins] 是进程内单例（缓存 SharedPreferences 句柄），
    // 「信任第三方插件」用例的信任态会残留到本用例。若已是已信任态（无信任
    // 按钮），先撤销回落「待信任」，保证本用例从干净起点出发。
    await scrollTo(
        tester, find.byKey(const Key('local-plugin-local:com.example.ext_ext')));
    if (find
        .byKey(const Key('local-trust-local:com.example.ext_ext'))
        .evaluate()
        .isEmpty) {
      await tester.tap(
          find.byKey(const Key('local-untrust-local:com.example.ext_ext')));
      await settleIo(tester);
      await tester.tap(find.widgetWithText(FilledButton, '撤销信任'));
      await settleIo(tester);
    }
    // 先建立信任态（信任卡确认后入白名单）。
    await scrollTo(
        tester, find.byKey(const Key('local-trust-local:com.example.ext_ext')));
    await tester
        .tap(find.byKey(const Key('local-trust-local:com.example.ext_ext')));
    await settleIo(tester);
    await tester.tap(find.text('信任并挂载'));
    await settleIo(tester);
    expect(find.text('已信任'), findsOneWidget);

    // 撤销入口只对第三方出现（同签名私有生态免确认，无撤销对象）。
    expect(
      find.byKey(const Key('local-untrust-local:com.example.ext_ext')),
      findsOneWidget,
    );
    await tester
        .tap(find.byKey(const Key('local-untrust-local:com.example.ext_ext')));
    await settleIo(tester);
    expect(find.text('撤销信任'), findsWidgets, reason: '撤销确认弹窗');
    await tester.tap(find.widgetWithText(FilledButton, '撤销信任'));
    await settleIo(tester);

    await scrollTo(tester, find.text('待信任'));
    expect(find.text('待信任'), findsOneWidget, reason: '已移出信任白名单');
    expect(find.text('已信任'), findsNothing);
    expect(
      find.byKey(const Key('local-untrust-local:com.zzh.goodhub.priv_priv')),
      findsNothing,
      reason: '同签名项无撤销入口',
    );
  });

  testWidgets('包变更流触发重扫热刷新', (tester) async {
    await pumpPanel(tester);
    expect(scanCalls, 1, reason: '初始拉扫一次');

    discovered = [sameSig]; // 卸载了第三方
    changesCtrl.add(null);
    await settleIo(tester);

    expect(scanCalls, greaterThan(1), reason: '包变更触发重扫');
    expect(
      find.byKey(const Key('local-plugin-local:com.example.ext_ext')),
      findsNothing,
      reason: '第三方已卸载不再出现',
    );
  });

  testWidgets('默认私有钉选（方案 A）：本地插件可钉选/取消（与端点同一默认键）',
      (tester) async {
    await pumpPanel(tester);
    expect(find.text('默认私有'), findsNothing);

    // 钉选同签名私有插件（serverId='priv'）。
    await scrollTo(
        tester, find.byKey(const Key('local-default-local:com.zzh.goodhub.priv_priv')));
    await tester
        .tap(find.byKey(const Key('local-default-local:com.zzh.goodhub.priv_priv')));
    await settleIo(tester);

    String? stored;
    await tester.runAsync(() async => stored = await readDefaultPrivateServerId());
    expect(stored, 'priv', reason: '本地插件 serverId 入统一默认键');
    expect(find.text('默认私有'), findsOneWidget);
    expect(find.byTooltip('取消默认私有服务'), findsOneWidget);

    // 再点取消：清键 + pill 消失。
    await tester
        .tap(find.byKey(const Key('local-default-local:com.zzh.goodhub.priv_priv')));
    await settleIo(tester);

    await tester.runAsync(() async => stored = await readDefaultPrivateServerId());
    expect(stored, isNull);
    expect(find.text('默认私有'), findsNothing);
  });

  testWidgets('本地插件卡工具列表可点开展开（2026-11-02 拆解归并回归）', (tester) async {
    // 自定义假目录：为 priv 插件返回两个工具，验证卡片内「工具」展开项可点开
    // （曾因 ExpansionTile 误置于 Expanded>Column>Row 致展开区高度被压成 0）。
    final catalog = _ToolFakeCatalog({
      'priv': [
        McpCatalogTool(
          name: 'echo',
          description: '',
          visibility: ToolVisibility.shared,
          declared: true,
        ),
        McpCatalogTool(
          name: 'p1',
          description: '',
          visibility: ToolVisibility.private,
          declared: true,
        ),
      ],
    });
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          LocalPluginsSection(
            catalog: catalog,
            scan: () async => [sameSig],
            changes: const Stream<void>.empty(),
            isDefaultPrivate: (_) => false,
            onPinToggle: (id, label, isDefault) async {},
            onFlash: (_) {},
            errorRowBuilder: panelErrorRow,
          ),
        ]),
      ),
    ));
    await settleIo(tester);

    // 折叠态：展开区收起（AnimatedCrossFade 的隐藏子树仍在 element 树内、仅
    // opacity 0 + IgnorePointer，故不能断言 findsNothing——用 crossFadeState）。
    final crossFade = find.byType(AnimatedCrossFade);
    expect(
      tester.widget<AnimatedCrossFade>(crossFade.first).crossFadeState,
      CrossFadeState.showFirst,
    );
    expect(find.textContaining('点击展开'), findsOneWidget);
    // 卡头 = 展开器（2026-11-02 卡头合并改版）：点卡头任意处（包名文本）展开。
    await tester.tap(find.textContaining('com.zzh.goodhub.priv'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedCrossFade>(crossFade.first).crossFadeState,
      CrossFadeState.showSecond,
      reason: '点卡头后展开',
    );
    expect(find.text('echo'), findsOneWidget, reason: '展开后可见工具');
    expect(find.text('p1'), findsOneWidget, reason: '展开后可见工具');
    // 工具行渲染在卡头信息行之下（真展开，非叠在头部）。
    final header = tester.getTopLeft(find.textContaining('com.zzh.goodhub.priv'));
    final echo = tester.getTopLeft(find.text('echo'));
    expect(echo.dy, greaterThan(header.dy), reason: '工具行应在卡头之下');
    // 展开后示意收敛（信息行不再提示「点击展开」）。
    expect(find.textContaining('点击展开'), findsNothing);
    // 概要并入卡头信息行：2 个工具中 1 个显式 shared。
    expect(find.textContaining('共享 1 / 共 2 个工具'), findsOneWidget);
  });
}
