package com.zzh.goodhub.engine

import android.content.ComponentCallbacks2

/**
 * 端侧引擎三态生命周期状态机（on-device S2-4，NPU 稿 §4.1）。
 *
 * 纯逻辑件（无 Android 依赖，JVM 单测覆盖）；析构动作经 [onEvict] 回调由
 * 接线方承载（EngineService 里 = Genie 会话 close + 数据面 close），状态机
 * 只管状态与触发规则，不直接触碰资源。
 *
 * 状态（§4.1 命名规范）：
 *  - [ACTIVE]：推理执行中（WARM 档内），生成期间不受 TTL 驱逐；
 *  - [WARM_STANDBY]：模型常驻待命，Inactivity TTL 计时（3~5min 拍板 5min），
 *    计时内新请求零重载续答；
 *  - [COLD_EVICTED]：已析构（进程 RSS < 50MB 由释放动作保证）；再入须快速
 *    暖机（loadModel，资产在盘不重下载）。
 *
 * 触发面：
 *  - [onGenerateStart]/[onGenerateFinished]：ACTIVE ↔ WARM_STANDBY；
 *  - [onTrimMemory]：TRIM_MEMORY_RUNNING_CRITICAL / TRIM_MEMORY_BACKGROUND
 *    及以上 → 立即驱逐（§4.1「onTrimMemory 驱动」）；
 *  - [onTtlElapsed]：TTL 超时驱逐（接线方经 Handler.postDelayed 驱动；
 *    状态机内部校验当前态与代次，防过期计时器误伤新会话）；
 *  - [onMemoryPressure]：内存预算护栏（§4.1）——RSS 逼近 LMK 阈值时即使
 *    TTL 内也提前驱逐。阈值由接线方提供（状态机不设魔法数）。
 *  - [onWarmup]：loadModel 受理/完成回填（COLD → WARM 档重入）。
 *
 * 代次（generation）：每次驱逐 +1、每次 warmup 重置计时基准——过期 TTL
 * 定时器凭代次失配自行作废，杜绝「旧计时器杀新会话」竞态。
 */
class EngineLifecycle(
    /** TTL 时长（毫秒）。§4.1 拍板 3~5min 区间取 5min（后台续航优先）；
     *  R-P0 参数化（on-device-residency S-R0-a）：initEngine Bundle 可注入覆盖。 */
    private var ttlMs: Long = DEFAULT_TTL_MS,
    /** 驱逐动作回调（接线方：Genie 会话 + 数据面释放）。 */
    private val onEvict: (reason: String) -> Unit,
    /**
     * 在途 / 受理中生成判定（接线方：单执行槽 busy 态）。
     *
     * 受理窗口竞态护栏（2026-11-05 真机实证）：执行槽已授予但 [onGenerateStart]
     * 尚未背书 ACTIVE 转换（受理窗口），此间状态仍 WARM_STANDBY——此刻 5min
     * TTL 到点驱逐会孤儿在途生成（空产出 frames=0 + 误导 busy）。busy 时
     * [onTtlElapsed] 拒绝驱逐，待空闲后定时器再触发。默认恒 false = 纯状态机
     * 语义不变（兼容既有测试）。
     */
    private val isBusy: () -> Boolean = { false },
) {
    /** R-P0 驻留策略位：TTL 参数注入（>0 才采用；缺省 5min 零行为变化——
     *  5min 缺省翻动须观测数据支撑，本缝仅为 L1 策略备好注入位）。 */
    fun updateTtlMs(ms: Long) {
        if (ms > 0) ttlMs = ms
    }

    /** R-P0：调度侧（scheduleTtl）读取的生效 TTL——注入后与 reason 串同源，
     *  禁双源（首版缺陷：调度侧直读 DEFAULT_TTL_MS 致注入后仍按 5min 计时）。 */
    val effectiveTtlMs: Long get() = ttlMs

    companion object {
        /** §4.1 Inactivity TTL 3~5min，取上界 5min（后台续航优先于重载开销）。 */
        const val DEFAULT_TTL_MS = 5 * 60 * 1000L

        /** R-P0 驻留策略位：initEngine Bundle 键（on-device-residency S-R0-a）。 */
        const val KEY_RESIDENCY_TTL_MS = "residencyTtlMs"

        /** P1 用户面驻留策略档位键（值 = [com.zzh.goodhub.engine.ResidencyPolicy.Strategy] 名，缺失 = smart）。 */
        const val KEY_RESIDENCY_STRATEGY = "residencyStrategy"
    }

    enum class State { COLD_EVICTED, WARM_STANDBY, ACTIVE }

    @Volatile
    var state: State = State.COLD_EVICTED
        private set

    /** 代次：驱逐/重入计数，作废过期 TTL 定时器的判据。 */
    @Volatile
    private var generation = 0

    /**
     * 代次对外只读面（M1 Expand）：会话票据 `seq` 取此值——主进程据此判别
     * 「票据是否属于当前会话」（配合 `:engine` 进程实例标识使用）。
     */
    val currentGeneration: Int
        get() = generation

    /**
     * TTL 到点回调（由接线方定时器驱动）。返回 true = 本次确实执行了驱逐
     * （接线方可据此记日志/上报）；false = 代次失配或非待命态，静默作废。
     */
    @Synchronized
    fun onTtlElapsed(generationAtSchedule: Int): Boolean {
        if (isBusy()) return false // 受理窗口 / 在途护栏：不驱逐（见 isBusy 文档）
        if (state != State.WARM_STANDBY) return false
        if (generationAtSchedule != generation) return false // 过期定时器作废
        evict("ttl-elapsed(${ttlMs}ms)")
        return true
    }

    /** 生成开始：WARM_STANDBY → ACTIVE（挂起 TTL 计时由接线方取消定时器承载）。 */
    @Synchronized
    fun onGenerateStart() {
        if (state == State.COLD_EVICTED) return // 未装载即生成：状态机不背书
        state = State.ACTIVE
    }

    /** 生成结束：ACTIVE → WARM_STANDBY，重置 TTL 基准；返回新代次供定时器。 */
    @Synchronized
    fun onGenerateFinished(): Int {
        if (state == State.COLD_EVICTED) return generation
        state = State.WARM_STANDBY
        return generation
    }

    /** loadModel 受理（COLD → WARM 档重入）：代次 +1，新会话新计时基准。 */
    @Synchronized
    fun onWarmup(): Int {
        generation += 1
        state = State.WARM_STANDBY
        return generation
    }

    /**
     * onTrimMemory 驱动（§4.1）：RUNNING_CRITICAL / BACKGROUND 及以上立即
     * 驱逐。返回 true = 触发了驱逐。
     */
    @Synchronized
    fun onTrimMemory(level: Int): Boolean {
        val evicting = level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND ||
            level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL
        if (!evicting) return false
        if (state == State.COLD_EVICTED) return false
        evict("trim-memory(level=$level)")
        return true
    }

    /**
     * 内存预算护栏（§4.1「逼近 LMK 阈值即使 TTL 内也提前降级」）：[rssBytes]
     * ≥ [guardBytes] 时驱逐。返回 true = 触发了驱逐。
     */
    @Synchronized
    fun onMemoryPressure(rssBytes: Long, guardBytes: Long): Boolean {
        if (rssBytes < guardBytes) return false
        if (state == State.COLD_EVICTED) return false
        evict("memory-guard(rss=${rssBytes / 1048576}MB ≥ ${guardBytes / 1048576}MB)")
        return true
    }

    /**
     * 护栏击穿驱逐（S3 内存面换线）：指标选型与阈值归 [com.zzh.goodhub.engine.MemoryGuardEvaluator]
     * 与接线方（availMem 基线增量 + 绝对地板，GenieX 路线下 ION/DSP 不计入
     * 进程 RSS），状态机只认「护栏判定已击穿」这一事实。返回 true = 触发了驱逐。
     */
    @Synchronized
    fun onGuardBreached(reason: String): Boolean {
        if (state == State.COLD_EVICTED) return false
        evict(reason)
        return true
    }

    /**
     * 主动 release（S3-4 终止下沉：AIDL releaseEngine = §4.1 cancel 中止 +
     * 析构进 COLD-EVICTED）。经状态机单源驱动：state 失真修正（此前
     * releaseEngine 直接 close 绕过状态机，state 停在中途态、generation 不增，
     * 旧 TTL 定时器不作废）+ 与 TTL/护栏驱逐同一条 onEvict 释放路径。
     * COLD 态幂等（不重复回调）。返回 true = 本次执行了释放。
     */
    @Synchronized
    fun onRelease(): Boolean {
        if (state == State.COLD_EVICTED) return false
        evict("release")
        return true
    }

    private fun evict(reason: String) {
        state = State.COLD_EVICTED
        generation += 1
        onEvict(reason)
    }
}
