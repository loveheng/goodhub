import 'dart:async';

import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_engine_aidl.dart';

/// 全测试进程装配引导（Dart test 约定文件名，每个测试文件 isolate 各跑一次）。
///
/// S2 端侧引擎单例注册制（extensibility-hardening）后，装配面测试流经
/// `assembleDefaultHybridEngine` 需要已注册实例——此处注册等价于 S2 前的
/// 「eager 具体类单例」测试语义（进程一份、全程共享）。需要新实例的测试
/// 自行 `resetSharedOnDeviceEngineForTest()` 后重注册（见
/// on_device_shared_engine_registry_test）。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  registerSharedOnDeviceEngine(AidlOnDeviceEngine());
  await testMain();
}
