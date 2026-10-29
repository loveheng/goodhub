package com.zzh.goodhub.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 单执行槽单测（on-device S3-3，NPU 稿 §6.6 / 总纲 §2 v2.6）：
 * 空闲授予、后台忙驳回、前台抢占让槽、抢占超时兜底、槽主释放语义。
 */
class EngineSlotTest {

    @Test
    fun `空闲授予并登记槽主`() {
        val slot = EngineSlot()
        assertEquals(EngineSlot.AcquireResult.GRANTED, slot.tryAcquire("r1", true) {})
        assertTrue(slot.isBusy)
        assertEquals("r1", slot.owner)
    }

    @Test
    fun `忙时后台请求立即驳回（策略 B，不触发抢占不排队）`() {
        val slot = EngineSlot()
        slot.tryAcquire("r1", true) {}
        var preempted = false
        val r = slot.tryAcquire("r2-summarizer", foreground = false) { preempted = true }
        assertEquals(EngineSlot.AcquireResult.DENIED_BUSY, r)
        assertFalse(preempted) // 后台驳回不中断在途请求
        assertEquals("r1", slot.owner) // 槽主不变
        assertTrue(slot.isBusy)
    }

    @Test
    fun `忙时前台请求抢占：preempt 触发，槽释放后授予新请求`() {
        val slot = EngineSlot(preemptWaitMs = 2000, pollMs = 1)
        slot.tryAcquire("r-old", true) {}
        val preempted = CountDownLatch(1)
        // 模拟在途请求收到 abort 后的快速收尾（另一线程 release）。
        Thread {
            preempted.await(1, TimeUnit.SECONDS)
            slot.release("r-old")
        }.start()
        val r = slot.tryAcquire("r-new", foreground = true) {
            preempted.countDown()
        }
        assertEquals(EngineSlot.AcquireResult.GRANTED, r)
        assertEquals("r-new", slot.owner)
    }

    @Test
    fun `忙时前台请求抢占超时兜底驳回（不静默挂死）`() {
        val slot = EngineSlot(preemptWaitMs = 30, pollMs = 1)
        slot.tryAcquire("r-stuck", true) {}
        var preempted = false
        val r = slot.tryAcquire("r-new", foreground = true) { preempted = true }
        assertEquals(EngineSlot.AcquireResult.DENIED_TIMEOUT, r)
        assertTrue(preempted) // 抢占回调仍已发出（在途方收到中断信号）
        assertTrue(slot.isBusy)
    }

    @Test
    fun `release 仅槽主生效且幂等`() {
        val slot = EngineSlot()
        slot.tryAcquire("r1", true) {}
        slot.release("r-other") // 非槽主：无效
        assertTrue(slot.isBusy)
        slot.release("r1")
        assertFalse(slot.isBusy)
        assertEquals(null, slot.owner)
        slot.release("r1") // 幂等
        assertFalse(slot.isBusy)
    }

    @Test
    fun `释放后新请求立即可授予（含后台请求）`() {
        val slot = EngineSlot()
        slot.tryAcquire("r1", true) {}
        slot.release("r1")
        assertEquals(
            EngineSlot.AcquireResult.GRANTED,
            slot.tryAcquire("r2-summarizer", foreground = false) {},
        )
    }

    @Test
    fun `并发申请原子互斥：至多一个 GRANTED（防 TOCTOU）`() {
        val slot = EngineSlot()
        val granted = java.util.concurrent.atomic.AtomicInteger(0)
        val latch = CountDownLatch(8)
        repeat(8) { i ->
            Thread {
                if (slot.tryAcquire("r$i", foreground = false) {} ==
                    EngineSlot.AcquireResult.GRANTED
                ) {
                    granted.incrementAndGet()
                }
                latch.countDown()
            }.start()
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        assertEquals(1, granted.get()) // 单执行槽硬约束
    }
}
