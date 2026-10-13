package com.zzh.goodhub

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.CountDownTimer
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.view.WindowManager
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/// TC12 L2 醒目呼叫：专用全屏 Activity——PC 触发 L2 写操作时由网关经全屏通知
/// （FULL_SCREEN_INTENT）拉起，息屏也能亮屏置顶，弹醒目确认卡；45s 显式确认时限，
/// 超时未点即主动回拒绝（与 gateway_security 的 Future.timeout 双保险）。
///
/// 用户决定（批准/拒绝/返回/超时）经 [GatewayConsentBridge.resolve] 回传 Dart 侧
/// [NativeConsentDelegate]，完成其挂起的 [GateDecision] Future。
class L2AlertActivity : Activity() {

    private var reqId = -1
    private var wakeLock: PowerManager.WakeLock? = null
    private var timer: CountDownTimer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        reqId = intent.getIntExtra(GatewayConsentBridge.EXTRA_REQ_ID, -1)
        val toolName = intent.getStringExtra(GatewayConsentBridge.EXTRA_TOOL) ?: ""
        val argsJson = intent.getStringExtra(GatewayConsentBridge.EXTRA_ARGS) ?: "{}"

        wakeScreen()
        vibrate()

        val title = TextView(this).apply {
            text = "PC 远程调用确认（L2 写操作）"
            textSize = 20f
            setPadding(40, 30, 40, 10)
            setTextColor(0xFF000000.toInt())
        }
        val toolView = TextView(this).apply {
            text = "工具：$toolName"
            textSize = 15f
            setPadding(40, 0, 40, 10)
            setTextColor(0xFF222222.toInt())
        }
        val argsView = TextView(this).apply {
            text = argsJson
            textSize = 12f
            setPadding(8, 8, 8, 8)
            typeface = Typeface.MONOSPACE
        }
        val scroll = ScrollView(this).apply { addView(argsView) }
        val remember = CheckBox(this).apply {
            text = "本网关会话记住该工具"
            setPadding(40, 0, 40, 0)
        }
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(title)
            addView(toolView)
            addView(scroll)
            addView(remember)
        }

        AlertDialog.Builder(this)
            .setView(container)
            .setCancelable(false)
            .setNegativeButton("拒绝") { _, _ -> finishWith(false, false, "用户拒绝") }
            .setPositiveButton("批准") { _, _ -> finishWith(true, remember.isChecked, null) }
            .show()

        // 45s 倒计时：标题展示剩余秒，归零主动拒绝（TC12）。
        timer = object : CountDownTimer(45000, 1000) {
            override fun onTick(millisUntilFinished: Long) {
                val remain = (millisUntilFinished / 1000).toInt()
                title.text = "PC 远程调用确认（L2 写操作）  剩 ${remain}s"
            }

            override fun onFinish() {
                finishWith(false, false, "确认超时（45s），已主动拒绝（TC12）")
            }
        }.start()
    }

    /// 亮屏置顶（TC12：醒目呼叫）——兼容旧 API 的 WindowManager flag 与新 API 直调。
    private fun wakeScreen() {
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "goodhub:l2",
        ).apply {
            setReferenceCounted(false)
            acquire(60000)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
    }

    private fun vibrate() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(VibratorManager::class.java).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(VIBRATOR_SERVICE) as Vibrator
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createOneShot(400, VibrationEffect.DEFAULT_AMPLITUDE),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(400)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "vibrate failed: $e")
        }
    }

    private fun finishWith(approved: Boolean, remember: Boolean, reason: String?) {
        timer?.cancel()
        GatewayConsentBridge.resolve(reqId, approved, remember, reason)
        releaseWake()
        finish()
    }

    private fun releaseWake() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    /// 安全优先：返回即拒绝（不静默放行）。
    override fun onBackPressed() {
        finishWith(false, false, "用户拒绝（返回）")
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseWake()
    }

    companion object {
        private const val TAG = "L2Alert"
    }
}
