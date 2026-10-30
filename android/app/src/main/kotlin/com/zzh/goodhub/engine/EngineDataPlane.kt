package com.zzh.goodhub.engine

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.IOException
import java.nio.ByteBuffer
import android.system.StructTimeval

/// 端侧引擎数据面装配（on-device-npu-deployment.md §6.1 v3.1，UDS 化）：
/// AF_UNIX SOCK_STREAM socketpair（`ParcelFileDescriptor.createSocketPair`）
/// 承载 token 字节流，**共享内存 RingBuffer / VarHandle 游标 / pipe 唤醒
/// 已整体退役**（S3-7：唤醒、背压、崩溃隔离均由内核 socket 语义承载——
/// 可读事件唤醒、SO_RCVBUF 满即写端阻塞/暂不可写形成天然流控、对端关闭
/// 即 EOF 可判活自愈；无共享游标即无游标错位类 Bug）。
///
/// fd 传递：写端留在 :engine（[SocketTokenWriter]），读端经 AIDL
/// `getDataSocketFd()` 以 ParcelFileDescriptor 传主进程（Binder dup 语义，
/// detachFd 后由主进程 native worker（libgdw）持有读循环）。
class EngineDataPlane : AutoCloseable {
    companion object {
        private const val TAG = "EngineDataPlane"

        /// 背压缓冲池（每端 SNDBUF/RCVBUF 各 512KB，S3-7 修订）。
        const val SOCKET_BUFFER_BYTES = 512 * 1024
    }

    private val sockets: Array<ParcelFileDescriptor> =
        ParcelFileDescriptor.createSocketPair().also { pair ->
            // 背压缓冲池显式调大至 512KB（内核默认几十~两百 KB）：吸收主进程
            // GC 暂停 / Flutter 转场渲染的数百毫秒级瞬时卡顿，写超时仅在消费
            // 端真实长失速时触发（防误杀，S3-7 修订）。两端各设，内核对
            // SO_SNDBUF/SO_RCVBUF 值有翻倍/下限策略，512KB 为请求值。
            for (p in pair) tuneBuffer(p)
        }

    private fun tuneBuffer(p: ParcelFileDescriptor) {
        try {
            Os.setsockoptInt(
                p.fileDescriptor, OsConstants.SOL_SOCKET,
                OsConstants.SO_SNDBUF, SOCKET_BUFFER_BYTES,
            )
            Os.setsockoptInt(
                p.fileDescriptor, OsConstants.SOL_SOCKET,
                OsConstants.SO_RCVBUF, SOCKET_BUFFER_BYTES,
            )
        } catch (e: ErrnoException) {
            // 非数据面降级：默认缓冲仍可用（只是瞬时卡顿吸收能力下降），
            // 留痕不阻断（§4.2）。
            Log.w(TAG, "[DEGRADE] socket buffer tune failed: ${e.errno}")
        }
    }

    /// :engine 侧写者视图（非阻塞 UDS + Os.poll 可写等待）。
    val writer: SocketTokenWriter = SocketTokenWriter(OsFrameTransport(sockets[0]))

    /// 主进程侧取数据面读端 fd（每次 dup，调用方/Binder 层负责传递语义）。
    fun dataSocketFd(): ParcelFileDescriptor =
        ParcelFileDescriptor.dup(sockets[1].fileDescriptor)

    override fun close() {
        runCatching { writer.close() }
        runCatching { sockets[0].close() }
        runCatching { sockets[1].close() }
    }
}

/// FrameTransport 的 Android 实装：阻塞写 + `SO_SNDTIMEO` 超时切片 +
/// `Os.poll(POLLOUT)` 可写等待。不设 O_NONBLOCK（`Os` 无公开 fcntl 设旗面）：
/// 阻塞写的超时语义由 SO_SNDTIMEO 承载——写阻塞不超过切片时长（100ms），
/// 零进展即返回 EAGAIN（映射为 0 = would block），总超时判定仍归
/// SocketTokenWriter 的 500ms deadline（有界背压语义不变）。
private class OsFrameTransport(private val pfd: ParcelFileDescriptor) : FrameTransport {
    private val fd = pfd.fileDescriptor

    init {
        try {
            Os.setsockoptTimeval(
                fd,
                OsConstants.SOL_SOCKET,
                OsConstants.SO_SNDTIMEO,
                StructTimeval.fromMillis(SocketTokenWriter.POLL_SLICE_MS.toLong()),
            )
        } catch (e: ErrnoException) {
            throw IOException("SO_SNDTIMEO failed: ${e.errno}", e)
        }
        Log.i(
            "EngineDataPlane",
            "uds data plane writer ready wfd=${pfd.fd}",
        )
    }

    override fun write(src: ByteBuffer): Int = try {
        val n = Os.write(fd, src)
        if (n > 0) n else 0
    } catch (e: ErrnoException) {
        // EAGAIN = SO_SNDTIMEO 切片内零进展（暂不可写）；EINTR = 信号打断（重试）。
        if (e.errno == OsConstants.EAGAIN || e.errno == OsConstants.EINTR) 0
        else throw IOException("uds write failed: ${e.errno}", e)
    }

    override fun awaitWritable(timeoutMs: Int): Boolean = try {
        val p = android.system.StructPollfd().apply {
            this.fd = this@OsFrameTransport.fd
            events = OsConstants.POLLOUT.toShort()
        }
        Os.poll(arrayOf(p), timeoutMs) > 0
    } catch (e: ErrnoException) {
        if (e.errno == OsConstants.EINTR) true else throw IOException("poll failed: ${e.errno}", e)
    }

    override fun close() {
        runCatching { pfd.close() }
    }
}
