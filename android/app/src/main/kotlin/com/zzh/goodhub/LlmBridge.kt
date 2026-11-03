package com.zzh.goodhub

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * 设备环境探针桥（channel: goodhub/llm，2026-11-03 退役瘦身）。
 *
 * **历史**：本桥原为 M2 随迁的端侧 LLM 生成通道（八方法：generate/warmup/
 * isAvailable/...，内嵌 `maxCtxFor` 按模型名前缀写死窗口 + SamplerConfig
 * 硬编码采样——模型绑定写死参数）。生成职责已由 `:engine` 独立进程
 * （GenieSession/LiteRtLmRunner + AIDL 票据面）整体接替：Dart 侧无任何
 * generateStream 调用方、`llm_selected_model` 偏好键无人写、`llmModels`
 * 内置目录零消费——生成面判死退役（含全部模型绑定写死参数）。
 *
 * **现役面**（活消费方，禁删）：
 * - `deviceProbe`：门禁数据源（准入探针 on_device_admission_probe /
 *   装载 MemGate on_device_engine_aidl / DeviceTierGate hybrid_assembly）；
 * - `socModel`：NPU 专包可见性判定（llm.dart llmModelVisibleOnDevice）。
 *
 * 其余方法一律 `notImplemented()`（Dart 侧 ChannelLlmEngine 对应调用落
 * MissingPluginException → Unavailable 语义，与「引擎不可用」消费口径一致）。
 */
object LlmBridge {
    private const val TAG = "LlmBridge"

    fun register(channel: MethodChannel, activity: Context) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceProbe" -> result.success(deviceProbe(activity))
                "socModel" -> result.success(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null
                )
                else -> result.notImplemented()
            }
        }
        Log.i(TAG, "registered (probe-only; generate face retired 2026-11-03)")
    }

    /// 设备环境探针（§16 门禁数据源）：RAM/电量/充电/省电/温控一次取齐。
    /// 未知语义（Dart 侧 DeviceTierGate 消费）：batteryPct=-1 未知；
    /// thermalStatus=-1 = API < 29 无公开温控 API，按放行处理（RAM 硬门槛兜底）。
    private fun deviceProbe(activity: Context): Map<String, Any> {
        val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val bm = activity.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val rawCapacity = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val batteryPct = if (rawCapacity <= 0) -1 else rawCapacity
        // 粘性广播查询（receiver=null）：系统保护广播，无需注册监听器
        val intent = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL || plugged > 0
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "totalRamBytes" to mem.totalMem,
            "availRamBytes" to mem.availMem,
            "lowMemory" to mem.lowMemory,
            "batteryPct" to batteryPct,
            "isCharging" to isCharging,
            "isPowerSave" to pm.isPowerSaveMode,
            "thermalStatus" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                pm.currentThermalStatus else -1,
        )
    }
}
