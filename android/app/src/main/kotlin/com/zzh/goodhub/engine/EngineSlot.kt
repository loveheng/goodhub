package com.zzh.goodhub.engine

import java.util.concurrent.atomic.AtomicBoolean

/**
 * 端侧引擎单执行槽（on-device S3-3，NPU 稿 §6.6 / 总纲 §2 v2.6）。
 *
 * 纯逻辑件（无 Android 依赖，JVM 单测覆盖）；承载策略 B + 抢占规则的原子
 * 判定，EngineService 接线时把析构动作（preempt 回调 = §6.3 abort 在途
 * 生成）注入本件，槽只管判定与等待，不直接触碰推理资源。
 *
 * 规则（§6.6 v2.4 拍板）：
 *  - **单执行槽**：任何时刻至多一个 generate 在跑（NPU 静态图/KV/VTCM
 *    物理单重入）；
 *  - **后台任务驳回（默认）**：槽占用时非前台请求立即 [AcquireResult.DENIED_BUSY]
 *    （ServiceBusyException 语义），调用方捕获即切云——不维护堆积队列；
 *  - **前台抢占**：前台请求到达且槽占用 → 先调 [preempt]（:engine 内对在途
 *    请求 abort，token 粒度快速中断），再有界等待槽释放后授予——覆盖
 *    「前台对后台 cancel 让槽」与「前台连发新消息中断旧请求执行最新」两条
 *    路径，**绝不驳回用户**（等待超时的兜底驳回走云端完成，不静默丢弃）；
 *  - **原子性**：授予经 [AtomicBoolean] CAS，杜绝「先 check 后 generate」
 *    的 TOCTOU 缝隙（总纲 §2 v2.6：busy 仅瞬时快照禁缓存，一切请求直接
 *    撞槽原子判定）。
 */
class EngineSlot(
    /** 前台抢占等待槽释放的上限（毫秒）：在途 abort 正常 ~1 token 周期内
     *  释放（实测 ~60ms），1.5s 兜底覆盖 native 异常滞留；超时即驳回切云。 */
    private val preemptWaitMs: Long = DEFAULT_PREEMPT_WAIT_MS,
    /** 抢占等待轮询步长（毫秒）。 */
    private val pollMs: Long = 10,
) {
    companion object {
        const val DEFAULT_PREEMPT_WAIT_MS = 1500L
    }

    enum class AcquireResult { GRANTED, DENIED_BUSY, DENIED_TIMEOUT }

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
     * @param foreground 是否前台请求（前台 = 可抢占；后台 = 忙即驳回）。
     * @param preempt 抢占回调（仅前台且槽占用时触发一次）：接线方对在途
     *   请求发出中断（§6.3 abort），中断完成由在途方 [release] 承载。
     */
    fun tryAcquire(
        requestId: String,
        foreground: Boolean,
        preempt: () -> Unit,
    ): AcquireResult {
        // 快路径：槽空闲 CAS 授予（与并发到达的其他请求原子互斥）。
        if (busyFlag.compareAndSet(false, true)) {
            owner = requestId
            return AcquireResult.GRANTED
        }
        // 策略 B：后台请求忙即驳回（不等待、不排队）。
        if (!foreground) return AcquireResult.DENIED_BUSY
        // 前台抢占：中断在途 + 有界等待释放（绝不驳回用户）。
        preempt()
        val deadlineNanos = System.nanoTime() + preemptWaitMs * 1_000_000
        while (busyFlag.get() && System.nanoTime() < deadlineNanos) {
            Thread.sleep(pollMs)
        }
        // CAS 授予：等到的释放瞬间与并发请求竞争，胜者成为新槽主。
        if (busyFlag.compareAndSet(false, true)) {
            owner = requestId
            return AcquireResult.GRANTED
        }
        return AcquireResult.DENIED_TIMEOUT
    }

    /** 释放执行槽（仅槽主生效；幂等）。 */
    fun release(requestId: String) {
        if (owner != requestId) return
        owner = null
        busyFlag.set(false)
    }
}
