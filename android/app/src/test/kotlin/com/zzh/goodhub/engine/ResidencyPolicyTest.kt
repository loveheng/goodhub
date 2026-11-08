package com.zzh.goodhub.engine

import com.zzh.goodhub.engine.ResidencyPolicy.CallerClass
import com.zzh.goodhub.engine.ResidencyPolicy.EnvSnapshot
import com.zzh.goodhub.engine.ResidencyPolicy.Strategy
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 驻留策略三档单测（residency-strategy-ui，on-device-residency P1 用户面）：
 * 档位=矩阵模式参数——smart 原样（缺省零变化钉子）/ extended 保底充电档 /
 * frugal 上限灭屏档；低电·省电·压力归零安全阀全档保留（R8）；
 * external 搭便车档不被 extended 放大（R7 拍板：外部请求无法钉死模型）。
 */
class ResidencyPolicyTest {

    private val envOn = EnvSnapshot(80, false, false, true)
    private val envOff = EnvSnapshot(80, false, false, false)
    private val envCharging = EnvSnapshot(80, true, false, true)
    private val envLow = EnvSnapshot(15, false, false, true)
    private val envPowerSave = EnvSnapshot(80, false, true, true)

    @Test
    fun `smart 档矩阵原样（缺省零变化钉子）`() {
        assertEquals(
            ResidencyPolicy.DEFAULT_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.hostForeground, envOn, false),
        )
        assertEquals(
            ResidencyPolicy.SCREEN_OFF_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.hostForeground, envOff, false),
        )
        assertEquals(
            ResidencyPolicy.CHARGING_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.hostForeground, envCharging, false),
        )
        assertEquals(
            ResidencyPolicy.EXTERNAL_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.external, envOn, false),
        )
    }

    @Test
    fun `extended 档宿主主体保底充电档（含灭屏抬升）`() {
        assertEquals(
            "前台 5min → 保底 30min",
            ResidencyPolicy.CHARGING_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.hostForeground, envOn, false, Strategy.extended),
        )
        assertEquals(
            "灭屏 1min → 保底 30min（驻留更久的产品语义）",
            ResidencyPolicy.CHARGING_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.hostForeground, envOff, false, Strategy.extended),
        )
        assertEquals(
            ResidencyPolicy.CHARGING_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.hostBackground, envCharging, false, Strategy.extended),
        )
    }

    @Test
    fun `extended 档不放大 external 搭便车（R7 拍板钉子）`() {
        assertEquals(
            "外部请求无法把模型钉死在内存",
            ResidencyPolicy.EXTERNAL_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.external, envOn, false, Strategy.extended),
        )
    }

    @Test
    fun `frugal 档上限灭屏档（充电与前台一并压缩）`() {
        assertEquals(
            ResidencyPolicy.SCREEN_OFF_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.hostForeground, envOn, false, Strategy.frugal),
        )
        assertEquals(
            "充电 30min → 上限 1min",
            ResidencyPolicy.SCREEN_OFF_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.hostForeground, envCharging, false, Strategy.frugal),
        )
        assertEquals(
            ResidencyPolicy.SCREEN_OFF_TTL_MS,
            ResidencyPolicy.ttlMs(CallerClass.external, envOn, false, Strategy.frugal),
        )
    }

    @Test
    fun `低电省电压力归零全档保留（R8 安全阀不被档位旁路）`() {
        for (strategy in Strategy.entries) {
            assertEquals(
                "低电（≤20%）归零 @ $strategy",
                0L,
                ResidencyPolicy.ttlMs(CallerClass.hostForeground, envLow, false, strategy),
            )
            assertEquals(
                "省电模式归零 @ $strategy",
                0L,
                ResidencyPolicy.ttlMs(CallerClass.hostForeground, envPowerSave, false, strategy),
            )
            assertEquals(
                "TRIM 压力让位归零 @ $strategy",
                0L,
                ResidencyPolicy.ttlMs(CallerClass.hostForeground, envOn, true, strategy),
            )
        }
    }

    @Test
    fun `Bundle 线格式解析（缺失与非法 = smart）`() {
        assertEquals(Strategy.smart, ResidencyPolicy.strategyFrom(null))
        assertEquals(Strategy.smart, ResidencyPolicy.strategyFrom("bogus"))
        assertEquals(Strategy.extended, ResidencyPolicy.strategyFrom("extended"))
        assertEquals(Strategy.frugal, ResidencyPolicy.strategyFrom("frugal"))
        assertEquals(Strategy.smart, ResidencyPolicy.strategyFrom("smart"))
    }
}
