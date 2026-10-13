package com.zzh.goodhub

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/// 前台保活服务通道桥（G4）：goodhub/gateway_service——start/stop 两方法，
/// Dart 侧 GatewayServiceChannel 对接（GatewayController 起停服时联动）。
/// 顺带补 POST_NOTIFICATIONS 运行时授权请求（Android 13+ 通知可见性；未授权
/// 仅通知不显示，服务照常运行，不阻断）。
object GatewayServiceBridge {
    private const val CHANNEL = "goodhub/gateway_service"
    private const val NOTIFY_PERM_REQUEST = 0x8766

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
                else -> result.notImplemented()
            }
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
