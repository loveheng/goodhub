package com.zzh.goodhub.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/// SocketTokenWriter JVM 单测（on-device S3-7 UDS 化）：成帧（长度前缀 BE）/EOS/
/// 部分写补齐/写超时死锁分类——socketpair 装配由 EngineDataPlane 承载，
/// 本测覆盖纯逻辑（FrameTransport 假通道）。
class SocketTokenWriterTest {
    /// 假通道：记录写入字节；可配置每次 write 返回 n（模拟部分写/would block）
    /// 与 awaitWritable 行为。
    private class FakeTransport(
        private var writesBeforeFull: Int = Int.MAX_VALUE,
        private var awaitWritableResult: Boolean = true,
    ) : FrameTransport {
        val out = ByteArrayOutputStream()
        var awaitCalls = 0
        var closed = false

        override fun write(src: ByteBuffer): Int {
            if (writesBeforeFull <= 0) return 0
            writesBeforeFull--
            val n = src.remaining()
            val buf = ByteArray(n)
            src.get(buf)
            out.write(buf)
            return n
        }

        override fun awaitWritable(timeoutMs: Int): Boolean {
            awaitCalls++
            return awaitWritableResult
        }

        override fun close() {
            closed = true
        }

        fun bytes(): ByteArray = out.toByteArray()
    }

    @Test
    fun `frame format is magic + type + big-endian length prefix (TLV)`() {
        val t = FakeTransport()
        val w = SocketTokenWriter(t)
        val payload = "你好".toByteArray(Charsets.UTF_8)
        w.writeToken(payload)
        val bytes = t.bytes()
        assertEquals(SocketTokenWriter.HEADER_BYTES + payload.size, bytes.size)
        assertEquals(SocketTokenWriter.MAGIC0, bytes[0])
        assertEquals(SocketTokenWriter.MAGIC1, bytes[1])
        assertEquals(0x00.toByte(), bytes[2]) // type 0x0001 TOKEN_CHUNK（大端高字节）
        assertEquals(0x01.toByte(), bytes[3]) // type 低字节
        assertEquals(0, bytes[4].toInt())
        assertEquals(0, bytes[5].toInt())
        assertEquals(0, bytes[6].toInt())
        assertEquals(payload.size, bytes[7].toInt())
        assertEquals(
            "你好",
            String(bytes, SocketTokenWriter.HEADER_BYTES, payload.size, Charsets.UTF_8),
        )
    }

    @Test
    fun `eos frame is magic + EOS type + zero-length prefix`() {
        val t = FakeTransport()
        val w = SocketTokenWriter(t)
        w.writeEos()
        assertTrue(
            t.bytes().contentEquals(
                byteArrayOf(
                    SocketTokenWriter.MAGIC0, SocketTokenWriter.MAGIC1,
                    0x00, 0x0F, // type 0x000F EOS
                    0, 0, 0, 0, // payload_len = 0
                ),
            ),
        )
    }

    @Test
    fun `partial writes are completed across multiple calls`() {
        // 每次至多写 3 字节且交替 would-block（模拟 socket 窗口极小），
        // 帧必须循环补齐不撕裂，可写等待必须被触发。
        val t = FakeTransport()
        var calls = 0
        val gated = object : FrameTransport by t {
            override fun write(src: ByteBuffer): Int {
                if (++calls % 2 == 0) return 0 // 交替 would-block
                val n = minOf(src.remaining(), 3)
                val buf = ByteArray(n)
                src.get(buf)
                t.out.write(buf)
                return n
            }

            override fun awaitWritable(timeoutMs: Int): Boolean = t.awaitWritable(timeoutMs)
        }
        val w = SocketTokenWriter(gated)
        w.writeToken("stream chunk".toByteArray(Charsets.UTF_8))
        assertEquals(SocketTokenWriter.HEADER_BYTES + 12, t.bytes().size)
        assertTrue("expect multiple partial writes", calls > 6)
        assertTrue(t.awaitCalls > 0)
    }

    @Test
    fun `write timeout raises IpcDeadlock`() {
        val t = FakeTransport(writesBeforeFull = 0, awaitWritableResult = false)
        val w = SocketTokenWriter(t, writeTimeoutMs = 50)
        val e = assertThrows(IpcDeadlockException::class.java) {
            w.writeToken(byteArrayOf(1, 2, 3))
        }
        assertTrue(e.message!!.contains("consumer dead"))
    }

    @Test
    fun `close closes transport`() {
        val t = FakeTransport()
        SocketTokenWriter(t).close()
        assertTrue(t.closed)
    }
}
