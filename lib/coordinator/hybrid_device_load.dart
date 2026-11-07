/// 混合引擎冷装载协调（extensibility-hardening S3 自 hybrid_cloud_engine 拆出）：
/// 场景 A/B/C 切云语义拆分（2026-10-30 用户裁决）的装载状态机——
///  A 已加载但运行期夭折 → EngineDiedException 静默无缝切云（DeviceLeg 承接，
///    本件不涉及）；
///  B 未加载冷启动 + **后台**触发 → **不切云、不报错**，打 PendingForegroundLoad
///    标记（TTL 30min）暂存退出，等下次前台；
///  C 未加载冷启动 + **前台**用户发起 → 加载态 + 90s 超时保护（装载等待自身
///    退避面）→ 终态失败显式报错；可自愈类（进程被杀/热降级）按需降级云端。
library;

import 'package:flutter/foundation.dart';

import '../core/errors/inference_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/on_device_engine.dart';
import '../llm/on_device_pending_load.dart';

/// 冷装载协调出口（send 编排按此分派：继续端侧 / 本轮显式收口 / 降级云端）。
sealed class DeviceLoadResult {
  const DeviceLoadResult();
}

/// 装载就绪（或本就 ready）→ 继续端侧发送。
class DeviceLoadReady extends DeviceLoadResult {
  const DeviceLoadReady();
}

/// 本轮以 [exception] 显式收口（场景 B 暂存通告 / q-1 终态装载失败——两者
/// 语义同形：抛 InferenceException、不切云）。
class DeviceLoadDeferred extends DeviceLoadResult {
  const DeviceLoadDeferred(this.exception);

  final InferenceException exception;
}

/// 场景 C 可自愈类（`retryable` = 进程/通道中断、热降级 `degraded`）→ 本轮
/// 降级云端完成（产出优先 + §5.2 Thermal→Cloud）。
class DeviceLoadCloudFallback extends DeviceLoadResult {
  const DeviceLoadCloudFallback();
}

/// 协调冷装载（懒加载兜底：首次命中端侧路径才显式加载——bind→就绪→资产→
/// loadModel→数据面 worker，加载过程对用户可见 loadState=loading）。
///
/// [cap] 为 null = 端侧引擎无显式装载能力 → 直接视为就绪（旧引擎形态兼容）。
/// [cloudForbidden] = 排除位守卫读数（S14e）；[hasCloud] = 云端兜底位。
Future<DeviceLoadResult> coordinateDeviceLoad({
  required OnDeviceEnableCapable? cap,
  required bool foreground,
  required CloudChatRequest request,
  required bool cloudForbidden,
  required bool hasCloud,
}) async {
  if (cap == null || cap.loadState.value == OnDeviceLoadState.ready) {
    return const DeviceLoadReady();
  }
  // 场景 B：后台冷装载 → 不切云，打 PendingForegroundLoad 标记暂存等前台。
  if (!foreground) {
    await OnDevicePendingLoad.mark();
    debugPrint('[HybridEngine] 场景B：后台冷装载 → 暂存等前台（不切云）');
    return DeviceLoadDeferred(
        const InferenceException('端侧模型将在你回到前台时自动加载（后台加载已暂存）'));
  }
  try {
    // D3 残余取消语义（S14b 钉死，裁决 = memory D3）：调用方在装载
    // 等待期取消本轮 = **放弃本轮等待**，绝不中止装载——单进程单装载
    // 纪律下中止装载即进程自杀重启。机制依据：enable() 的 Future 不
    // 随流退订取消（async* 生成器 await 检查点语义），且无任何取消
    // 路径调 disable()——装载在后台继续完成，下一轮命中即秒级复用；
    // 本轮在 await 返回前已死（无产出投递）= 等待已放弃。已知边界：
    // 放弃的即时性受 Dart await 检查点限制（不能中断 enable 本身，
    // 禁中止装载优先于即时退出），退订信号先于装载完成到达时本轮在
    // 装载完成后立即静默退出。理由码落痕 = [ROUTE] 行（send 编排段）。
    await cap.enable();
  } on OnDeviceLoadException catch (e) {
    // 终态失败（资产缺失 / 设备不支持 / 内存不足）→ q-1 显式报错**不**
    // 切云；可自愈类（`retryable` = 进程/通道中断、热降级 `degraded`）
    // → 切云完成本轮（产出优先 + §5.2 Thermal→Cloud）。
    //
    // 中断类也切云的依据（真机实证 2026-10-30）：`:engine` 被 LMK 连杀
    // 时，等待端侧自愈 = 用户干等 2 分钟以上（退避 3.5/8/12/30/60s 累计），
    // 本轮必须由云端兜底，否则「2 分钟没有首 token」。
    final recoverable = e.degraded || e.retryable;
    if (!recoverable) {
      return DeviceLoadDeferred(InferenceException('端侧加载失败：${e.reason}'));
    }
    // 排除位守卫（S14e）：可自愈类原语义 = 切云完成本轮（产出优先）；
    // 本步声明禁止云端 → 显式失败不切云（数据不出境）。
    if (cloudForbidden) {
      return DeviceLoadDeferred(InferenceException(
          '端侧加载失败：${e.reason}（本步声明禁止云端，不切云）'));
    }
    if (!hasCloud) {
      return DeviceLoadDeferred(
          InferenceException('端侧加载失败：${e.reason}（可稍后重试）'));
    }
    debugPrint('[HybridEngine] 场景C：端侧暂不可用（${e.reason}）→ 降级云端完成本轮');
    return const DeviceLoadCloudFallback();
  }
  return const DeviceLoadReady();
}
