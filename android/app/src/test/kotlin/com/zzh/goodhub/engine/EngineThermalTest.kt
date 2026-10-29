package com.zzh.goodhub.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 热调度状态机单测（on-device S3-1，NPU 稿 §5.2/§5.3）：
 * 热档位 → 四模式映射、SEVERE 全切云进出沿迟滞、回调仅翻转沿触发。
 */
class EngineThermalTest {
    private val events = mutableListOf<Pair<Boolean, Int>>()

    private fun thermal() = EngineThermal { active, status -> events.add(active to status) }

    @Test
    fun `初始态 BALANCED 且未切云`() {
        val t = thermal()
        assertEquals(EngineThermal.Mode.BALANCED, t.mode)
        assertFalse(t.cutoffActive)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `NONE 与 LIGHT 为 BALANCED 默认档`() {
        val t = thermal()
        t.onThermalStatus(EngineThermal.STATUS_NONE)
        assertEquals(EngineThermal.Mode.BALANCED, t.mode)
        t.onThermalStatus(EngineThermal.STATUS_LIGHT)
        assertEquals(EngineThermal.Mode.BALANCED, t.mode)
        assertFalse(t.cutoffActive)
    }

    @Test
    fun `MODERATE 为 POWERSAVE 降档（预留钩子，继续端侧）`() {
        val t = thermal()
        t.onThermalStatus(EngineThermal.STATUS_MODERATE)
        assertEquals(EngineThermal.Mode.POWERSAVE, t.mode)
        // MODERATE 带 = 端侧继续，不触发切云回调
        assertFalse(t.cutoffActive)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `SEVERE 及以上进入 THERMAL_CUTOFF 全切云（禁 CPU 分流）`() {
        for (status in intArrayOf(
            EngineThermal.STATUS_SEVERE,
            EngineThermal.STATUS_CRITICAL,
            EngineThermal.STATUS_EMERGENCY,
            EngineThermal.STATUS_SHUTDOWN,
        )) {
            events.clear()
            val t = thermal()
            t.onThermalStatus(status)
            assertEquals(EngineThermal.Mode.THERMAL_CUTOFF, t.mode)
            assertTrue(t.cutoffActive)
            assertEquals(listOf(true to status), events)
        }
    }

    @Test
    fun `进出沿迟滞：SEVERE 进入 MODERATE 退出，LIGHT 复位 BALANCED`() {
        val t = thermal()
        t.onThermalStatus(EngineThermal.STATUS_LIGHT)
        assertTrue(t.onThermalStatus(EngineThermal.STATUS_SEVERE)) // 进入沿
        assertTrue(t.cutoffActive)
        // CRITICAL 内再升档：仍切云，无翻转（无重复回调）
        assertFalse(t.onThermalStatus(EngineThermal.STATUS_CRITICAL))
        assertEquals(1, events.size)
        // 回落 MODERATE：退出切云（滞回带下沿），转 POWERSAVE 继续端侧
        assertTrue(t.onThermalStatus(EngineThermal.STATUS_MODERATE))
        assertFalse(t.cutoffActive)
        assertEquals(EngineThermal.Mode.POWERSAVE, t.mode)
        // 复位 NONE：BALANCED，非翻转沿无回调
        assertFalse(t.onThermalStatus(EngineThermal.STATUS_NONE))
        assertEquals(EngineThermal.Mode.BALANCED, t.mode)
        assertEquals(
            listOf(
                true to EngineThermal.STATUS_SEVERE,
                false to EngineThermal.STATUS_MODERATE,
            ),
            events,
        )
    }

    @Test
    fun `同档重入幂等：回调只在翻转沿触发`() {
        val t = thermal()
        assertFalse(t.onThermalStatus(EngineThermal.STATUS_NONE))
        assertFalse(t.onThermalStatus(EngineThermal.STATUS_NONE))
        t.onThermalStatus(EngineThermal.STATUS_SEVERE)
        assertFalse(t.onThermalStatus(EngineThermal.STATUS_SEVERE))
        assertFalse(t.onThermalStatus(EngineThermal.STATUS_EMERGENCY)) // 切云带内升级非翻转
        assertTrue(t.onThermalStatus(EngineThermal.STATUS_LIGHT)) // LIGHT ≤ MODERATE → 退出沿翻转
        assertEquals(2, events.size)
        assertEquals(false to EngineThermal.STATUS_LIGHT, events[1])
    }

    @Test
    fun `lastStatus 记录最近上报值（观测面）`() {
        val t = thermal()
        t.onThermalStatus(EngineThermal.STATUS_LIGHT)
        assertEquals(EngineThermal.STATUS_LIGHT, t.lastStatus)
        t.onThermalStatus(EngineThermal.STATUS_CRITICAL)
        assertEquals(EngineThermal.STATUS_CRITICAL, t.lastStatus)
    }
}
