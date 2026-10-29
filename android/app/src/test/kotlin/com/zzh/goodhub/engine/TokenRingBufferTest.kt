package com.zzh.goodhub.engine

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/// TokenRingBuffer JVM 单测（on-device S1-3）：掩码协议 / 回绕 / 背压超时 /
/// 清空在途——共享内存装配由 EngineDataPlane 承载，本测覆盖纯逻辑。
class TokenRingBufferTest {
    private fun newRing(capacity: Int): Pair<TokenRingBuffer, ByteBuffer> {
        val buffer = ByteBuffer.allocateDirect(TokenRingBuffer.requiredBytes(capacity))
        return TokenRingBuffer.create(buffer, capacity) to buffer
    }

    @Test
    fun `drain preserves order across mask wraparound`() {
        val capacity = 8
        val (ring, _) = newRing(capacity)
        // 写 3×capacity 个 token：跨越回绕边界两轮余一。
        val all = IntArray(capacity * 3 - 1) { it + 1 }
        var sent = 0
        val received = ArrayList<Int>()
        while (sent < all.size) {
            val batch = all.copyOfRange(sent, minOf(sent + capacity / 2, all.size))
            ring.write(batch, writeTimeoutMs = 1000)
            sent += batch.size
            ring.drain().forEach { received.add(it) }
        }
        assertArrayEquals(all, received.toIntArray())
    }

    @Test
    fun `write beyond capacity without drain times out with IpcDeadlock`() {
        val (ring, _) = newRing(4)
        ring.write(intArrayOf(1, 2, 3, 4), writeTimeoutMs = 50)
        try {
            ring.write(intArrayOf(5), writeTimeoutMs = 50)
            throw AssertionError("expected IpcDeadlockException")
        } catch (e: IpcDeadlockException) {
            assertTrue(e.message!!.contains("full"))
        }
    }

    @Test
    fun `clearPending drops unconsumed tokens`() {
        val (ring, _) = newRing(8)
        ring.write(intArrayOf(1, 2, 3), writeTimeoutMs = 1000)
        ring.clearPending()
        assertArrayEquals(IntArray(0), ring.drain())
        // 清空后可继续写入（取消后引擎复位场景）。
        ring.write(intArrayOf(9), writeTimeoutMs = 1000)
        assertArrayEquals(intArrayOf(9), ring.drain())
    }

    @Test
    fun `drain on empty returns empty`() {
        val (ring, _) = newRing(8)
        assertArrayEquals(IntArray(0), ring.drain())
    }

    @Test
    fun `spsc producer consumer crosses wraparound without loss`() {
        val capacity = 16
        val (ring, _) = newRing(capacity)
        val total = capacity * 5
        val received = ArrayList<Int>()
        val consumer = Thread {
            var got = 0
            while (got < total) {
                ring.drain().forEach { received.add(it); got++ }
                Thread.yield()
            }
        }
        consumer.start()
        for (t in 1..total) {
            ring.write(intArrayOf(t), writeTimeoutMs = 5000)
        }
        consumer.join(5000)
        assertEquals((1..total).toList(), received)
    }

    @Test
    fun `capacity must be power of two`() {
        try {
            newRing(6)
            throw AssertionError("expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("power of two"))
        }
    }
}
