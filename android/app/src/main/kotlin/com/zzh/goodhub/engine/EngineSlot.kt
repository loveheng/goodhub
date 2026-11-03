package com.zzh.goodhub.engine

import java.util.concurrent.atomic.AtomicBoolean

/**
 * 端侧引擎单执行槽（on-device S3-3，NPU 稿 §6.6 / 总纲 §2 v2.6；**打断术语
 * 于 task-capability S14e 订正**）。
 *
 * 纯逻辑件（无 Android 依赖，JVM 单测覆盖）；承载策略 B + 协作式打断规则的
 * 原子判定，EngineService 接线时把析构动作（打断回调 = §6.3 abort 在途生成）
 * 注入本件，槽只管判定与等待，不直接触碰推理资源。
 *
 * 规则（§6.6 v2.4 拍板 + S14e 订正）：
 *  - **单执行槽**：任何时刻至多一个 generate 在跑（NPU 静态图/KV/VTCM
 *    物理单重入）；
 *  - **后台任务驳回（默认）**：槽占用时非前台请求立即 [AcquireResult.DENIED_BUSY]
 *    （ServiceBusyException 语义），调用方捕获即切云——不维护堆积队列；
 *  - **前台协作式打断**：前台请求到达且槽占用 → 先调 [interrupt]（:engine 内对
 *    在途请求 abort，token 粒度快速中断），再有界等待槽释放后授予——覆盖
 *    「前台对后台 cancel 让槽」与「前台连发新消息中断旧请求执行最新」两条路径。
 *
 * **打断是协作式，不是抢占式（S14e，K11）**：底层推理算子阻塞且不可切分，
 * 中断只在生成循环的检查点生效；等待窗口耗尽返回
 * [AcquireResult.DENIED_INTERRUPT_NOT_EFFECTIVE]——**不得假设打断已生效**
 * （在途生成可能仍在跑、算力仍被占），上层按策略性降级处置（切云或显式
 * 上浮等待），**不得以重启引擎进程的方式强行腾出算力**（重启即冷装载 =
 * 秒级装载 + 前台卡顿）。旧表述「绝不驳回用户」在物理层不成立（实测降级为
 * 「绝不立刻满足」：窗口耗尽即切云完成本轮）。引擎侧单执行槽的 CAS 授予另称
 * 「原子授予」，与「协作式打断」是两件事，勿混称「抢占」。
 *
 *  - **原子性**：授予经 [AtomicBoolean] CAS，杜绝「先 check 后 generate」
 *    的 TOCTOU 缝隙（总纲 §2 v2.6：busy 仅瞬时快照禁缓存，一切请求直接
 *    撞槽原子判定）。
 */
class EngineSlot(
    /** 协作式打断等待槽释放的上限（毫秒）：在途 abort 正常 ~1 token 周期内
     *  释放（实测 ~60ms），1.5s 兜底覆盖 native 异常滞留；耗尽即判打断未生效
     *  （DENIED_INTERRUPT_NOT_EFFECTIVE），上层按策略性降级处置（切云）。 */
    private val interruptWaitMs: Long = DEFAULT_INTERRUPT_WAIT_MS,
    /** 打断等待轮询步长（毫秒）。 */
    private val pollMs: Long = 10,
) {
    companion object {
        const val DEFAULT_INTERRUPT_WAIT_MS = 1500L
    }

    enum class AcquireResult {
        GRANTED,

        /** 槽被占且本次请求不可授予（后台忙驳回，不打断不等待）。 */
        DENIED_BUSY,

        /** 协作式打断等待窗口耗尽：**打断未生效**（在途生成可能仍在跑，
         *  算力仍被占）——上层不得假设已腾出，按策略性降级处置。 */
        DENIED_INTERRUPT_NOT_EFFECTIVE,
    }

    private val busyFlag = AtomicBoolean(false)

    /** 当前槽主请求 id（观测面：日志/诊断）。 */
    @Volatile
    var owner: String? = null
        private set

    val isBusy: Boolean
        get() = busyFlag.get()

    /**
     * 原子申请执行槽。
     *
     * @param requestId 新请求 id（授予后成为槽主）。
     * @param foreground 是否前台请求（前台 = 可请求协作式打断；后台 = 忙即驳回）。
     * @param interrupt 协作式打断回调（仅前台且槽占用时触发一次）：接线方对
     *   在途请求发出中断（§6.3 abort），中断完成由在途方 [release] 承载。
     *   **回调发出 ≠ 打断生效**——等待窗口耗尽即判未生效（见
     *   [AcquireResult.DENIED_INTERRUPT_NOT_EFFECTIVE]）。
     */
    fun tryAcquire(
        requestId: String,
        foreground: Boolean,
        interrupt: () -> Unit,
    ): AcquireResult {
        // 快路径：槽空闲 CAS 授予（与并发到达的其他请求原子互斥）。
        if (busyFlag.compareAndSet(false, true)) {
            owner = requestId
            return AcquireResult.GRANTED
        }
        // 策略 B：后台请求忙即驳回（不等待、不排队、不打断）。
        if (!foreground) return AcquireResult.DENIED_BUSY
        // 前台协作式打断：中断在途 + 有界等待释放（打断只在检查点生效，
        // 非抢占式强制切换）。
        interrupt()
        val deadlineNanos = System.nanoTime() + interruptWaitMs * 1_000_000
        while (busyFlag.get() && System.nanoTime() < deadlineNanos) {
            Thread.sleep(pollMs)
        }
        // CAS 授予：等到的释放瞬间与并发请求竞争，胜者成为新槽主。
        if (busyFlag.compareAndSet(false, true)) {
            owner = requestId
            return AcquireResult.GRANTED
        }
        // 窗口耗尽：打断**未生效**（不得假设在途已停、算力已腾出）——上层
        // 按策略性降级处置（切云或显式上浮等待），不得重启引擎腾算力。
        return AcquireResult.DENIED_INTERRUPT_NOT_EFFECTIVE
    }

    /** 释放执行槽（仅槽主生效；幂等）。 */
    fun release(requestId: String) {
        if (owner != requestId) return
        owner = null
        busyFlag.set(false)
    }
}
