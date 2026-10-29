import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';
import 'package:goodhub/llm/on_device_thermal_gate.dart';

/// 热切云闸门单测（on-device S3-1，NPU 稿 §5.2/§5.3）。
///
/// 覆盖面 = 闸门布尔沿状态机 + AidlOnDeviceEngine generate 接线（热闸置于
/// bind 之前，纯 Dart 环境可测；:engine 侧 EngineThermal 状态机单测在
/// Kotlin 侧承载档位映射/迟滞，本闸门只持切云沿，不重复判档）。
void main() {
  group('EngineThermalGate', () {
    test('初始态：未切云（端侧默认可用）', () {
      final gate = EngineThermalGate();
      expect(gate.cutoffActive, isFalse);
    });

    test('setCutoff(true)：切云沿关闭闸门', () {
      final gate = EngineThermalGate();
      gate.setCutoff(active: true);
      expect(gate.cutoffActive, isTrue);
    });

    test('setCutoff(false)：热回落沿复开闸门（端侧自然恢复）', () {
      final gate = EngineThermalGate()
        ..setCutoff(active: true)
        ..setCutoff(active: false);
      expect(gate.cutoffActive, isFalse);
    });

    test('沿重入幂等：同沿重复上报不改变状态', () {
      final gate = EngineThermalGate();
      gate.setCutoff(active: true);
      gate.setCutoff(active: true);
      expect(gate.cutoffActive, isTrue);
      gate.setCutoff(active: false);
      gate.setCutoff(active: false);
      expect(gate.cutoffActive, isFalse);
    });
  });

  group('AidlOnDeviceEngine 热闸接线', () {
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      // Mock 通道桩：恢复沿用例的 generate 会走到 bind（热闸已放行）——
      // 无桩会 MissingPluginException 穿透 async 体外；桩返回 null 后按
      // 既有时序走 waitReady 3s 超时 → StateError 快速失败（非热闸路径）。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
        return null;
      });
    });

    test('切云期 generate 快速失败 EngineDiedException（bind 之前，禁 CPU 分流）',
        () async {
      final engine = AidlOnDeviceEngine();
      engine.thermalGate.setCutoff(active: true);
      await expectLater(
        engine.generate(requestId: 'r1', prompt: 'p').toList(),
        throwsA(isA<EngineDiedException>()),
      );
      // 恢复沿：闸门复开后不再快速失败（bind 阶段才报 not_bound，非热闸路径）。
      engine.thermalGate.setCutoff(active: false);
      await expectLater(
        engine.generate(requestId: 'r2', prompt: 'p').toList(),
        throwsA(isNot(isA<EngineDiedException>())),
      );
    });
  });
}
