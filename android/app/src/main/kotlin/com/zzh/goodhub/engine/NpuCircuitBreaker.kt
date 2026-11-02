package com.zzh.goodhub.engine

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log

/**
 * NPU 持久化熔断器（P0：坏机型反复进 NPU 卡死防御）。
 *
 * 作用域边界（与既有降级体系对齐）：
 * - 本类**只覆盖「NPU init API 返回失败（非崩溃）」**这一轻量可观测分支：QNN
 *   运行库已装但 init 抛错（DSP 权限锁 / 驱动握手失败 / 代际不兼容）→ 落盘标记，
 *   后续同机跳过 NPU 重探（省去每次 2s 级沉重 init），降级走 GPU/云端。
 * - **不覆盖 native 崩溃分支**：`:engine` 因 DSP SIGSEGV / FastRPC 超时致死，由
 *   [EngineServiceBridge.onServiceDisconnected] → `onProcessDied` → Dart 侧熔断器
 *   （§6.5 v2.6 收窄口径：外部处决不计 NPU 熔断，仅冷却窗口）收口——本类
 *   绝不跨进程代 trip，避免把「低内存 LMK 杀死」误记为设备 NPU 缺陷。
 *
 * 粒度 = `per (family, arch, soc)`：GenieX 系 `geniex` 与 LiteRT-LM 系 `litertlm`
 * 各自独立熔断，互不污染；`arch` 取自 [GenieXRuntime.hexagonArch]、`soc` 取自
 * `Build.SOC_MODEL`。
 *
 * 自愈（2026-11-02 复合键）：重置键 = `fingerprint|versionCode`——系统 OTA
 * （[Build.FINGERPRINT] 变更）**或** App 版本号变更（新包带新 QNN 运行库 /
 * 模型配置，可修复此前的「代际不兼容」类失败；单 FINGERPRINT 会让历史坏机
 * 用户的 NPU 封死到系统大版本更新）任一即清空全部标记重新允许探测。升级
 * 首跑旧单键值与复合键必然失配 → 自然自愈清理（每机一次重探，代价 = 一次
 * 2s 级 init）。
 *
 * 落盘 = SharedPreferences（同 UID 跨 `:engine` / 主进程可见；写入低频，用 commit
 * 确保落盘，进程崩溃重启后仍可读到历史熔断）。
 */
object NpuCircuitBreaker {
    private const val PREF_NAME = "npu_circuit_breaker"
    private const val KEY_PREFIX = "breaker_"
    private const val KEY_RESET = "last_reset_key"
    private const val TAG = "NpuCircuitBreaker"

    fun isTripped(context: Context, family: String, arch: Int, soc: String): Boolean =
        isTripped(context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE),
            resetKey(context), family, arch, soc)

    @Synchronized
    internal fun isTripped(
        sp: SharedPreferences, resetKey: String, family: String, arch: Int, soc: String
    ): Boolean {
        val saved = sp.getString(KEY_RESET, null)
        // 系统 OTA 或 App 版本变更 → 清空所有熔断标记（旧 breaker key 一并
        // 清掉），允许重新探测；写入新键后后续判定走正常分支。
        if (saved != resetKey) {
            sp.edit().clear().putString(KEY_RESET, resetKey).commit()
            return false
        }
        return sp.getBoolean(buildKey(family, arch, soc), false)
    }

    fun trip(context: Context, family: String, arch: Int, soc: String, reason: String) {
        trip(context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE),
            resetKey(context), family, arch, soc, reason)
    }

    @Synchronized
    internal fun trip(
        sp: SharedPreferences, resetKey: String, family: String, arch: Int, soc: String,
        reason: String
    ) {
        val key = buildKey(family, arch, soc)
        sp.edit()
            .putString(KEY_RESET, resetKey)
            .putBoolean(key, true)
            .putString("${key}_reason", reason)
            .putLong("${key}_ts", System.currentTimeMillis())
            .commit()
        Log.w(TAG, "NPU circuit tripped: key=$key reason=$reason")
    }

    /** 读取熔断原因（诊断留痕；未熔断返回 null）。 */
    fun trippedReason(context: Context, family: String, arch: Int, soc: String): String? =
        trippedReason(context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE),
            family, arch, soc)

    @Synchronized
    internal fun trippedReason(sp: SharedPreferences, family: String, arch: Int, soc: String): String? =
        sp.getString("${buildKey(family, arch, soc)}_reason", null)

    fun reset(context: Context) {
        reset(context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE))
    }

    @Synchronized
    internal fun reset(sp: SharedPreferences) {
        sp.edit().clear().commit()
    }

    /**
     * 重置键 = 系统指纹 + App 版本号复合（两者任一变更即重置，2026-11-02）。
     * 版本号读取失败落 -1（失配 → 干净重探，安全方向）。
     */
    private fun resetKey(context: Context): String {
        val versionCode = try {
            val pi = context.packageManager.getPackageInfo(context.packageName, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pi.longVersionCode
            } else {
                pi.versionCode.toLong()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "[DEGRADE] versionCode unavailable, fallback -1: $e")
            -1L
        }
        return "${Build.FINGERPRINT}|$versionCode"
    }

    private fun buildKey(family: String, arch: Int, soc: String): String =
        "$KEY_PREFIX${family}_${arch}_${soc.trim().lowercase()}"
}
