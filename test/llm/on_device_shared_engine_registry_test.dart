import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';

/// S2 注册语义钉（extensibility-hardening）：进程级端侧引擎单例注册制——
/// 幂等（同实例放行）/ 异实例断言拦截 / 未注册 fail-fast / 测试重置。
void main() {
  setUp(resetSharedOnDeviceEngineForTest);
  tearDown(resetSharedOnDeviceEngineForTest);

  test('未注册取用 → StateError（fail-fast，禁静默兜底）', () {
    expect(() => sharedOnDeviceEngine, throwsStateError);
  });

  test('注册后取用 → 同实例；同实例重复注册幂等放行', () {
    final engine = AidlOnDeviceEngine();
    registerSharedOnDeviceEngine(engine);
    expect(identical(sharedOnDeviceEngine, engine), isTrue);
    registerSharedOnDeviceEngine(engine);
    expect(identical(sharedOnDeviceEngine, engine), isTrue);
  });

  test('异实例重复注册 → AssertionError（MethodChannel 单槽纪律）', () {
    registerSharedOnDeviceEngine(AidlOnDeviceEngine());
    expect(
      () => registerSharedOnDeviceEngine(AidlOnDeviceEngine()),
      throwsA(isA<AssertionError>()),
    );
  });
}
