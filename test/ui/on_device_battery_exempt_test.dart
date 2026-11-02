import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/sections/on_device_config_section.dart';

void main() {
  Future<bool> fakeStatus(bool exempt) async => exempt;
  Future<bool> fakeRequest(bool result) async => result;

  Widget host(WidgetTester tester, Widget child) {
    // 大视口：ListView 懒构建只建视口内子项。电池引导行需可见，给足高度。
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: Scaffold(body: ListView(children: [child])),
    );
  }

  testWidgets('未加白名单：显引导行，点「去设置」发起申请并复查', (tester) async {
    var requestCalls = 0;
    await tester.pumpWidget(host(tester, OnDeviceConfigSection(
      onFlash: (_) {},
      batteryStatusOverride: () async {
        return requestCalls > 0; // 初始未加白（false）→ 申请后已加白
      },
      batteryRequestOverride: () async {
        requestCalls++;
        return true;
      },
    )));
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
    await tester.pumpWidget(host(tester, OnDeviceConfigSection(
      onFlash: (_) {},
      batteryStatusOverride: () => fakeStatus(true),
      batteryRequestOverride: () => fakeRequest(true),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('on-device-battery-exempt-request')),
        findsNothing);
  });

  testWidgets('白名单查询抛异常按未知处理——不显引导行不崩（面板主功能不受阻）', (tester) async {
    await tester.pumpWidget(host(tester, OnDeviceConfigSection(
      onFlash: (_) {},
      batteryStatusOverride: () => throw Exception('channel unavailable'),
      batteryRequestOverride: () => fakeRequest(true),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('on-device-battery-exempt-request')),
        findsNothing);
    // 配置段主功能仍在（标题可见）
    expect(find.text('端侧模型配置'), findsOneWidget);
  });
}
