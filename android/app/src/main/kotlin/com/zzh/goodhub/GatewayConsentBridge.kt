package com.zzh.goodhub

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/// 网关 L2 醒目呼叫通道（TC12）：Dart 侧 [NativeConsentDelegate] 经
/// `goodhub/gateway_consent` 调 `requestConsent` → 原生发高优先级全屏通知
/// （FULL_SCREEN_INTENT）拉起 [L2AlertActivity]；用户决定后经 [resolve] 完成 Dart Future。
///
/// 每个请求分配独立 reqId，支持 PC 并发 L2（背压 max 4）互不串扰。
object GatewayConsentBridge {

    const val CHANNEL = "goodhub/gateway_consent"
    const val EXTRA_REQ_ID = "req_id"
    const val EXTRA_TOOL = "tool"
    const val EXTRA_ARGS = "args"
    private const val TAG = "GatewayConsent"
    private const val CHANNEL_ID = "goodhub_consent"

    private lateinit var activity: Activity
    private val pending = ConcurrentHashMap<Int, MethodChannel.Result>()
    private val counter = AtomicInteger(1)

    fun register(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestConsent" -> {
                    val tool = call.argument<String>("toolName") ?: ""
                    val args = call.argument<String>("argumentsJson") ?: "{}"
                    val id = counter.incrementAndGet()
                    pending[id] = result
                    postConsentNotification(id, tool, args)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 由 [L2AlertActivity] 调用：完成某个待决请求的 Dart Future（回传 GateDecision 映射）。
    fun resolve(reqId: Int, approved: Boolean, remember: Boolean, reason: String?) {
        val r = pending.remove(reqId) ?: return
        try {
            r.success(
                mapOf(
                    "approved" to approved,
                    "rememberSession" to remember,
                    "reason" to reason,
                ),
            )
        } catch (e: Throwable) {
            Log.w(TAG, "resolve failed: $e")
        }
    }

    private fun postConsentNotification(id: Int, tool: String, args: String) {
        val nm = activity.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "PC 远程确认", NotificationManager.IMPORTANCE_HIGH),
            )
        }
        val intent = Intent(activity, L2AlertActivity::class.java).apply {
            putExtra(EXTRA_REQ_ID, id)
            putExtra(EXTRA_TOOL, tool)
            putExtra(EXTRA_ARGS, args)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pi = PendingIntent.getActivity(
            activity,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val notification = Notification.Builder(activity, CHANNEL_ID)
            .setSmallIcon(activity.applicationInfo.icon)
            .setContentTitle("PC 远程调用确认（L2 写操作）")
            .setContentText("工具：$tool —— 请在手机上确认")
            .setPriority(Notification.PRIORITY_MAX)
            .setCategory(Notification.CATEGORY_CALL)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .build()
        nm.notify(id, notification)
    }
}
