package com.zzh.goodhub.engine

import java.lang.invoke.MethodHandles
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.locks.LockSupport

/// Token 数据面 SPSC 环形缓冲（on-device-npu-deployment.md §6.1）。
///
/// 内存布局（共享内存首部起，LITTLE_ENDIAN）：
/// ```
/// [0..3]   write_idx (u32, 单调自增)
/// [4..7]   read_idx  (u32, 单调自增)
/// [8..]    槽区 capacity×4B，载荷 = 原始 token id（uint32，非字符串）
/// ```
/// 单调自增掩码协议：容量恒为 2 的幂，`idx & MASK` 寻址；`write_idx - read_idx`
/// 以无符号减法判定空（==0）/满（==capacity），利用 u32 自然溢出免显式回绕重置，
/// 消除无锁队列边界回绕死锁风险（§6.1）。
///
/// 跨进程原子性：头两字经 `byteBufferViewVarHandle` 以 volatile 语义访问
/// （ARM 上映射 ldar/stlr，跨进程可见，Android API 33+ 支持 VarHandle）；
/// 载荷槽由唯一写者写、读者 acquire 后消费，SPSC 单写单读下无撕裂。
///
/// 本类为纯逻辑件（只依赖 ByteBuffer/JDK），可在 JVM 单测中覆盖；真实共享内存
/// 由 [EngineDataPlane] 装配。
class TokenRingBuffer private constructor(
    private val buffer: ByteBuffer,
    private val capacity: Int,
) {
    private val handle = MethodHandles.byteBufferViewVarHandle(IntArray::class.java, ByteOrder.LITTLE_ENDIAN)
    private val mask = capacity - 1
    private val slots: ByteBuffer = buffer.duplicate().apply {
        position(HEADER_BYTES)
        limit(requiredBytes(capacity))
    }.slice().order(ByteOrder.LITTLE_ENDIAN)

    /// u32 语义：Int 比特位即 u32，差值比较用无符号减法（Int 减法天然回绕）。
    /// 注意：byteBufferViewVarHandle 的 int 坐标是**字节偏移**（须 4B 对齐），
    /// write_idx@0 / read_idx@4。
    private var writeIdx: Int
        get() = handle.getVolatile(buffer, 0) as Int
        set(value) = handle.setVolatile(buffer, 0, value)

    private var readIdx: Int
        get() = handle.getVolatile(buffer, 4) as Int
        set(value) = handle.setVolatile(buffer, 4, value)

    /// 可消费 token 数（u32 减法：负差值即回绕后的大正数）。
    private fun available(): Int = writeIdx - readIdx

    /**
     * 写入一批 token id（:engine 侧唯一写者）。
     *
     * 缓冲满时施加**有界等待**而非丢弃（§6.3 有界背压）：park ≤1ms 粒度等待，
     * 超过 [writeTimeoutMs] 仍无空间 → 判定消费端死锁，抛 [IpcDeadlockException]
     * （调用方走 §6.3 中断路径：中止生成、清空缓冲、上报切云，不空转占硬件）。
     */
    fun write(tokens: IntArray, writeTimeoutMs: Long = WRITE_TIMEOUT_MS) {
        val deadline = System.nanoTime() + writeTimeoutMs * 1_000_000
        var i = 0
        while (i < tokens.size) {
            if (available() == capacity) {
                val remain = deadline - System.nanoTime()
                if (remain <= 0) {
                    throw IpcDeadlockException(
                        "ring buffer full for ${writeTimeoutMs}ms (capacity=$capacity, " +
                            "pending=${tokens.size - i} tokens) — consumer dead or stalled",
                    )
                }
                LockSupport.parkNanos(minOf(remain, 1_000_000))
                continue
            }
            val w = writeIdx
            slots.putInt((w and mask) * 4, tokens[i])
            // volatile 写自带 release 语义，发布槽内容后再推进 write_idx。
            writeIdx = w + 1
            i++
        }
        wake()
    }

    /**
     * 排空当前可用 token（消费端 40ms 节拍/唤醒触发时调用，§6.1 微批满窗口排空）。
     * 返回按序 token 列表；无可消费返回空表。
     */
    fun drain(maxTokens: Int = capacity): IntArray {
        val n = minOf(available(), maxTokens)
        if (n <= 0) return IntArray(0)
        val out = IntArray(n)
        for (i in 0 until n) {
            val r = readIdx
            out[i] = slots.getInt((r and mask) * 4)
            readIdx = r + 1
        }
        return out
    }

    /// 清空未消费在途 Token（§6.3 cancel：清 RingBuffer 后下发 cancelled 收尾）。
    /// 仅取消/死锁自救路径调用（单写者场景下安全：写者已停）。
    fun clearPending() {
        readIdx = writeIdx
    }

    /// 诊断（S2-5）：写者视角的游标现场——区分「读者 readIdx 写入对写者不可见」
    /// 与「写侧算术错误」。
    fun diagCursor(): String {
        val wi = writeIdx
        val ri = readIdx
        return "wi=$wi ri=$ri avail=${wi - ri} cap=$capacity"
    }

    /// 唤醒钩子：由 [EngineDataPlane] 注入（pipe/eventfd 写端写 1 字节）。
    /// 纯 JVM 可测（无 android 依赖）；注入方自行决定失败是否留痕。
    internal var onWakeup: (() -> Unit)? = null

    private fun wake() {
        try {
            onWakeup?.invoke()
        } catch (e: Exception) {
            // 唤醒失败只意味着消费端少一次提前唤醒（仍有 40ms 节拍兜底），不中断生成。
            System.err.println("[DEGRADE] ring wakeup failed: $e")
        }
    }

    companion object {
        /// §6.3 拍板：500ms 写超时 → IPC_DEADLOCK（decode 35ms/token，500ms 未被
        /// 消费即消费线程死锁或主进程 ANR）。
        const val WRITE_TIMEOUT_MS = 500L

        /// 默认容量 1024 槽 ≈ 4KB（§6.3 按数秒容量预留）。
        const val DEFAULT_CAPACITY = 1024

        /// 头部 8B（write/read idx 各 4B）。
        const val HEADER_BYTES = 8

        fun requiredBytes(capacity: Int): Int = HEADER_BYTES + capacity * 4

        /// capacity 必须为 2 的幂（掩码协议硬约束）；buffer 须覆盖 [0, requiredBytes)。
        fun create(buffer: ByteBuffer, capacity: Int): TokenRingBuffer {
            require(capacity > 0 && (capacity and (capacity - 1)) == 0) {
                "ring capacity must be a power of two, got $capacity"
            }
            require(buffer.capacity() >= requiredBytes(capacity)) {
                "buffer too small: ${buffer.capacity()} < ${requiredBytes(capacity)}"
            }
            buffer.order(ByteOrder.LITTLE_ENDIAN)
            return TokenRingBuffer(buffer, capacity)
        }
    }
}

/// §6.3 IPC 死锁判定：写超时后 :engine 不永久挂起，主动中断本次生成并切云。
class IpcDeadlockException(message: String) : RuntimeException(message)
