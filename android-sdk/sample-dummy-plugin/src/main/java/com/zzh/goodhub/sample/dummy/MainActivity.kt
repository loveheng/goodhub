package com.zzh.goodhub.sample.dummy

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

/**
 * 极简启动页：仅用于让靶子 APK 可安装、可在桌面点击确认存活（插件本身靠 bindService 唤起）。
 */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(
            TextView(this).apply {
                text = "Dummy MCP Plugin\nSERVER_ID=dummy\n提供工具: echo / add"
                textSize = 16f
                setPadding(32, 32, 32, 32)
            }
        )
    }
}
