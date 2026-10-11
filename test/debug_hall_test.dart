import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/ui/services_hall_page.dart';

void main() {
  late Directory tempDir;
  late CowOverridesStore store;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hall_dbg');
    store = CowOverridesStore(dir: tempDir);
  });
  testWidgets('debug empty', (tester) async {
    await tester
        .pumpWidget(MaterialApp(home: ServicesHallPage(storeOverride: store)));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .toList();
    final names = <String>[];
    await tester.runAsync(() async {
      names.addAll(await store.overrideNames());
      await File('/tmp/hall_dump.txt')
          .writeAsString('TEXTS=${texts.join(' || ')}\nnames=$names');
    });
  });
  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });
}

