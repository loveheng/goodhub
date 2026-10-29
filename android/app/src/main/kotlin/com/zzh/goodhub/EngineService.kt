package com.zzh.goodhub

import android.app.Service
import android.content.ComponentCallbacks2
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.util.Log

/// 端侧 NPU 引擎独立进程服务（on-device epic S1）。
///
/// 运行于 `:engine` 独立进程（Manifest android:process=":engine"），与主进程经
/// Binder/AIDL 控制面 + Ashmem/eventfd 数据面通信（on-device-npu-deployment.md
/// §6.1/§6.2）：NPU 驱动 Panic 或 OOM 仅使主进程收到 EngineDiedException 切云，
/// 绝不拖垮 Flutter 主进程。
///
/// S1-2：控制面 AIDL 契约 Stub 落地（IOnDeviceEngineService，总纲 §2 方法集）。
/// S2 正式接线：推理后端 = Genie 持久会话（[GenieSession]，替换 S1-5 Mock
/// 生成器）——loadModel 后台建会话，startGenerate 真 HTP 流式生成，cancel 经
/// GenieDialog_signal(ABORT) token 粒度即时中断（§6.3 全合规）。
/// Trim 信号 → 三态生命周期状态机（§4.1）归 S2-4。
class EngineService : Service() {
    companion object {
        private const val TAG = "EngineService"

        // ==== S3-2 FGS 前台预挂（NPU 稿 §6.2 v2.7）====
        private const val FGS_CHANNEL_ID = "engine_generation"
        private const val FGS_NOTIFICATION_ID = 1001

        /// 长生成 FGS 挂载阈值：maxTokens ≥ 256 视为「可能耗时」（§6.2
        /// 「generate() 发起且判定可能耗时时即附着」的判定口径；实测 ~60ms/
        /// token 下 ≈15s+，越过 OEM 冻结 5~10s 观察窗量级——拍板兜底值）。
        /// 判定在主进程 Dart 侧承载（本常量供文档锚定，Kotlin 无条件执行）。
        const val FGS_PROMOTE_MIN_MAX_TOKENS = 256

        // ==== 旧裸 Genie C API 注入面（日志级别/per-stage 策略/config 键
        // 覆写/投递链 DRAIN 档）随 S3 换线退役====：geniex-android 管线无
        // 对应注入 API——日志与调优归 SDK 默认 + 资产 htp config
        // （perf_profile=sustained_high_performance 已实证固化），投递链
        // 成本已经 DRAIN 对照实证为零（devlog 2026-10-29）。
    }

    private var listener: IOnDeviceEngineListener? = null

    /// 数据面（§6.1）：initEngine 时建立，getSharedMemory/getEventFd 下发句柄；
    /// 失败降级为 null（控制面后续调用快速失败，不拖垮绑定）。
    private var dataPlane: com.zzh.goodhub.engine.EngineDataPlane? = null

    /// Genie 正式会话（S2 正式接线）：持久 Dialog 生成后端。
    private val session = GenieSession(this)

    /// S3-3 单执行槽（§6.6）：策略 B 驳回 + 前台抢占的原子判定面。
    private val slot = com.zzh.goodhub.engine.EngineSlot()

    /// S2-4 三态生命周期状态机（§4.1）：驱逐动作 = Genie 会话 + 数据面释放。
    private val lifecycle = com.zzh.goodhub.engine.EngineLifecycle { reason ->
        Log.i(TAG, "lifecycle evict: $reason")
        session.close()
        dataPlane?.close()
        dataPlane = null
    }

    /// TTL 定时器（主线程 Handler；代次失配由状态机作废，防旧计时器杀新会话）。
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /// S3-1 热调度状态机（§5.2/§5.3）：切云沿回调 = abort 在途生成（§6.3
    /// token 粒度即时中断）+ 通知主进程闸门（AIDL onThermalCutover oneway）。
    private val thermal = com.zzh.goodhub.engine.EngineThermal { active, status ->
        if (active) {
            Log.w(TAG, "[DEGRADE] thermal cutoff: SEVERE+ (status=$status) " +
                "→ abort in-flight generation, switch to cloud")
            session.abort()
        } else {
            Log.i(TAG, "thermal recovered: status=$status, on-device path resumed")
        }
        notifyThermalCutover(active)
    }

    /// PowerManager thermal listener（§5.3 公共 API，minSdk 34 ≥ API 29 无
    /// 版本门槛；无 executor 版本回调在主线程）。onCreate 注册/onDestroy 注销。
    private val thermalListener =
        android.os.PowerManager.OnThermalStatusChangedListener { status ->
            thermal.onThermalStatus(status)
        }

    private fun scheduleTtl(generation: Int) {
        mainHandler.removeCallbacksAndMessages(null)
        mainHandler.postDelayed(
            { lifecycle.onTtlElapsed(generation) },
            com.zzh.goodhub.engine.EngineLifecycle.DEFAULT_TTL_MS,
        )
    }

    /// 内存预算护栏（§4.1）：S3 内存面换线（2026-10-29）——真指标 =
    /// availMem 暖机基线增量（ION/DMA-BUF 由内核计入系统可用内存，故增量
    /// ≈ 引擎真实足迹）+ availMem 绝对地板（系统饥饿防护）。旧 RSS/PSS 线
    /// 随 GenieX 路线退役：暖机+生成全程 :engine PSS 稳定 ~103MB，权重常驻
    /// ION/DSP 不计 PSS，2.5GB 线实际不可达（S2-5 真机校准结论）。
    /// 指标选型与阈值归 [MemoryGuardEvaluator]；per-process dmabuf 精确
    /// 记账需 root/debugfs，不可行，弃（不做猜测性降级）。
    private var warmupBaselineAvailMem = 0L

    private fun readAvailMem(): Long =
        (getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager).let { am ->
            android.app.ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }.availMem
        }

    private fun checkMemoryGuard() {
        val reason = com.zzh.goodhub.engine.MemoryGuardEvaluator.evaluate(
            baselineAvailMemBytes = warmupBaselineAvailMem,
            currentAvailMemBytes = readAvailMem(),
        ) ?: return
        lifecycle.onGuardBreached(reason)
    }

    private val stub = object : IOnDeviceEngineService.Stub() {
        override fun initEngine(config: Bundle?, cb: IOnDeviceEngineListener?): Int {
            listener = cb
            // S3-1 初态对齐：绑定可能晚于升温（热状态权威在 :engine），立即
            // 回报当前切云态，主进程闸门不因时序漏开。
            cb?.let { runCatching { it.onThermalCutover(thermal.cutoffActive) } }
            if (dataPlane == null) {
                dataPlane = try {
                    com.zzh.goodhub.engine.EngineDataPlane()
                } catch (e: Exception) {
                    // 数据面建立失败不等价熔断（§6.5 口径）：控制面存活，
                    // 生成路径不可用，主进程保持云端默认通路。
                    Log.e(TAG, "[DEGRADE] data plane init failed: $e")
                    null
                }
            }
            // 后端可用性（S3 换线）：QnnProbe/jniLibs 探针随裸 Genie C API 链
            // 退役——geniex-android AAR 自带 QNN 运行时全家桶，真伪由 loadModel
            // 的管线创建结果承载（失败置 loadError，主进程收口云端默认通路）。
            return EngineStatus.assetMissing.ordinal
        }

        override fun loadModel(modelDir: String?): Int {
            // S2 正式接线：单飞闸 + 后台线程建 Genie 会话（~2.7s 暖机，不占
            // Binder 线程）。幂等：ready/creating 中重复调用不重建。
            if (modelDir.isNullOrEmpty()) return EngineStatus.unsupportedDevice.ordinal
            if (dataPlane == null) return EngineStatus.assetMissing.ordinal // initEngine 未跑
            if (session.ready) return EngineStatus.ready.ordinal
            if (session.beginLoad()) {
                // S2-4：COLD → WARM 档重入（快速暖机，资产在盘不重下载）；
                // 代次 +1 作废旧 TTL 定时器，新会话新计时基准。
                scheduleTtl(lifecycle.onWarmup())
                // S3 内存面：暖机前采集 availMem 基线——护栏增量自此起算，
                // 覆盖模型加载本身（ION 足迹含在内核 availMem 计账内）。
                warmupBaselineAvailMem = readAvailMem()
                // 装载窗口 FGS 前台化（§6.2）：装载期高 CPU + ~3.2GB 峰值分配
                // 恰是 ColorOS「后台高耗能」击杀画像（S2-5 实证：官方 demo
                // 前台装载 4B 存活、本服务进程同条件被静默 SIGKILL）——受理
                // 即挂 FGS 提权，终态（ready/loadError）撤下。
                promoteFgs("正在本地加载模型")
                Thread({
                    try {
                        session.doLoad(modelDir)
                    } finally {
                        stopFgs()
                    }
                }, "engine-model-load").start()
            }
            // 受理即返回 assetMissing（创建中；就绪后 checkStatus 转 ready）。
            return EngineStatus.assetMissing.ordinal
        }

        override fun getSharedMemory(): android.os.SharedMemory =
            dataPlane?.sharedMemoryForIpc()
                ?: throw UnsupportedOperationException("data plane not initialized")

        override fun getEventFd(): ParcelFileDescriptor =
            dataPlane?.eventReadFd()
                ?: throw UnsupportedOperationException("data plane not initialized")

        override fun startGenerate(requestId: String?, promptJson: String?, generationParams: Bundle?) {
            if (requestId == null) throw IllegalArgumentException("requestId required")
            // S3-1 热闸（§5.2 Thermal→Cloud）：SEVERE 及以上拒绝受理——与
            // onThermalCutover 主动闸门互为冗余（回调丢失的单点保险），不构成
            // TOCTOU 危害（宁多切云不误放行）。
            if (thermal.cutoffActive) throw IllegalStateException("thermal cutoff active (SEVERE+)")
            // S3-3 单执行槽 + 策略 B（§6.6）：原子判定（禁先 check 后调用，
            // 防 TOCTOU）——后台忙即驳（切云，不排队）；前台忙则 abort 在途
            //（§6.3 token 粒度中断）+ 有界等待让槽（绝不驳回用户；前台语义
            // 由主进程 Bridge 依 Activity 前台态注入）。
            val foreground = generationParams?.getBoolean("foreground", false) ?: false
            when (slot.tryAcquire(requestId, foreground) { session.abort() }) {
                com.zzh.goodhub.engine.EngineSlot.AcquireResult.GRANTED -> {}
                com.zzh.goodhub.engine.EngineSlot.AcquireResult.DENIED_BUSY ->
                    throw ServiceBusyException(
                        "${ServiceBusyException.MESSAGE_PREFIX}: engine busy " +
                            "(strategy B, background denied; requestId=$requestId)")
                com.zzh.goodhub.engine.EngineSlot.AcquireResult.DENIED_TIMEOUT ->
                    throw ServiceBusyException(
                        "${ServiceBusyException.MESSAGE_PREFIX}: preempt wait timeout " +
                            "(${com.zzh.goodhub.engine.EngineSlot.DEFAULT_PREEMPT_WAIT_MS}ms), " +
                            "routed to cloud (requestId=$requestId)")
            }
            if (!session.ready) {
                slot.release(requestId)
                throw UnsupportedOperationException(
                    "genie session not ready (loadModel first; loadError=${session.loadError})")
            }
            val dp = dataPlane ?: run {
                slot.release(requestId)
                throw UnsupportedOperationException("data plane not initialized")
            }
            val maxTokens = generationParams?.getInt("maxTokens", 512) ?: 512
            lifecycle.onGenerateStart() // S2-4：WARM_STANDBY → ACTIVE（TTL 定时器随代次作废）
            val cb = listener
            Thread({
                // S3-6 数据面（§6.1 立法语义恢复）：token 流 = RingBuffer 写入
                // （Ashmem）+ pipe 唤醒，主进程 native worker（libgdw）经
                // Dart 端口投递；Binder onTokens 过渡通道随 S3-6 退役。
                //  - 载荷 = 文本块 UTF-8 字节值（identity 字节级；Dart 侧同构
                //    identity 表重组，跨微批边界无损流式 UTF-8 重组 = §6.4）；
                //  - 40ms 微批冲刷（§6.1 节拍契约不变）；
                //  - ring 写超时（500ms）= 消费端死锁（IPC_DEADLOCK §6.3）：
                //    abort 在途生成 + 清空 RingBuffer + onIpcDeadlock 切云
                //    （不计熔断），绝不空转占硬件。
                // §1.2 吞吐打点：时间戳在 sink 入口采集（decode token 粒度，
                // 40ms 微批只影响投递不影响计时）。统计变量放 sink 外层——
                // 结束打点在 query 返回后读，sink 内经闭包回写。
                val benchT0 = System.currentTimeMillis()
                var benchFirst = 0L
                var benchLast = 0L
                var benchChunks = 0
                val sink = object : GenieChunkSink {
                    var pending: MutableList<Int> = ArrayList(64)
                    var lastFlush = System.currentTimeMillis()
                    var ipcDeadlock = false
                    var benchBytes = 0        // 写侧累计入环字节数（与 Dart 接收对账）
                    var benchBytesMark = 0

                    override fun onChunk(text: String) {
                        if (text.isEmpty() || session.abortRequested || ipcDeadlock) return
                        val t = System.currentTimeMillis()
                        if (benchFirst == 0L) benchFirst = t
                        benchLast = t
                        benchChunks++
                        val bytes = text.toByteArray(Charsets.UTF_8)
                        for (i in bytes.indices) pending.add(bytes[i].toInt() and 0xFF)
                        val now = System.currentTimeMillis()
                        if (now - lastFlush >= 40) {
                            flush()
                        }
                    }

                    /// 40ms 微批冲刷：RingBuffer 写入（满时 park 有界等待 ≤
                    /// writeTimeoutMs=500ms——§6.3 有界背压；超时即消费端死锁）。
                    /// 异常不在 Genie 回调栈内穿透：就地 abort 并标记，query
                    /// 返回后走 onIpcDeadlock 切云。
                    fun flush() {
                        val flushed = pending.size
                        try {
                            // 诊断打点（S2-5 字节流腐化排查）：前三批 hex 采样。
                            if (benchChunks <= 3 && pending.isNotEmpty()) {
                                val hex = pending.take(16).joinToString(" ") {
                                    "%02x".format(it)
                                }
                                Log.i(TAG, "flush #${benchChunks + 1} n=${pending.size} head=[$hex]")
                            }
                            dp.ring.write(pending.toIntArray())
                        } catch (e: com.zzh.goodhub.engine.IpcDeadlockException) {
                            ipcDeadlock = true
                            Log.w(TAG, "[DEGRADE] ipc deadlock (consumer stalled): $e")
                            // 诊断打点（S2-5）：死锁瞬间写者视角游标现场。
                            Log.w(TAG, "[DEGRADE] writer cursor: ${dp.ring.diagCursor()}")
                            runCatching { session.abort() }
                            dp.ring.clearPending()
                            pending.clear()
                            return
                        }
                        pending = ArrayList(64)
                        lastFlush = System.currentTimeMillis()
                        // 诊断打点（S2-5 字节流对账）：写侧累计字节数——与 Dart
                        // 接收侧累计对账，区分「ring/投递丢字节」与「解码器状态」。
                        benchBytes += flushed
                        if (benchBytes / 200 > benchBytesMark) {
                            benchBytesMark = benchBytes / 200
                            Log.i(TAG, "flushed cum=${benchBytes}B")
                        }
                    }
                }
                try {
                    // 同步生成：Genie 经回调流式投块（native → JNI → 本 sink），
                    // 本线程阻塞至完成/abort。返回 0=SUCCESS / 1=WARNING_ABORTED
                    //（cancel 生效）/ 负值=ERROR_*。
                    val status = session.query(promptJson.orEmpty(), maxTokens, sink)
                    val cancelled = session.abortRequested || status == 1 || sink.ipcDeadlock
                    if (!cancelled && sink.pending.isNotEmpty()) {
                        sink.flush()
                    }
                    // §6.3：cancel 清空在途后以 cancelled 收尾；正常完成 stop。
                    // IPC 死锁：上报切云沿（不计熔断口径，§6.3/§6.5）——流收尾
                    // 仍走 cancelled（partial 产出不得伪装完整答案）。查询失败
                    //（负状态码）同样以 cancelled 收尾：日志留痕。
                    dp.ring.clearPending()
                    if (sink.ipcDeadlock) {
                        runCatching { cb?.onIpcDeadlock() }
                    }
                    if (status < 0) {
                        Log.w(TAG, "[DEGRADE] genie query failed: status=$status")
                    }
                    // TPOT 分母钉子：优先用 Genie 自报的真实生成 token 数
                    //（GenieDialog_getValue / NUM_GENERATED），不可用则回退
                    // chunks-1（旧近似，1 chunk = 1 token 未实证）。
                    val gen = session.numGenerated()
                    val span = if (benchChunks > 1) benchLast - benchFirst else 0L
                    val denom = if (gen > 1) gen - 1 else (benchChunks - 1).coerceAtLeast(1)
                    val tpot = if (span > 0) span.toDouble() / denom else 0.0
                    Log.i(TAG, "bench: ttft=${benchFirst - benchT0}ms decodeSpan=${span}ms "
                        + "chunks=$benchChunks numGenerated=$gen "
                        + "tpot=${java.lang.String.format(java.util.Locale.US, "%.1f", tpot)}"
                        + "ms/token")
                    cb?.onGenerateFinished(requestId, if (cancelled || status < 0) 1 else 0)
                } catch (e: Exception) {
                    Log.w(TAG, "[DEGRADE] genie generate aborted: $e")
                    runCatching { dp.ring.clearPending() }
                    runCatching { cb?.onGenerateFinished(requestId, 1) }
                } finally {
                    // S3-3：槽释放（仅槽主生效；抢占方 CAS 等待即刻放行）。
                    slot.release(requestId)
                    // S3-2：FGS 卸载（§6.2 收尾对称——promote 可能未发生
                    //（短生成/后台跳过），stopForeground 为幂等 no-op）。
                    runCatching {
                        stopForeground(Service.STOP_FOREGROUND_REMOVE)
                    }.onFailure { Log.w(TAG, "[DEGRADE] stopForeground: $it") }
                    // S2-4：ACTIVE → WARM_STANDBY（重排 TTL + 内存预算护栏，
                    // §4.1「逼近 LMK 阈值即使 TTL 内也提前驱逐」）。
                    scheduleTtl(lifecycle.onGenerateFinished())
                    checkMemoryGuard()
                }
            }, "engine-genie-generate").start()
        }

        override fun cancelGenerate(requestId: String?) {
            // §6.3：GenieDialog_signal(ABORT) → 生成循环 token 粒度检查 m_abort
            // 即时跳出（SDK 源码实证），不空转。
            session.abort()
            Log.d(TAG, "cancelGenerate: ABORT signaled (requestId=$requestId)")
        }

        override fun truncateContext(keepTokens: Int) {
            // S3-6 KV 复用语义收口（总纲 §2「keepTokens=0 等价旧 resetContext」
            // + NPU 稿 §2.4 Prefix Cache 唯一主路线）：geniex-android 管线下
            // 前缀复用为运行时内置，App 侧无需自研 KV 槽位管理——
            //  - keepTokens=0（清历史重放同前缀）：GenieSession.query 每请求
            //    前置 reset 单发隔离，KV 从 0 对齐口径天然满足；重放同前缀
            //    命中运行时前缀缓存（llama.cpp prompt cache 层），S2-5 观测
            //    钩子即按此口径复测；
            //  - keepTokens>0（部分回滚）：Genie 无部分回滚 API，不支持——
            //    DEGRADE 留痕不静默，调用方按全会话语义使用。
            if (keepTokens > 0) {
                Log.w(TAG, "[DEGRADE] truncateContext partial rollback unsupported " +
                    "(Genie no partial KV API): keepTokens=$keepTokens")
            } else {
                Log.d(TAG, "truncateContext(0): single-turn reset enforced per query (§2/§2.4)")
            }
        }

        override fun releaseEngine() {
            // S3-4 终止下沉（§4.1 组合语义）：release = 先中止在途生成
            // （cancel 链下沉，无在途时幂等无害）再析构。释放经状态机单源
            // 驱动（lifecycle.onRelease → onEvict 回调 = Genie 会话 + 数据面
            // 释放，与 TTL/护栏驱逐同一路径）——修正此前直接 close 绕过
            // 状态机致 state 失真/旧 TTL 定时器不作废的缺口。释放后
            // checkStatus 回落 assetMissing；重新可用须 loadModel（资产在盘，
            // 二次暖机秒级，不重下载）。
            Log.d(TAG, "releaseEngine: abort in-flight + lifecycle release (COLD-EVICTED)")
            session.abort()
            lifecycle.onRelease()
        }

        override fun checkStatus(): Int {
            // 会话状态（S2 正式接线）：生成在途 → busy（仅监控展示，禁 TTL
            // 缓存，v2.6）；会话 ready → ready；creating/未装载 → assetMissing
            // （过渡口径：无独立 creating 序数——三态状态机归 S2-4）。设备
            // 可用性由 loadModel 管线创建结果承载（探针已随换线退役）。
            // S3-1：热切云期 → circuitBroken（环境降级可自愈语义，禁缓存 v2.6
            // 同样适用——热回落沿经 onThermalCutover 主动解除）。
            if (thermal.cutoffActive) return EngineStatus.circuitBroken.ordinal
            if (slot.isBusy) return EngineStatus.busy.ordinal
            return (if (session.ready) EngineStatus.ready else EngineStatus.assetMissing).ordinal
        }

        // S3-2：FGS 前台预挂执行面（§6.2 v2.7）——主进程已作前台态判定与
        // 长生成阈值判定，此处无条件执行；时序违规竞态（判定后瞬间退后台）
        // 经 catch 防御，绝不令 :engine 崩溃（DEGRADE = 无 FGS 保活，仅损失
        // OEM 冻结防御强度，生成本身不受影响）。
        override fun promoteForeground() = promoteFgs("正在本地生成")

        private fun promoteFgs(title: String) {
            val svc = this@EngineService
            try {
                val icon = svc.applicationInfo.icon
                val notification = android.app.Notification.Builder(svc, FGS_CHANNEL_ID)
                    .setContentTitle(title)
                    .setSmallIcon(if (icon != 0) icon else android.R.drawable.stat_notify_sync)
                    .setOngoing(true)
                    .build()
                startForeground(
                    FGS_NOTIFICATION_ID,
                    notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
                Log.d(TAG, "FGS promoted (dataSync, foreground pre-attach)")
            } catch (e: Exception) {
                Log.w(TAG, "[DEGRADE] startForeground rejected (时序竞态兜底): $e")
            }
        }

        private fun stopFgs() {
            runCatching { stopForeground(Service.STOP_FOREGROUND_REMOVE) }
                .onFailure { Log.w(TAG, "[DEGRADE] stopForeground: $it") }
        }

        override fun diagPanic() {
            // S2-5 熔断验证（PATCH：诊断接口）：模拟驱动 Panic——走真实
            // onEngineDied 信号链，主进程侧计入熔断计数（§6.5）。
            Log.w(TAG, "[DIAG] diagPanic: simulating driver panic via onEngineDied")
            notifyEngineDied()
        }
    }

    /// §6.2/§4.1：onTrimMemory 驱动三态状态机——RUNNING_CRITICAL /
    /// BACKGROUND 及以上立即 COLD-EVICTED（析构 Genie 会话 + 数据面，进程
    /// RSS 压至 50MB 以下）；低等级留痕不动作。
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        val evicted = lifecycle.onTrimMemory(level)
        Log.d(TAG, "trimMemory level=$level evicted=$evicted")
    }

    /// :engine 侧主动上报热切云沿（S3-1：AIDL oneway 广播不阻塞）。
    private fun notifyThermalCutover(active: Boolean) {
        try {
            listener?.onThermalCutover(active)
        } catch (e: RemoteException) {
            Log.w(TAG, "listener dead while reporting thermal cutover: $e")
        }
    }

    override fun onCreate() {
        super.onCreate()
        val pm = getSystemService(android.os.PowerManager::class.java)
        if (pm != null) {
            pm.addThermalStatusListener(thermalListener)
            // 初始态对齐：进程启动时可能已处于升温态（getCurrentThermalStatus）。
            thermal.onThermalStatus(pm.currentThermalStatus)
        } else {
            Log.w(TAG, "[DEGRADE] PowerManager unavailable: thermal scheduling disabled")
        }
        // S3-2：FGS 通知渠道（幂等；IMPORTANCE_LOW = 静默栏位通知，不打扰）。
        runCatching {
            val nm = getSystemService(android.app.NotificationManager::class.java)
            nm?.createNotificationChannel(
                android.app.NotificationChannel(
                    FGS_CHANNEL_ID, "端侧本地生成", android.app.NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }.onFailure { Log.w(TAG, "[DEGRADE] notification channel: $it") }
    }

    override fun onDestroy() {
        val pm = getSystemService(android.os.PowerManager::class.java)
        pm?.removeThermalStatusListener(thermalListener)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder = stub

    override fun onLowMemory() {
        super.onLowMemory()
        Log.w(TAG, "[DEGRADE] engine process low memory: state machine not yet wired")
    }

    /// :engine 侧主动上报致命事件（§2 EngineDied 回调；oneway 广播不阻塞）。
    /// 主进程侧另经 ServiceConnection.onServiceDisconnected 捕获进程死亡，
    /// 两路最终同归切云路径（S1-5 接线）。
    private fun notifyEngineDied() {
        try {
            listener?.onEngineDied()
        } catch (e: RemoteException) {
            Log.w(TAG, "listener dead while reporting engine died: $e")
        }
    }
}
