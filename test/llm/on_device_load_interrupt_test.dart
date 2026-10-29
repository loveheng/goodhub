import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';
import 'package:goodhub/llm/on_device_engine_binding.dart';

/// 装载链路错误分类口径（lesson gdw-load-notbound 回归钉）。
///
/// 真机实证：`:engine` 在 Genie/QNN 装载中被系统静默 SIGKILL 后，主进程
/// 通道调用撞 `DeadObjectException` → 桥面回 `engine_binder_error`（或
/// 未绑定回 `not_bound`）。二者语义 = **进程中断（可自愈重试）**，严禁
/// 折算 `unsupportedDevice`（语义 = 硬件/驱动不支持），否则真机报
/// 「模型装载失败（unsupportedDevice）」误导排查方向。
///
/// 经 Mock MethodChannel 注入错误码，钉住三口径：中断码可重试 / 未知码
/// 为终态且如实带码 / 序数 5 仍是真「设备不支持」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 各用例改写的通道行为：错误码（非空即抛 PlatformException）。
  String? errorCode;
  int? statusOrdinal;

  setUp(() {
    errorCode = null;
    statusOrdinal = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, (call) async {
      final code = errorCode;
      if (code != null) throw PlatformException(code: code);
      if (call.method == 'loadModel' || call.method == 'checkStatus') {
        return statusOrdinal;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OnDeviceEngineBinding.channel, null);
  });

  test('engine_binder_error（binder 尸体）= 进程中断，禁折算 unsupportedDevice',
      () async {
    errorCode = 'engine_binder_error';
    final engine = AidlOnDeviceEngine();
    await expectLater(
      engine.loadModel('/models/x'),
      throwsA(
        isA<OnDeviceLoadException>()
            .having((e) => e.reason, 'reason', contains('进程中断'))
            .having((e) => e.reason, 'reason', isNot(contains('unsupported')))
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('not_bound（未绑定）= 进程中断同口径（既有语义回归钉）', () async {
    errorCode = 'not_bound';
    final engine = AidlOnDeviceEngine();
    await expectLater(
      engine.loadModel('/models/x'),
      throwsA(
        isA<OnDeviceLoadException>()
            .having((e) => e.reason, 'reason', contains('进程中断'))
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('未知错误码 = 终态失败，如实带码上抛（不伪装 unsupportedDevice）', () async {
    errorCode = 'engine_load_rejected';
    final engine = AidlOnDeviceEngine();
    await expectLater(
      engine.loadModel('/models/x'),
      throwsA(
        isA<OnDeviceLoadException>()
            .having((e) => e.reason, 'reason', contains('engine_load_rejected'))
            .having((e) => e.retryable, 'retryable', isFalse),
      ),
    );
  });

  test('真 unsupportedDevice 序数（5）= 设备不支持终态，DEGRADE 口径不变', () async {
    statusOrdinal = EngineStatus.unsupportedDevice.index; // AIDL 序数
    final engine = AidlOnDeviceEngine();
    expect(await engine.loadModel('/models/x'), EngineStatus.unsupportedDevice);
  });

  test('中断码白名单与桥面错误码同步（not_bound + engine_binder_error）', () {
    expect(kEngineInterruptCodes, contains('not_bound'));
    expect(kEngineInterruptCodes, contains('engine_binder_error'));
  });
}
