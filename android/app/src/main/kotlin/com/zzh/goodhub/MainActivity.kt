package com.zzh.goodhub

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
    }
}
