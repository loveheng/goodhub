package com.zzh.goodhub

/// EngineStatus 结构化状态（on-device-capability.md §2 v2.5）。
/// 序数与 Dart 侧 lib/llm/on_device_engine.dart 的 EngineStatus 严格对齐，
/// AIDL checkStatus/initEngine 以 int 序数传输——调整顺序必须双端同轮。
enum class EngineStatus {
    ready,              // 就绪可用
    busy,               // 执行中，支持抢占 / 策略 B 驳回
    assetMissing,       // 驱动就绪但模型未下载
    insufficientMemory, // 当前可用 RAM 低于门禁
    circuitBroken,      // 处于熔断保护期
    unsupportedDevice,  // 硬件 / 芯片架构不匹配（D1 中低端）
    thermalCutoff,      // 热降级切云期（≥SEVERE；环境降级可自愈，温度回落即恢复）
}
