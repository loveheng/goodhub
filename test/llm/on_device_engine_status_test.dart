import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';

/// EngineStatus 序数锚定 + reloading 语义钉（Fix1 恢复语义去歧义）。
///
/// 序数 = AIDL int 传输契约（禁调序，仅允许末尾追加）——Kotlin 侧
/// `EngineStatusOrdinalTest` 同轮锚定 reloading == 8，任一侧漂移即测试红。
///
/// 事故背景（2026-10-31 用户报告「端侧过段时间就不可用且 App 无感知」）：
/// 空闲驱逐后重载撞 `loadedOnce` 单进程单装载纪律，`:engine` 返回值复用
/// assetMissing 终态序数 → Dart 侧当「模型未导入」误导重下、且不再重试
/// → 端侧静默永久失效、后续请求静默切云。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int? statusOrdinal;
  setUp(() {
    statusOrdinal = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
      if (call.method == 'loadModel') return statusOrdinal;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, null);
  });

  group('EngineStatus 序数锚定（AIDL int 契约，双端同轮钉死）', () {
    test('reloading 固定末尾 ordinal=8（Kotlin 侧同轮锚定）', () {
      expect(EngineStatus.reloading.index, 8);
    });

    test('loading 保持 ordinal=7（M4 追加位不动，禁调序）', () {
      expect(EngineStatus.loading.index, 7);
    });

    test('序数 8 还原 reloading；序数 9 还原 unknownNeedReconcile（F2 追加）', () {
      expect(engineStatusFromOrdinal(8), EngineStatus.reloading);
      expect(engineStatusFromOrdinal(9), EngineStatus.unknownNeedReconcile);
    });

    test('越界序数收容 unknownNeedReconcile（I2 未知≠终态，禁再投毒 unsupportedDevice）', () {
      expect(engineStatusFromOrdinal(999), EngineStatus.unknownNeedReconcile);
      expect(engineStatusFromOrdinal(-1), EngineStatus.unknownNeedReconcile);
    });

    test('unknownNeedReconcile 固定末尾 ordinal=9（Kotlin 侧同轮锚定）', () {
      expect(EngineStatus.unknownNeedReconcile.index, 9);
    });
  });

  group('reloading 语义（Fix1：拒绝同进程重载 = 可重试中断，非终态）', () {
    test('loadModel 序数 8 → reloading（不再伪 assetMissing）', () async {
      statusOrdinal = EngineStatus.reloading.index;
      final engine = AidlOnDeviceEngine();
      expect(await engine.loadModel('/models/x'), EngineStatus.reloading);
    });

    test('用户文案区别于 assetMissing（禁再引导「重新导入模型」）', () {
      final r = engineStatusFailureReason(EngineStatus.reloading);
      expect(r, contains('重启装载'));
      expect(r, isNot(contains('导入')));
    });

    test('assetMissing 文案仍是终态「未导入」口径（真·缺失语义保留）', () {
      expect(engineStatusFailureReason(EngineStatus.assetMissing),
          contains('未导入'));
    });

    test('expectRestart 默认 false（既有中断语义不变），显式置位可传播', () {
      const e = OnDeviceLoadException('x', retryable: true);
      expect(e.expectRestart, isFalse);
      const r =
          OnDeviceLoadException('y', retryable: true, expectRestart: true);
      expect(r.expectRestart, isTrue);
      expect(r.retryable, isTrue);
    });
  });
}
