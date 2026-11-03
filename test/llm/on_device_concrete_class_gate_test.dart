import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 端侧件持具体类收口门禁钉（task-capability W1-S09）。
///
/// 红线：端侧消费件（capability / adapter 等）持引擎一律经接口
/// （`OnDeviceEngine` / `OnDeviceSupplyFace`），禁持有具体实现类
/// `AidlOnDeviceEngine`——本钉机械扫描 lib/llm/：实现类名只许出现在其
/// 定义文件（on_device_engine_aidl.dart）与文件头说明注释之外**不得作为
/// 类型引用**（`final AidlOnDeviceEngine` / `AidlOnDeviceEngine _x` / 参数位）。
void main() {
  test('门禁钉：lib/llm 内 AidlOnDeviceEngine 不作类型引用（仅定义文件可）', () {
    final offenders = <String>[];
    for (final f in Directory('lib/llm')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final normalized = f.path.replaceAll('\\', '/');
      if (normalized == 'lib/llm/on_device_engine_aidl.dart') continue;
      for (var i = 0; i < f.readAsLinesSync().length; i++) {
        final line = f.readAsLinesSync()[i];
        final code = line.trim();
        if (code.startsWith('//') || code.startsWith('///')) continue;
        // 类型引用形状：字段声明 / 构造参数 / 泛型 / is / as。
        final isTypeRef = RegExp(r'\bAidlOnDeviceEngine\b').hasMatch(code);
        if (isTypeRef) offenders.add('${f.path}:${i + 1}: ${code.trim()}');
      }
    }
    expect(offenders, isEmpty,
        reason: '端侧消费件禁持具体实现类，一律持 OnDeviceEngine / '
            'OnDeviceSupplyFace 接口：$offenders');
  });
}
