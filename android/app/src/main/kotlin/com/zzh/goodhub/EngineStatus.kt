package com.zzh.goodhub

/// EngineStatus 结构化状态（on-device-capability.md §2 v2.5）。
/// 序数与 Dart 侧 lib/llm/on_device_engine.dart 的 EngineStatus 严格对齐，
/// AIDL checkStatus/initEngine 以 int 序数传输——调整顺序必须双端同轮。
enum class EngineStatus {
    ready,              // 就绪可用
    busy,               // 执行中，支持协作式打断（非抢占式）/ 策略 B 驳回
    assetMissing,       // 资产缺失（M4 起回归终态语义：真·未导入/校验不过）
    insufficientMemory, // 当前可用 RAM 低于门禁
    circuitBroken,      // 处于熔断保护期
    unsupportedDevice,  // 硬件 / 芯片架构不匹配（D1 中低端）
    thermalCutoff,      // 热降级切云期（≥SEVERE；环境降级可自愈，温度回落即恢复）
    loading,            // M4 追加（受理态，P2-14 销账）：模型装载中（创建线程在建会话）
    // 追加（Fix1 恢复语义去歧义）：本进程拒绝同进程重载（单进程单装载纪律）
    // → 进程将自杀交 AMS 冷启动新进程装载。**可重试中断，非终态**——与
    // assetMissing（真·未导入/校验不过）严格分开：此前复用 assetMissing 把
    // 「空闲回收后重载」报成「请重新导入模型」（补救方向误导），且主进程侧
    // 按终态判死不再重试 → 端侧事实上永久失效。双端序数严格对齐（Dart 侧
    // lib/llm/on_device_engine.dart 末尾同步追加）。
    reloading,
    // 追加（F2，2026-10-31 ADR）：未知序数收容态——跨端漂移/未知状态非终态，
    // 主进程折算为「未知需对账」驱动票据原子刷新（I2 未知≠终态），严禁再
    // 投毒进 unsupportedDevice 终态。双端序数严格对齐（Dart 侧末尾同步追加）。
    unknownNeedReconcile,
}
