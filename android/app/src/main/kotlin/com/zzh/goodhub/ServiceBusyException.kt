package com.zzh.goodhub

/// 端侧引擎执行槽占用驳回（on-device S3-3，NPU 稿 §6.6 策略 B / 总纲 §2 v2.6；
/// 打断术语于 task-capability S14e 订正）。
///
/// 单执行槽被占且本次请求不可授予（后台忙驳回 / 前台**协作式打断**等待窗口
/// 耗尽）时由 `:engine` 抛出，调用方（混合引擎）捕获即无缝切云——不维护堆积
/// 队列。
///
/// **S14e 语义**：打断是协作式不是抢占式——等待窗口耗尽只说明**打断未生效**
/// （在途生成可能仍在跑、算力仍被占），上层不得假设算力已腾出；处置按策略性
/// 降级（切云），**不得以重启引擎进程的方式强行腾出算力**（重启即冷装载）。
/// 打断未生效的子情形以 message 内 `interrupt_not_effective` 标记区分（主进程
/// Bridge 原样透传 message，机器判别用）。
///
/// **跨进程识别约束**：AIDL Binder 对 RuntimeException 只保真 message 不保真
/// 类型，故 message 固定 [MESSAGE_PREFIX] 前缀供主进程 Bridge 机器判别（禁
/// 依赖 `is ServiceBusyException`）。
class ServiceBusyException(message: String) : IllegalStateException(message) {
    companion object {
        const val MESSAGE_PREFIX = "service_busy"

        /// 协作式打断等待窗口耗尽（打断未生效）的消息标记（S14e）——上层据此
        /// 区分「槽忙驳回」与「打断未生效」两种子情形。
        const val INTERRUPT_NOT_EFFECTIVE_MARK = "interrupt_not_effective"
    }
}
