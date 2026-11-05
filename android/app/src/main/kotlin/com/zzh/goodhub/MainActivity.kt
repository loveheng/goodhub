package com.zzh.goodhub

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 端侧 LLM 桥（M2 自 goodshare 随迁）：isAvailable/unavailableReason/
        // generate/socModel 四方法，协议与 Dart 侧 lib/llm/llm.dart 对齐
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "goodhub/llm",
        ).let { LlmBridge.register(it, this) }
        // 本地插件 Binder 传输桥（T-trans-2）：goodhub/binder_mcp + goodhub/binder_mcp_events
        BinderTransportBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        // 网关前台保活服务桥（G4）：goodhub/gateway_service
        GatewayServiceBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        // 网关 L2 醒目呼叫通道（TC12）：goodhub/gateway_consent
        GatewayConsentBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        // 端侧引擎绑定桥（on-device S1-1）：goodhub/on_device_engine
        EngineServiceBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        // GenieX 增配安装面通道（npu-geniex-runtime P2，设计稿 §7）
        GenieXBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    // AI 调试直达（仅 debug/profile Manifest 声明 goodhub://debug 入口）：
    // 冷启动把 VIEW intent 翻成 initialRoute；singleTop 热启动走 onNewIntent
    // 经 NavigationChannel.pushRoute 推给 Dart（Navigator.pushNamed）。
    // release 无该 intent-filter，且 Dart 侧 onGenerateRoute 以 !kReleaseMode
    // 装配，路由面不进生产。
    // super 的可空返回（无 route extra 时）须显式落到默认首页路由。
    override fun getInitialRoute(): String =
        debugRoute(intent) ?: super.getInitialRoute() ?: "/"

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val route = debugRoute(intent) ?: return
        flutterEngine?.navigationChannel?.pushRoute(route)
    }

    private fun debugRoute(source: Intent?): String? {
        val data = source?.data ?: return null
        if (data.scheme != "goodhub" || data.host != "debug") return null
        val page = data.path?.trim('/')?.takeIf { it.isNotEmpty() } ?: return null
        return "/debug/$page"
    }
}
