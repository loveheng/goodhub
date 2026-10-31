import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_asset_manager.dart';
import 'package:goodhub/ui/sections/on_device_model_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<bool> fakeStatus(bool exempt) async => exempt;
  Future<bool> fakeRequest(bool result) async => result;

  /// 造「已安装」态：引导行仅在已装/已选模型时展示（S3-5 守卫——查询失败
  /// 被通道吞成 false，守卫防测试环境懒构建布局位移殃及同页其他面板测试）。
  late Directory tmp;
  late OnDeviceAssetManager assetsWithInstalledModel;

  setUp(() async {
    // _refresh 先读 Selection（SharedPreferences）再查 isInstalled——
    // 测试环境无插件通道，不 mock 则整段 catch、_installed 永远为空。
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('odms-battery-test');
    final support = Directory('${tmp.path}/support');
    // isInstalled 廉价检查 = 目录 + `.asset-meta.json` 在场即视为已装。
    final modelDir = Directory(
        '${support.path}/models/qwen3_1_7b-geniex_qairt-w4a16');
    await modelDir.create(recursive: true);
    await File('${modelDir.path}/.asset-meta.json').writeAsString('{}');
    assetsWithInstalledModel = OnDeviceAssetManager.forTest(
      supportDirResolver: () async => support,
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Widget host(WidgetTester tester, Widget child) {
    // 大视口：ListView 懒构建只建视口内子项——段内模型目录行增高后白名单
    // 引导行被推出首屏构建窗 → finder 0 命中假失败（同 byok_panel_test 口径）。
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: Scaffold(body: ListView(children: [child])),
    );
  }

  /// runAsync 轮询：_refresh 的真实文件 IO（Directory.exists）在 fakeAsync
  /// 区内仅 runAsync 下落定——纯 pumpAndSettle 等不到 `_installed` 回填。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
  }

  testWidgets('已装模型 + 未加白名单：显引导行，点「去设置」发起申请并复查', (tester) async {
    var requestCalls = 0;
    await tester.pumpWidget(host(tester, OnDeviceModelSection(
      assetManager: assetsWithInstalledModel,
      onFlash: (_) {},
      batteryStatusOverride: () async {
        return requestCalls > 0; // 初始未加白（false）→ 申请后已加白
      },
      batteryRequestOverride: () async {
        requestCalls++;
        return true;
      },
    )));
    await settleIo(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('on-device-battery-exempt-request')),
        findsOneWidget);
    expect(find.textContaining('厂商省电机制'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('on-device-battery-exempt-request')));
    await tester.pumpAndSettle();

    expect(requestCalls, 1);
    // 申请后复查状态（requestCalls=1 → status 返回 true）→ 引导行收起
    expect(find.byKey(const ValueKey('on-device-battery-exempt-request')),
        findsNothing);
  });

  testWidgets('已加白名单时不显引导行', (tester) async {
    await tester.pumpWidget(host(tester, OnDeviceModelSection(
      assetManager: assetsWithInstalledModel,
      onFlash: (_) {},
      batteryStatusOverride: () => fakeStatus(true),
      batteryRequestOverride: () => fakeRequest(true),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('on-device-battery-exempt-request')),
        findsNothing);
  });

  testWidgets('未装模型时即使未加白也不显引导行（守卫：查询失败吞 false 防误显）', (tester) async {
    final emptyAssets = OnDeviceAssetManager.forTest(
      supportDirResolver: () async =>
          Directory('${tmp.path}/support-empty'),
    );
    await tester.pumpWidget(host(tester, OnDeviceModelSection(
      assetManager: emptyAssets,
      onFlash: (_) {},
      batteryStatusOverride: () => fakeStatus(false),
      batteryRequestOverride: () => fakeRequest(true),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('on-device-battery-exempt-request')),
        findsNothing);
    // 模型段主功能仍在（目录标题可见）
    expect(find.text('端侧模型'), findsOneWidget);
  });

  testWidgets('白名单查询抛异常按未知处理——不显引导行不崩（面板主功能不受阻）', (tester) async {
    await tester.pumpWidget(host(tester, OnDeviceModelSection(
      assetManager: assetsWithInstalledModel,
      onFlash: (_) {},
      batteryStatusOverride: () => throw Exception('channel unavailable'),
      batteryRequestOverride: () => fakeRequest(true),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('on-device-battery-exempt-request')),
        findsNothing);
    expect(find.text('端侧模型'), findsOneWidget);
  });
}
