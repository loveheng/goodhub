package com.zzh.goodhub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/// PC 远程网关前台保活服务（G4，thirdconnect.md §7）：
/// ForegroundService（通知栏常驻）+ WifiLock（HIGH_PERF）+ WakeLock（PARTIAL），
/// 避免息屏/Doze 断连 PC 的 Streamable HTTP 会话。
///
/// - `foregroundServiceType="connectedDevice"`（minSdk 34 强制类型化），前置权限
///   以 `CHANGE_WIFI_STATE` 满足（Android 14 对该类型的最低 precondition 之一）；
/// - 锁不可重入计数（setReferenceCounted(false)），onDestroy 统一释放；
/// - startForegroundService 必须在 5s 内 startForeground——onStartCommand 即调；
/// - 起服失败（OEM 限制/权限缺失）捕获降级：网关仍可用（仅前台时），禁崩宿主。
class GatewayForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            createChannel() // Android 8+ 必须先建通道，否则 startForeground 抛 IllegalArgumentException 崩宿主
            startForeground(NOTIFICATION_ID, buildNotification())
            acquireLocks()
        } catch (e: Exception) {
            Log.e(TAG, "[DEGRADE] gateway fgs: startForeground failed: $e")
            stopSelf()
        }
        return START_STICKY
    }

    @Suppress("DEPRECATION") // WIFI_MODE_FULL_HIGH_PERF（34 起标记弃用，仍为稳态高性能口径）
    private fun acquireLocks() {
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "goodhub:gateway").apply {
            setReferenceCounted(false)
            acquire()
        }
        val wm = applicationContext.getSystemService(WifiManager::class.java)
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "goodhub:gateway").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
        super.onDestroy()
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "PC 远程网关",
            NotificationManager.IMPORTANCE_LOW, // 常驻保活不打扰
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val tapIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("GoodHub 网关运行中")
            .setContentText("PC 可经 http://<手机IP>:8766/mcp 访问")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(tapIntent)
            .build()
    }

    companion object {
        private const val TAG = "GatewayForeground"
        private const val CHANNEL_ID = "goodhub_gateway"
        private const val NOTIFICATION_ID = 0x8766

        fun start(context: Context) {
            try {
                context.startForegroundService(
                    Intent(context, GatewayForegroundService::class.java),
                )
            } catch (e: Exception) {
                Log.e(TAG, "[DEGRADE] gateway fgs: start failed: $e")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, GatewayForegroundService::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "[DEGRADE] gateway fgs: stop failed: $e")
            }
        }
    }
}
