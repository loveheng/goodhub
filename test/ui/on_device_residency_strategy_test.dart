import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/sections/on_device_config_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpSection(WidgetTester tester, List<String> flashes) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            OnDeviceConfigSection(
              onFlash: flashes.add,
              batteryStatusOverride: () async => true,
              batteryRequestOverride: () async => true,
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('切档探针3', (tester) async {
    final flashes = <String>[];
    await pumpSection(tester, flashes);
    await tester.tap(find.byKey(const ValueKey('on-device-residency-strategy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快速释放').last, warnIfMissed: true);
    await tester.pump(const Duration(milliseconds: 300));
    final prefs = await SharedPreferences.getInstance();
    // ignore: avoid_print
    print('stored=${prefs.getString('on_device.residency_strategy')} '
        'flashes=$flashes menuOpen=${find.text('快速释放').evaluate().length}');
  });
}
