package com.zzh.goodhub.engine

import java.io.IOException
import java.nio.ByteBuffer

/// §6.3 IPC 死锁判定（语义随数据面 UDS 化迁移自 TokenRingBuffer）：写超时后
/// :engine 不永久挂起，主动中断本次生成并切云。
class IpcDeadlockException(message: String) : RuntimeException(message)

/// 数据面帧类型（TLV 的 T，与 libgdw 读端同一常量语义）。大块数据（文生图
/// 产物等）走「落盘 + 元数据帧引用」零拷贝范式，不入本协议载荷。
enum class FrameType(val value: Short) {
    /// LLM 逐字增量文本（payload = UTF-8 字节）。
    TOKEN_CHUNK(0x0001),

    /// 图像生成完成元数据（payload = JSON：引用句柄 + 宽高）——多模态 epic
    /// 开工时启用，当前无生产端，仅协议留位。
    IMAGE_META(0x0002),

    /// 生成进度（payload = [4B 大端 current][4B 大端 total]）——同上留位。
    PROGRESS(0x0003),

    /// 流终结帧（payload_len 恒 0）——Dart 流生命周期唯一事实源。
    EOS(0x000F),
}

/// 帧传输原语（[SocketTokenWriter] 的可测接缝）：Android 实装 = 非阻塞
/// UDS fd（`Os.write` + `Os.poll`，见 EngineDataPlane）；JVM 单测 = 假通道。
interface FrameTransport : AutoCloseable {
    /// 非阻塞写：返回实际写入字节数；0 = 暂不可写（would block）。
    /// 传输层致命错误抛 [IOException]。
    fun write(src: ByteBuffer): Int

    /// 可写等待：true = [timeoutMs] 内恢复可写；false = 超时（调用方判死锁）。
    fun awaitWritable(timeoutMs: Int): Boolean
}

/// 端侧引擎数据面写帧器（on-device-npu-deployment.md §6.1 v3.1，UDS 化）：
/// TLV 成帧 `[2 字节魔数 0x5A 0xA5][2 字节帧类型][4 字节大端 payload_len]
/// [payload]`，单方向单写者顺序写。魔数为对齐/失步校验字：读端读到魔数
/// 不匹配即判协议腐化 fail-fast 退出（纯长度前缀在 1 字节流偏移后可能读到
/// 伪造长度全线跑偏）；类型字段使协议**终生定型**——文字/进度/图像元数据/
/// 未知未来类型共用同一帧格式，新增载荷类型不重构协议。
///
/// - [FrameType.EOS]（payload_len = 0）= **流终结帧**（[writeEos]）：每代生成
///   收尾前必发，读端将其投给 Dart——**Dart 流生命周期唯一事实源 = EOS**
///   （收尾事件仅作控制面通知，不参与流的开关，跨信道时序同步整体不做）。
/// - 大块数据（文生图产物等）**不走本协议载荷**：写端落盘后经元数据帧传
///   引用（零拷贝范式），socket 上恒为 KB 级帧。
/// - 背压：socket 发送缓冲满（512KB，EngineDataPlane 显式调大）→ `write`
///   返回 0 → [FrameTransport.awaitWritable] 等可写。**有界等待**：总预算
///   [writeTimeoutMs]（3000ms——写超时仅在消费端**真实长失速**时触发：
///   512KB 缓冲池足以吸收主进程 GC 暂停/Flutter 转场渲染数百毫秒级瞬时
///   卡顿，短卡顿不再产生任何写阻塞），超时抛 [IpcDeadlockException]，
///   调用方走 abort + 切云，绝不空转占硬件。
/// - 部分写：流式 socket 允许部分写入，循环补齐（帧完整性由读端按
///   魔数+类型+长度前缀重组保证，单写者顺序写下无交错）。
/// - SIGPIPE：本进程为 zygote fork（app_process 启动即 `signal(SIGPIPE,
///   SIG_IGN)`），对端关闭的写入返回 EPIPE 而非杀进程，经 IOException/
///   ErrnoException 正常上抛。
class SocketTokenWriter(
    private val transport: FrameTransport,
    private val writeTimeoutMs: Long = WRITE_TIMEOUT_MS,
) : AutoCloseable {

    /** 按帧类型写入（写超时后中止：生成线程收口 abort + onIpcDeadlock）。 */
    fun writeFrame(type: FrameType, payload: ByteArray) {
        val deadline = System.nanoTime() + writeTimeoutMs * 1_000_000
        writeFully(headerOf(type, payload.size), deadline)
        if (payload.isNotEmpty()) writeFully(ByteBuffer.wrap(payload), deadline)
    }

    /// LLM 增量文本帧（TOKEN_CHUNK）。
    fun writeToken(payload: ByteArray) = writeFrame(FrameType.TOKEN_CHUNK, payload)

    /// EOS 流终结帧：`[0x5A 0xA5][0x000F][4B 00 00 00 00]`（payload_len = 0）。
    fun writeEos() = writeFrame(FrameType.EOS, ByteArray(0))

    override fun close() {
        runCatching { transport.close() }
    }

    private fun headerOf(type: FrameType, len: Int): ByteBuffer =
        ByteBuffer.allocate(HEADER_BYTES)
            .put(MAGIC0).put(MAGIC1)
            .putShort(type.value) // 大端（ByteBuffer 默认 BIG_ENDIAN）
            .putInt(len)
            .apply { flip() }

    private fun writeFully(buf: ByteBuffer, deadlineNanos: Long) {
        while (buf.hasRemaining()) {
            val n = transport.write(buf)
            if (n > 0) continue
            val remainMs = (deadlineNanos - System.nanoTime()) / 1_000_000
            if (remainMs <= 0) {
                throw IpcDeadlockException(
                    "socket write stalled for ${writeTimeoutMs}ms " +
                        "(remaining=${buf.remaining()}B) — consumer dead or stalled",
                )
            }
            if (!transport.awaitWritable(remainMs.toInt().coerceAtMost(POLL_SLICE_MS))) {
                throw IpcDeadlockException(
                    "socket not writable for ${writeTimeoutMs}ms — consumer dead or stalled",
                )
            }
        }
    }

    companion object {
        /// 帧魔数（对齐/失步校验字，与 libgdw 读端同一常量语义）。
        const val MAGIC0: Byte = 0x5A
        const val MAGIC1: Byte = 0xA5.toByte()

        /// 帧头长（魔数 2B + 类型 2B + 长度 4B）。
        const val HEADER_BYTES = 8

        /// 写超时 → IPC_DEADLOCK：3000ms（S3-7 修订：写超时仅在消费端真实
        /// 长失速时触发——512KB socket 缓冲池吸收 GC 暂停/渲染卡顿等数百
        /// 毫秒级瞬时阻塞，旧 500ms 口径系 RingBuffer 4KB 容量所迫，随缓冲
        /// 池扩大同步放宽，防误杀）。
        const val WRITE_TIMEOUT_MS = 3000L

        /// 单次可写等待上限（毫秒）：预算切片，保证超时判定粒度不超预算过多。
        const val POLL_SLICE_MS = 100
    }
}
