import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R12 镜像（extensibility-hardening S2）：端侧引擎实现件 import 单点门禁。
///
/// 红线：lib 非白名单文件禁 import `on_device_engine_aidl.dart`——消费方一律经
/// 抽象件 `on_device_engine.dart`（sharedOnDeviceEngine 单例注册制，类型
/// OnDeviceSupplyFace）。与 arch-guard R12（pre-commit 侧）同规则；llm 域内
/// 具体类**类型引用**由 on_device_concrete_class_gate_test（W1-S09）把守，
/// 本钉把守 **import 边**。
void main() {
  test('门禁钉：实现件 import 仅限白名单（装配根 / 门面 / llm 域内登记件）', () {
    const whitelist = {
      'lib/main.dart',
      'lib/coordinator/on_device_admin.dart',
      'lib/llm/on_device_status_class.dart',
    };
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final normalized = f.path.replaceAll('\\', '/');
      if (whitelist.contains(normalized)) continue;
      if (normalized.startsWith('lib/llm/')) continue; // 实现件属地豁免
      for (final line in f.readAsLinesSync()) {
        final code = line.trim();
        if (code.startsWith('//') || code.startsWith('///')) continue;
        if (RegExp(r"""import\s+['"][^'']*on_device_engine_aidl\.dart['"];""")
            .hasMatch(code)) {
          offenders.add('${f.path}: ${code.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: '端侧引擎实现件 import 出白名单'
            '（消费方一律经 on_device_engine.dart 抽象件）：$offenders');
  });
}
