package com.zzh.goodhub

/// 端侧引擎执行槽占用驳回（on-device S3-3，NPU 稿 §6.6 策略 B / 总纲 §2 v2.6）。
///
/// 单执行槽被占且本次请求不可授予（后台忙驳回 / 前台抢占等待超时兜底）时
/// 由 `:engine` 抛出，调用方（混合引擎）捕获即无缝切云——不维护堆积队列。
///
/// **跨进程识别约束**：AIDL Binder 对 RuntimeException 只保真 message 不保真
/// 类型，故 message 固定 [MESSAGE_PREFIX] 前缀供主进程 Bridge 机器判别（禁
/// 依赖 `is ServiceBusyException`）。
class ServiceBusyException(message: String) : IllegalStateException(message) {
    companion object {
        const val MESSAGE_PREFIX = "service_busy"
    }
}
