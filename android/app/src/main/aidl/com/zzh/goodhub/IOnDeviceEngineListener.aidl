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

    // `:engine` 侧**自发**状态变更（与请求无关的驱逐/释放）统一上行：
    //   - TTL 空闲驱逐（scheduleTtl → onTtlElapsed）
    //   - onTrimMemory 驱逐（RUNNING_CRITICAL / BACKGROUND 及以上）
    //   - 内存预算护栏驱逐（checkMemoryGuard → onGuardBreached）
    //   - 主动 release（AIDL releaseEngine → lifecycle.onRelease）
    // reason 取值见 EngineLifecycle.evict 的调用点
    // （"ttl-elapsed(...)"/"trim-memory(level=...)"/"memory-guard(...)"/"release"）。
    //
    // **存在理由（P0-3）**：双端状态机此前只有 Dart→Kotlin 单向通道，
    // :engine 自发驱逐后主进程 `loadState` 仍为 ready（说谎）→ `enable()` 判
    // ready 而 no-op 不重装 → 下一次端侧请求必撞 `genie session not
    // ready` / `data plane not initialized`，且错误文案呈现 `assetMissing`
    // （立法语义=模型未下载）→ 补救方向被误导为「重新下载模型」。
    // 主进程据此复位 loadState + 清数据面 handle，令下一次 enable 走
    // 「快速暖机」再入（资产在盘不重下载）。
    //
    // 契约细化（M2 §2.8 I6）：evictingRequestId 非空 = 本次驱逐**打断了在途
    // 生成**（onTrimMemory/护栏/release 四路径 ACTIVE 态照常驱逐——内存水位
    // 优先于本轮产出）；主进程对被中断的流以 SESSION_ABORTED_BY_EVICTION
    // 语义收口（可重试/切云），区别于进程死亡的 EngineDied——不再靠数据面
    // EOF 间接收口（丢归因、切云决策无从区分）。
    void onEngineEvicted(String reason, String evictingRequestId);
}

