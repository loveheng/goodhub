import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/app/service_directory.dart';
import 'package:goodhub/llm/on_device_engine.dart';

/// 端侧供给面注册中心化验收钉（task-capability W1-S08）。
///
/// 立法 = `on-device-capability.md` §2「纳入注册中心、UI 零直连」：UI 层取
/// 端侧引擎一律经 service_directory.[onDeviceEngine]，禁 import
/// `on_device_engine_aidl.dart` 直连具体实现件。本钉机械扫描 lib/ui/：
/// 出现实现件 import 即红（实现件更换只许改 service_directory 一行）。
void main() {
  group('S08 端侧供给面注册中心化', () {
    test('门禁钉：lib/ui/** 禁 import on_device_engine_aidl', () {
      final offenders = <String>[];
      for (final f in Directory('lib/ui')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        for (final line in f.readAsLinesSync()) {
          if (line.contains('on_device_engine_aidl')) {
            offenders.add('${f.path}: ${line.trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'UI 禁直连端侧实现件，一律走 service_directory.onDeviceEngine：'
              '$offenders');
    });

    test('注册中心条目：override 注入位优先生效，缺省回落实现件单例', () {
      // 注入假件（最小实现面即编译期受接口约束）——override 非空恒返回。
      final injected = _StubSupplyFace();
      onDeviceEngineOverride = injected;
      expect(identical(onDeviceEngine, injected), isTrue);
      onDeviceEngineOverride = null;
      // 缺省回落实现件单例（loadedOnce 单装载纪律归实现件自管）。
      expect(onDeviceEngine, isNotNull);
    });
  });
}

class _StubSupplyFace implements OnDeviceSupplyFace {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
