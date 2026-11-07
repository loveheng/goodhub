package com.zzh.goodhub.engine

import android.content.ComponentCallbacks2

/**
 * 驻留策略单源（on-device-residency P1-a）：TTL 矩阵 + TRIM 分档的唯一 owner
 * ——状态机零魔法数纪律对齐（EngineLifecycle / EngineService 只消费本对象的
 * 结论）。矩阵短路序（从高到低）：低电归零 → 灭屏加速 → 充电放宽 → external
 * 搭便车 → 缺省 5min。外部覆盖（P0 updateTtlMs 注入缝）优先级高于矩阵，由
 * 接线方（EngineService）裁决，本对象不感知。
 */
object ResidencyPolicy {
    /** 缺省 TTL（§4.1 拍板 5min——矩阵缺省项，消费方禁直读旧常量）。 */
    const val DEFAULT_TTL_MS = 5L * 60 * 1000

    /** 低电阈值（%）与各档 TTL（R7/R8 评审定案，本文件唯一出处）。 */
    const val LOW_BATTERY_PCT = 20
    const val SCREEN_OFF_TTL_MS = 60L * 1000
    const val CHARGING_TTL_MS = 30L * 60 * 1000
    const val EXTERNAL_TTL_MS = 60L * 1000
    const val PRESSURE_TTL_MS = 0L

    /** 连续 BACKGROUND 级 trim 让位次数上限（超限升级驱逐，防永久赖驻）。 */
    const val PRESSURE_STREAK_LIMIT = 3

    /** 调用方类别（R7 三值主体；external 随 W6 落地接入，现阶段不产出）。 */
    enum class CallerClass { hostForeground, hostBackground, external }

    /** 环境快照（P0 观测面同源字段：sticky 广播 + PowerManager 事件沿同步读）。 */
    data class EnvSnapshot(
        val batteryPct: Int,
        val charging: Boolean,
        val powerSave: Boolean,
        val interactive: Boolean,
    )

    /** TRIM 分档动作（P1-b）：Evict = 立即驱逐；Defer = 让位（记压力、短 TTL）。 */
    enum class TrimAction { Evict, Defer }

    /**
     * TTL 矩阵（短路序）：低电归零 → 压力让位 → 灭屏 1min → 充电 30min →
     * external 1min → 缺省 5min。[pressure] = 连续 BACKGROUND 级 trim 让位中
     * （接线方累计 streak，达 [PRESSURE_STREAK_LIMIT] 升级驱逐）。
     */
    fun ttlMs(caller: CallerClass, env: EnvSnapshot, pressure: Boolean): Long {
        if (env.powerSave || env.batteryPct in 0 until LOW_BATTERY_PCT) return 0L
        if (pressure) return PRESSURE_TTL_MS
        if (!env.interactive) return SCREEN_OFF_TTL_MS
        if (env.charging) return CHARGING_TTL_MS
        if (caller == CallerClass.external) return EXTERNAL_TTL_MS
        return DEFAULT_TTL_MS
    }

    /**
     * TRIM 分档（P1-b）：RUNNING_CRITICAL / COMPLETE → 立即驱逐；其余
     *（BACKGROUND 降档为让位——R4「一刀切干掉 6GB 瞬态代价模型」的非对称
     * 惩罚修正）→ Defer（接线方累计 streak，超限升级驱逐）。
     */
    fun trimAction(level: Int): TrimAction =
        if (level == ComponentCallbacks2.TRIM_MEMORY_COMPLETE ||
            level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL
        ) TrimAction.Evict
        else TrimAction.Defer
}
