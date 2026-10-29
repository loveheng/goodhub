package com.zzh.goodhub.engine

/**
 * 端侧引擎热调度状态机（on-device S3-1，NPU 稿 §5.2/§5.3）。
 *
 * 纯逻辑件（无 Android 依赖，JVM 单测覆盖）；输入为 PowerManager
 * OnThermalStatusChangedListener 的 thermal status 整数（PowerManager
 * THERMAL_STATUS_* 常量值，接线方直传），切云决策经 [onCutoffChanged] 回调
 * 由接线方承载（:engine abort 在途生成 + 通知主进程闸门），状态机只管
 * 状态与触发规则，不直接触碰资源。
 *
 * 热档位 → 调度模式映射（§5.2 四模式；禁 CPU 分流，§5.2 决策行）：
 *  - NONE / LIGHT → [Mode.BALANCED]（默认档：NPU OPP 由资产 htp config
 *    perf_profile=sustained_high_performance 承载，Balanced「稳定在热封顶线
 *    下不降频」语义已被该档覆盖）；
 *  - MODERATE → [Mode.POWERSAVE]（§5.2「降 NPU OPP、插入采样间隔」）——
 *    geniex-android 管线无 per-stage/OPP 运行时 API（S3 换线拍板实证，
 *    devlog 2026-10-29），本档为预留钩子仅留痕，SDK 暴露 API 后接入；
 *  - SEVERE / CRITICAL / EMERGENCY / SHUTDOWN → [Mode.THERMAL_CUTOFF]：
 *    全量切云端（§5.2 Thermal→Cloud 行），严禁 NPU↔CPU 层切分（CPU 能效差
 *    5~10×，分流加剧发热）。
 *
 * 非热触发档（§5.2 其余两行）不在本状态机射程：Performance（前台短请求）由
 * perf_profile 档位承载、Duty-cycle（常驻轻量检测）P1 无对应触发源——均
 * 不随热状态迁移，如实记录。
 *
 * 迟滞带：进入切云沿 = status ≥ [CUTOFF_ENTER_MIN]（SEVERE）；退出沿 =
 * status ≤ [CUTOFF_EXIT_MAX]（MODERATE）——MODERATE 带属 Powersave 档继续
 * 端侧，进入/退出阈值错开构成滞回，防热状态在阈值附近抖动反复横跳。
 */
class EngineThermal(
    /** 切云沿回调（仅在状态翻转时触发）：active=true 进入切云 / false 恢复。 */
    private val onCutoffChanged: (active: Boolean, status: Int) -> Unit,
) {
    companion object {
        // PowerManager.THERMAL_STATUS_* 常量值镜像（API 29+；int 直传保持
        // 纯逻辑件零 Android 依赖，接线方以系统常量调用）。
        const val STATUS_NONE = 0
        const val STATUS_LIGHT = 1
        const val STATUS_MODERATE = 2
        const val STATUS_SEVERE = 3
        const val STATUS_CRITICAL = 4
        const val STATUS_EMERGENCY = 5
        const val STATUS_SHUTDOWN = 6

        // 实际 Android 常量序：NONE(0) LIGHT(1) MODERATE(2) SEVERE(3)
        // CRITICAL(4) EMERGENCY(5) SHUTDOWN(6)——进入切云沿 = SEVERE 起。
        const val CUTOFF_ENTER_MIN = STATUS_SEVERE

        /// 退出切云沿 = 降到 MODERATE 及以下（MODERATE 带 = Powersave 续跑端侧）。
        const val CUTOFF_EXIT_MAX = STATUS_MODERATE
    }

    enum class Mode { BALANCED, POWERSAVE, THERMAL_CUTOFF }

    @Volatile
    var mode: Mode = Mode.BALANCED
        private set

    /** 切云闸当前态（initEngine 时经 AIDL 回报主进程，覆盖绑定晚于升温的时序）。 */
    @Volatile
    var cutoffActive: Boolean = false
        private set

    /** 最近一次上报的热状态（观测面：日志/诊断）。 */
    @Volatile
    var lastStatus: Int = STATUS_NONE
        private set

    /**
     * 热状态上报（PowerManager listener 直通）。返回 true = 本次触发了切云
     * 状态翻转（接线方可据此 abort/记日志）。
     */
    @Synchronized
    fun onThermalStatus(status: Int): Boolean {
        lastStatus = status
        mode = when {
            status >= CUTOFF_ENTER_MIN -> Mode.THERMAL_CUTOFF
            status >= STATUS_MODERATE -> Mode.POWERSAVE
            else -> Mode.BALANCED
        }
        val cutoff = status >= CUTOFF_ENTER_MIN
        val changed = cutoff != cutoffActive
        cutoffActive = cutoff
        if (changed) onCutoffChanged(cutoff, status)
        return changed
    }
}
