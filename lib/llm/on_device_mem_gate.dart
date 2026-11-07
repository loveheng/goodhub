/// 端侧装载「起跑闸」（MemGate）水位常量与判定（on-device 2026-10-30 步 0 +
/// 场景 C 裁决）。
///
/// **配对阈值集（P1-c 水位对账）**：本文件三值（1.2/1.6/0.9GB，Dart 装载闸·
/// 真机校准）与 `:engine` `MemoryGuardEvaluator`（6GB/1GB，运行期护栏）为
/// **不同层、不同语义的配对阈值**——装载前预检 ↔ 运行期护栏。重校准须两侧
/// 同步（观测对账行 [RESIDENCY] mem-gate 提供对账数据）；跨进程强统一单源
/// 经评估否决（语义不同层，强统一 = cargo-cult，见 epic devlog）。
///
/// **为什么重定水位（真机实测推翻旧认知）**：旧值起跑 4.5GB / 棘轮 5GB 的依据
/// 是「4B 装载瞬态 ~6GB ION dmabuf 会击穿整机 min watermark」——官方 demo
/// 同机同 4B 实测推翻该认知：装载瞬态 PSS 仅 **2.09GB**，且在整机
/// MemAvailable **956MB** 时即装载成功。旧水位在 12GB 机型上**永不可能
/// 满足** → 等待循环永久静默轮询（60s/次、零日志）→ **端侧从未真正起跑**
/// （「2 分钟没有首 token」的第一直接原因，早于 LMK 击杀）。
///
/// **安全线口径**：用整机 `MemAvailable`（Linux 口径，含可回收页缓存），
/// **不用**进程 PSS 峰值——峰值里大部分是可回收页缓存 + DSP 侧，用它定线会
/// 把闸门设得过高（这正是旧水位失义的根源）。
library;

/// 起跑水位（常规）：低于此值不发起装载，等系统自然回升（后台继续装载）。
const int kLoadMinAvailRamBytes = 1200 << 20; // 1.17GB ≈ 1.2GB

/// 快死棘轮水位：连续快死（受理后 30s 内中断）≥2 次后抬到此处，等系统真实
/// 恢复（用户清后台 / 大应用退出）才再发起——停止连累整机 LMK 杀其他应用。
const int kRetryHighWaterBytes = 1600 << 20; // 1.56GB ≈ 1.6GB

/// 硬失败线（场景 C 降级线，用户裁决 0.9GB）：低于此值再等也不会满足起跑
/// 线，等待只会让用户干等 → 立即终态失败（显式报错，提示清理后台应用）。
const int kLoadHardFailAvailRamBytes = 900 << 20; // 0.9GB

/// 起跑闸判定结果。
enum MemGateDecision {
  /// 可起跑（余量达标，或探针不可用 → 放行，沿既有「未知 = 放行」口径）。
  go,

  /// 余量不足但仍高于硬失败线 → 等待（退避重试）。
  wait,

  /// 跌破硬失败线 → 放弃本轮装载（终态失败）。
  hardFail,
}

/// 起跑闸判定（纯函数，便于单测覆盖三档）。
///
/// [availRamBytes] = 整机 `MemAvailable`（字节）；null = 探针不可用 → 放行
/// （沿既有探针口径：未知 ≠ 已知有害）。
MemGateDecision decideMemGate({
  required int? availRamBytes,
  required int threshold,
}) {
  if (availRamBytes == null) return MemGateDecision.go;
  if (availRamBytes >= threshold) return MemGateDecision.go;
  if (availRamBytes < kLoadHardFailAvailRamBytes) {
    return MemGateDecision.hardFail;
  }
  return MemGateDecision.wait;
}

/// 装载失败文案（硬失败线专用）——面向用户，白话 + 可行动。
String memGateHardFailReason(int? availRamBytes) {
  final availMb = availRamBytes == null ? 0 : availRamBytes >> 20;
  return '可用内存不足（当前 ${availMb}MB，'
      '需 ≥${kLoadHardFailAvailRamBytes >> 20}MB），请清理后台应用后重试';
}
