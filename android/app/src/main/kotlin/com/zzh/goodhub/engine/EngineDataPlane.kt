package com.zzh.goodhub.engine

import android.os.ParcelFileDescriptor
import android.os.SharedMemory
import android.system.ErrnoException
import android.util.Log
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer

/// 端侧引擎数据面装配（on-device-npu-deployment.md §6.1）：
/// Ashmem（android.os.SharedMemory）承载 [TokenRingBuffer] + 唤醒 fd。
///
/// 唤醒通道按「可读 fd」契约：**eventfd 需 syscall，JVM/Kotlin 侧以
/// pipe（ParcelFileDescriptor.createPipe）等价承载**——消费端（S3-6 native
/// worker 的 epoll/Looper）只依赖「可读 fd 唤醒」语义，pipe/eventfd 兼容；
/// 若坚持 eventfd 可在 S3-6 native 层替换（fd 类型对 AIDL 契约不透明）。
///
/// fd 传递：SharedMemory 为 AIDL 友好 parcelable（getFdDup/getFd 均 @hide，
/// 2026-10-28 官方源码核实，应用不可依赖），故控制面契约经 getSharedMemory()
/// 直传 parcelable，fd 经 Binder 语义不变。
class EngineDataPlane(
    val capacity: Int = TokenRingBuffer.DEFAULT_CAPACITY,
) : AutoCloseable {
    companion object {
        private const val TAG = "EngineDataPlane"
        private const val SHM_NAME = "goodhub_engine_tokens"
    }

    val sharedMemory: SharedMemory = SharedMemory.create(SHM_NAME, TokenRingBuffer.requiredBytes(capacity))

    /// 唤醒通道：:engine 持写端，主进程经 AIDL getEventFd() 拿读端。
    private val wakePipe: Array<ParcelFileDescriptor> = ParcelFileDescriptor.createPipe()
    private val wakeWrite = FileOutputStream(wakePipe[1].fileDescriptor)

    /// :engine 侧写者视图（读写映射）。
    private val writerBuffer: AutoCloseableByteBuffer = AutoCloseableByteBuffer(sharedMemory.mapReadWrite())

    val ring: TokenRingBuffer = TokenRingBuffer.create(writerBuffer.buffer, capacity)

    init {
        // 诊断打点（S2-5 ipc deadlock 排查）：唤醒链路 fd 溯源——写端 fd 与
        // 经 AIDL dup 出去的读端 fd 是否成对，写计数是否推进。
        Log.i(
            TAG,
            "wakePipe rfd=${wakePipe[0].fd} wfd=${wakePipe[1].fd} cap=$capacity",
        )
        var wakeWrites = 0
        ring.onWakeup = {
            try {
                // §6.1：写完仅一次轻量唤醒写（1 字节），不占 Binder 线程。
                wakeWrite.write(1)
                if (++wakeWrites <= 3 || wakeWrites % 200 == 0) {
                    Log.i(TAG, "wake write #$wakeWrites -> wfd=${wakePipe[1].fd}")
                }
            } catch (e: IOException) {
                Log.w(TAG, "[DEGRADE] wake pipe write failed: $e")
            }
        }
    }

    /// 主进程侧取共享内存 parcelable（每次返回同一实例；Binder 层负责跨进程 dup）。
    fun sharedMemoryForIpc(): SharedMemory = sharedMemory

    /// 主进程侧取唤醒读端 fd（每次 dup，调用方/框架负责关闭）。
    fun eventReadFd(): ParcelFileDescriptor = ParcelFileDescriptor.dup(wakePipe[0].fileDescriptor)

    override fun close() {
        runCatching { wakeWrite.close() }
        runCatching { wakePipe[0].close() }
        runCatching { writerBuffer.close() }
        runCatching { sharedMemory.close() }
    }
}

/// SharedMemory.mapReadWrite 返回的 DirectByteBuffer 无显式 unmap 入口外的
/// 包装（SharedMemory.unmap 需要保留原 ByteBuffer 引用）。
internal class AutoCloseableByteBuffer(val buffer: ByteBuffer) : AutoCloseable {
    override fun close() {
        SharedMemory.unmap(buffer)
    }
}
