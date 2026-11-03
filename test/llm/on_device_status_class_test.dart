import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_status_class.dart';

/// 端侧状态三分类单源验收钉（task-capability W1-S01）。
///
/// 背景：`on_device_load_poll.dart` 与 `on_device_engine_aidl.dart` 曾对
/// 同一状态持相反语义（前者把 reloading 归轮询终态出口、后者判可重试中断）。
/// 本钉锁死唯一分类：reloading=可重试、assetMissing=终态；新增 EngineStatus
/// 枚举值未登记分类即红（穷举映射 + 逐值断言）。
void main() {
  group('三分类映射（W1-S01 验收钉）', () {
    test('reloading 判可重试（非终态——空闲回收后重载此前被误判死）', () {
      expect(onDeviceStatusClass(EngineStatus.reloading),
          OnDeviceStatusClass.retryable);
    });

    test('assetMissing 判终态（真·未导入，如实上抛）', () {
      expect(onDeviceStatusClass(EngineStatus.assetMissing),
          OnDeviceStatusClass.terminal);
    });

    test('过程态：loading / unknownNeedReconcile（I2 未知≠终态）', () {
      expect(onDeviceStatusClass(EngineStatus.loading),
          OnDeviceStatusClass.inProgress);
      expect(onDeviceStatusClass(EngineStatus.unknownNeedReconcile),
          OnDeviceStatusClass.inProgress);
    });

    test('可重试中断：thermalCutoff（环境性可自愈）', () {
      expect(onDeviceStatusClass(EngineStatus.thermalCutoff),
          OnDeviceStatusClass.retryable);
    });

    test('终态：insufficientMemory / circuitBroken / unsupportedDevice', () {
      expect(onDeviceStatusClass(EngineStatus.insufficientMemory),
          OnDeviceStatusClass.terminal);
      expect(onDeviceStatusClass(EngineStatus.circuitBroken),
          OnDeviceStatusClass.terminal);
      expect(onDeviceStatusClass(EngineStatus.unsupportedDevice),
          OnDeviceStatusClass.terminal);
    });

    test('就绪出口：ready / busy 单列 success，不误归终态', () {
      expect(onDeviceStatusClass(EngineStatus.ready),
          OnDeviceStatusClass.success);
      expect(onDeviceStatusClass(EngineStatus.busy),
          OnDeviceStatusClass.success);
    });

    test('穷举：EngineStatus 每个值都映射到合法分类（switch 非穷举即编译红，此钉防回退到 if 收容）', () {
      final classes = EngineStatus.values.map(onDeviceStatusClass).toSet();
      expect(classes.every((c) => OnDeviceStatusClass.values.contains(c)), isTrue);
    });
  });
}
