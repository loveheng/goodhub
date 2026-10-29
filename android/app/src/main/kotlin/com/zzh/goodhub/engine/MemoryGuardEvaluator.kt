package com.zzh.goodhub.engine

/**
 * 内存预算护栏评估器（on-device S3 内存面，NPU 稿 §4.1「逼近 LMK 阈值即使
 * TTL 内也提前降级」）。
 *
 * S2-5 真机校准发现（8 Elite，2026-10-29）：GenieX 路线下权重/ctx-bin 常驻
 * ION/DSP 缓冲，不计入进程 PSS（暖机+生成全程 :engine PSS 稳定 ~103MB），
 * 「进程 RSS 易破 2.4GB」的推拍前提不成立——RSS 线实际不可达，已按 Uncertain
 * 销项流程换线本指标。
 *
 * 真指标（选型依据见 devlog 2026-10-29）：
 *  - **availMem 基线增量**：ION/DMA-BUF 分配由内核计入系统可用内存，故
 *    「暖机基线 availMem − 当前 availMem」≈ 引擎真实足迹（含 ION）；
 *  - **availMem 绝对地板**：系统级饥饿防护——不论增量多少，可用内存跌破
 *    地板即驱逐（整机其他 App 压力场景，TTL 内也降级）。
 *
 * 弃选：per-process dmabuf 精确记账（/proc/<pid>/fd 符号链接不携带尺寸，
 * debugfs bufinfo 需 root）——不可行，不做猜测性降级。
 *
 * 纯逻辑件（无 Android 依赖，JVM 单测覆盖）；availMem 采集由接线方承载
 * （ActivityManager.MemoryInfo），状态机与驱逐动作仍归 [EngineLifecycle]。
 */
object MemoryGuardEvaluator {

    /**
     * 增量预算：§4.1 LMK 防护栏原 2.5GB 线语义平移（引擎真实足迹上限）。
     */
    const val HELD_BUDGET_BYTES: Long = 2560L * 1024 * 1024

    /**
     * availMem 绝对地板：跌破即驱逐。取 1GB——低于此值系统已进入低内存
     * 杀截区间（LMK 对后台进程先动手），引擎必须让位，与足迹无关。
     */
    const val ABSOLUTE_FLOOR_BYTES: Long = 1024L * 1024 * 1024

    /**
     * 护栏判定。返回 null = 未触发；非 null = 驱逐理由（供日志与上报）。
     *
     * [baselineAvailMemBytes] = 暖机完成时采集的 availMem；
     * [currentAvailMemBytes] = 当前 availMem；
     * [heldBudgetBytes] / [floorBytes] 由接线方注入（默认取本对象常量），
     * 保持状态机/评估器无魔法数纪律。
     */
    fun evaluate(
        baselineAvailMemBytes: Long,
        currentAvailMemBytes: Long,
        heldBudgetBytes: Long = HELD_BUDGET_BYTES,
        floorBytes: Long = ABSOLUTE_FLOOR_BYTES,
    ): String? {
        if (currentAvailMemBytes <= 0 || baselineAvailMemBytes <= 0) return null
        // 采样噪声容忍：availMem 抖动（其他进程分配/回收）不应触发误杀，
        // 地板判定同样带 8MB 容差（一个采样周期的抖动量级）。
        val jitterTolerance = 8L * 1024 * 1024
        val held = baselineAvailMemBytes - currentAvailMemBytes
        if (held >= heldBudgetBytes) {
            return "memory-guard(availMem-delta=${held / 1048576}MB ≥ ${heldBudgetBytes / 1048576}MB)"
        }
        if (currentAvailMemBytes + jitterTolerance <= floorBytes) {
            return "memory-guard(availMem=${currentAvailMemBytes / 1048576}MB ≤ floor=${floorBytes / 1048576}MB)"
        }
        return null
    }
}
