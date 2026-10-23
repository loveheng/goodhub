package com.zzh.goodhub

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/// 前台保活服务通道桥（G4）：goodhub/gateway_service——start/stop 两方法，
/// Dart 侧 GatewayServiceChannel 对接（GatewayController 起停服时联动）。
/// 顺带补 POST_NOTIFICATIONS 运行时授权请求（Android 13+ 通知可见性；未授权
/// 仅通知不显示，服务照常运行，不阻断）。
object GatewayServiceBridge {
    private const val CHANNEL = "goodhub/gateway_service"
    private const val NOTIFY_PERM_REQUEST = 0x8766
    private const val TAG = "GatewayServiceBridge"

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ensureNotificationPermission(activity)
                    GatewayForegroundService.start(activity)
                    result.success(null)
                }
                "stop" -> {
                    GatewayForegroundService.stop(activity)
                    result.success(null)
                }
                // 电池优化白名单（G4 遗留项收口，2026-10-23）：未加白名单时
                // 息屏进 Doze 会限网 → PC 侧表现为「过段时间连接掉了」。
                "batteryExemptionStatus" -> {
                    result.success(isIgnoringBatteryOptimizations(activity))
                }
                "requestBatteryExemption" -> {
                    if (isIgnoringBatteryOptimizations(activity)) {
                        result.success(true)
                    } else {
                        requestExemption(activity)
                        // 未当场生效——需用户在系统弹窗确认；状态以下次查询为准。
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 是否已在电池优化白名单（需 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 权限）。
    private fun isIgnoringBatteryOptimizations(activity: Activity): Boolean {
        val pm = activity.getSystemService(PowerManager::class.java)
        return pm.isIgnoringBatteryOptimizations(activity.packageName)
    }

    /// 跳系统申请页：优先「直接申请本应用」弹窗；部分 ROM 抛异常 → 退到
    /// 白名单列表页（用户手动选）。两路都失败才上抛。
    private fun requestExemption(activity: Activity) {
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${activity.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return
        } catch (e: Exception) {
            Log.w(TAG, "battery exemption request dialog unavailable: $e")
        }
        try {
            activity.startActivity(
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: Exception) {
            Log.e(TAG, "[DEGRADE] gateway battery exemption: $e")
        }
    }

    private fun ensureNotificationPermission(activity: Activity) {
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            activity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFY_PERM_REQUEST,
            )
        }
    }
}
