package com.zzh.goodhub

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/// 应用设置直达桥（ux-hardening P0-3 收尾）：更新页安装失败时引导用户去
/// 「安装未知应用」授权页。零状态、零权限声明（仅拉起系统设置页）。
object AppSettingsBridge {
    private const val CHANNEL = "goodhub/app_settings"

    fun register(messenger: BinaryMessenger, activity: MainActivity) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openUnknownAppSources" -> {
                    val i = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        // Android 8+：直达本包的「安装未知应用」授权页
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}"),
                        )
                    } else {
                        // <8：退化为应用详情页（无独立授权页可直达）
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${activity.packageName}"),
                        )
                    }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(i)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
