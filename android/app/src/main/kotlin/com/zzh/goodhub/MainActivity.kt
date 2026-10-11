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
    }
}
