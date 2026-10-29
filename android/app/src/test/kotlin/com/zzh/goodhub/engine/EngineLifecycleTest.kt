package com.zzh.goodhub.engine

import android.content.ComponentCallbacks2
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 三态生命周期状态机单测（on-device S2-4，NPU 稿 §4.1）：
 * ACTIVE / WARM-STANDBY / COLD-EVICTED 转换、TTL 代次作废、trim 驱动、
 * 内存预算护栏。
 */
class EngineLifecycleTest {
    private val evictions = mutableListOf<String>()

    private fun lifecycle() = EngineLifecycle(onEvict = { evictions.add(it) })

    @Test
    fun `初始态 COLD_EVICTED，warmup 转 WARM_STANDBY 并返回代次`() {
        val lc = lifecycle()
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)
        val gen = lc.onWarmup()
        assertEquals(EngineLifecycle.State.WARM_STANDBY, lc.state)
        assertTrue(gen > 0)
        assertTrue(evictions.isEmpty())
    }

    @Test
    fun `生成往返 ACTIVE 与 WARM_STANDBY`() {
        val lc = lifecycle()
        lc.onWarmup()
        lc.onGenerateStart()
        assertEquals(EngineLifecycle.State.ACTIVE, lc.state)
        val gen = lc.onGenerateFinished()
        assertEquals(EngineLifecycle.State.WARM_STANDBY, lc.state)
        assertTrue(gen > 0)
    }

    @Test
    fun `TTL 超时驱逐至 COLD_EVICTED 且触发析构回调`() {
        val lc = lifecycle()
        val gen = lc.onWarmup()
        assertTrue(lc.onTtlElapsed(gen))
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)
        assertEquals(1, evictions.size)
        assertTrue(evictions[0].contains("ttl-elapsed"))
    }

    @Test
    fun `代次失配的过期定时器作废（旧计时器不杀新会话）`() {
        val lc = lifecycle()
        val oldGen = lc.onWarmup()
        lc.onTtlElapsed(oldGen) // 驱逐，代次 +1
        lc.onWarmup() // 新会话，代次再 +1
        assertFalse(lc.onTtlElapsed(oldGen)) // 旧代次定时器到点 → 作废
        assertEquals(EngineLifecycle.State.WARM_STANDBY, lc.state)
    }

    @Test
    fun `ACTIVE 期间 TTL 到点不驱逐（生成中不受 TTL 驱逐）`() {
        val lc = lifecycle()
        val gen = lc.onWarmup()
        lc.onGenerateStart()
        assertFalse(lc.onTtlElapsed(gen))
        assertEquals(EngineLifecycle.State.ACTIVE, lc.state)
        assertTrue(evictions.isEmpty())
    }

    @Test
    fun `trim 驱动：BACKGROUND 与 RUNNING_CRITICAL 驱逐，低等级不动作`() {
        val lc = lifecycle()
        lc.onWarmup()
        assertFalse(lc.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE))
        assertEquals(EngineLifecycle.State.WARM_STANDBY, lc.state)
        assertTrue(lc.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL))
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)

        val lc2 = lifecycle()
        lc2.onWarmup()
        assertTrue(lc2.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_BACKGROUND))
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc2.state)
    }

    @Test
    fun `内存预算护栏：RSS 越线即使 TTL 内也提前驱逐，未越线不动作`() {
        val lc = lifecycle()
        lc.onWarmup()
        assertFalse(lc.onMemoryPressure(rssBytes = 2_000L * 1024 * 1024, guardBytes = 2_560L * 1024 * 1024))
        assertEquals(EngineLifecycle.State.WARM_STANDBY, lc.state)
        assertTrue(lc.onMemoryPressure(rssBytes = 2_700L * 1024 * 1024, guardBytes = 2_560L * 1024 * 1024))
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)
    }

    @Test
    fun `COLD_EVICTED 下一切触发静默（无重复驱逐回调）`() {
        val lc = lifecycle()
        lc.onWarmup()
        lc.onTtlElapsed(lc.onGenerateFinished()) // 驱逐一次
        val count = evictions.size
        assertFalse(lc.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_BACKGROUND))
        assertFalse(lc.onMemoryPressure(9_999L * 1024 * 1024, 1L))
        assertFalse(lc.onGenerateStart().let { false }) // 无动作（不崩不回调）
        assertEquals(count, evictions.size)
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)
    }

    @Test
    fun `驱逐后 warmup 重入：代次递增，旧定时器全数作废`() {
        val lc = lifecycle()
        val g1 = lc.onWarmup()
        lc.onTtlElapsed(g1)
        val g2 = lc.onWarmup()
        assertTrue(g2 > g1)
        assertFalse(lc.onTtlElapsed(g1))
        assertTrue(lc.onTtlElapsed(g2))
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)
    }

    @Test
    fun `主动 release：WARM 态释放至 COLD_EVICTED 并触发析构回调`() {
        val lc = lifecycle()
        lc.onWarmup()
        assertTrue(lc.onRelease())
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)
        assertEquals(1, evictions.size)
        assertTrue(evictions[0].contains("release"))
    }

    @Test
    fun `主动 release：ACTIVE 中途释放同样生效（在途生成中止后析构）`() {
        val lc = lifecycle()
        lc.onWarmup()
        lc.onGenerateStart()
        assertEquals(EngineLifecycle.State.ACTIVE, lc.state)
        assertTrue(lc.onRelease())
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)
    }

    @Test
    fun `主动 release 幂等：COLD 态重复释放不重复回调，且旧定时器代次作废`() {
        val lc = lifecycle()
        val g = lc.onWarmup()
        assertTrue(lc.onRelease())
        assertFalse(lc.onRelease()) // 幂等：不重复回调
        assertEquals(1, evictions.size)
        assertFalse(lc.onTtlElapsed(g)) // 释放后代次递增，旧 TTL 定时器作废
        assertEquals(EngineLifecycle.State.COLD_EVICTED, lc.state)
    }
}
