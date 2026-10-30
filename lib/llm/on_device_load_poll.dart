import 'on_device_engine.dart';

/// 端侧模型装载「受理态 → 就绪」轮询状态机（on-device S3-1 修订）。
///
/// 背景（AIDL 契约）：`loadModel` **受理即返回** `assetMissing`（`:engine` 后台
/// 线程建 Genie 会话，秒级~分钟级暖机），真实就绪须轮询 `checkStatus`。
///
/// 本件是**纯逻辑件**（状态探针 / 时钟 / 节拍全注入），便于单测覆盖非就绪
/// 中间态——尤其热降级（[EngineStatus.thermalCutoff]）：
///
/// - **热降级不是装载失败**：`:engine` 侧装载线程不因热切云中断（热切云只拦
///   生成受理 + 改 `checkStatus` 回报），温度回落后装载自然就绪。故容忍窗内
///   **继续轮询**、绝不判死——真机曾报「模型装载失败（circuitBroken）」：把环境
///   降级误报成引擎故障并终止装载（热降级与熔断曾复用同一序数）。
/// - 容忍窗超限仍不恢复 → 抛 [OnDeviceLoadException]（`retryable` + `degraded`）：
///   环境性可自愈，由上层按 §5.2 Thermal→Cloud **切云**完成本轮（既非终态
///   失败，也非熔断）。
/// - 其余非就绪终态（`insufficientMemory` / `circuitBroken` /
///   `unsupportedDevice`）如实上抛，由上层判生。
Future<EngineStatus> pollLoadReady({
  required Future<EngineStatus> Function() probe,
  Duration budget = const Duration(seconds: 60),
  Duration thermalTolerance = const Duration(seconds: 90),
  Duration tick = const Duration(milliseconds: 300),
  Future<void> Function(Duration)? sleep,
  DateTime Function()? clock,
}) async {
  final DateTime Function() now = clock ?? DateTime.now;
  final Future<void> Function(Duration) rest =
      sleep ?? ((d) => Future<void>.delayed(d));
  final deadline = now().add(budget);
  final thermalDeadline = now().add(thermalTolerance);
  var thermalActive = false;
  var status = EngineStatus.assetMissing;
  while (now().isBefore(deadline)) {
    await rest(tick);
    status = await probe();
    if (status == EngineStatus.ready || status == EngineStatus.busy) {
      return status;
    }
    if (status == EngineStatus.thermalCutoff) {
      // 热降级（设备过热）：环境性可自愈，装载仍在后台进行——继续等热回落。
      thermalActive = true;
      if (!now().isBefore(thermalDeadline)) {
        throw const OnDeviceLoadException(
          '设备过热，端侧已暂停（温度回落后可重试）',
          retryable: true,
          degraded: true,
        );
      }
      continue;
    }
    thermalActive = false;
    if (status != EngineStatus.assetMissing) break;
  }
  if (thermalActive) {
    throw const OnDeviceLoadException(
      '设备过热，端侧已暂停（温度回落后可重试）',
      retryable: true,
      degraded: true,
    );
  }
  return status;
}
