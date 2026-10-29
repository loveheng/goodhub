package com.zzh.goodhub;

// 端侧引擎事件回调（on-device-capability.md §2：EngineDied 回调经 onEngineDied()
// 由 :engine 侧主动通知）。oneway：:engine 侧单向广播，不阻塞推理线程。
oneway interface IOnDeviceEngineListener {
    // :engine 侧主动上报进程内致命事件（NPU 驱动 Panic / 算子越界 abort 等）；
    // 外部处决（OEM SIGKILL / LMK）不会触发本回调——由主进程侧
    // ServiceConnection.onServiceDisconnected 捕获，两路最终同归切云路径。
    void onEngineDied();

    // S3-6（NPU 稿 §6.3）：RingBuffer 写超时判定消费端死锁（IPC_DEADLOCK）——
    // :engine 已主动中断本次生成并清空在途；主进程按 EngineDiedException
    // 切云（不计熔断口径：消费端失速属环境事件非本端 Bug，仅冷却窗口）。
    void onIpcDeadlock();

    // 生成收尾：finishReason 0=stop / 1=cancelled（§6.3 cancel 清在途后收尾）。
    void onGenerateFinished(String requestId, int finishReason);

    // S3-1 热调度（NPU 稿 §5.2/§5.3）：切云沿回调——active=true = 热状态达
    // SEVERE 及以上（Thermal→Cloud 全量切云，禁 CPU 分流；:engine 侧已同步
    // abort 在途生成）；active=false = 热状态回落 MODERATE 及以下（端侧恢复）。
    // 初态对齐：initEngine 时立即回报当前态（覆盖绑定晚于升温的时序）。
    void onThermalCutover(boolean active);
}

