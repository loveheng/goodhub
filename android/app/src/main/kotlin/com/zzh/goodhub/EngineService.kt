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
/// Binder/AIDL 控制面 + UDS socketpair 数据面通信（on-device-npu-deployment.md
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

        /// B-1 装载窗口 abort 线：跌破 = 整机内存进入击杀窗口，best-effort 早退。
        private const val LOAD_ABORT_AVAIL_MEM_BYTES = 1024L * 1024 * 1024

        /// 护栏周期采样间隔（P2-11，2026-11-01）：生成期（内存活动峰值段，数十秒）
        /// 每 5s 采样一次 availMem 护栏——旧实现仅 finally 收尾采样一次，
        /// 「逼近 LMK 提前驱逐」只兑现 1/N。5s = 采样周期量级，与评估器
        /// 8MB 抖动容差匹配（一个周期的抖动量级），不追峰值精度。
        private const val GUARD_SAMPLE_INTERVAL_MS = 5000L

        // ==== 旧裸 Genie C API 注入面（日志级别/per-stage 策略/config 键
        // 覆写/投递链 DRAIN 档）随 S3 换线退役====：geniex-android 管线无
        // 对应注入 API——日志与调优归 SDK 默认 + 资产 htp config
        // （perf_profile=sustained_high_performance 已实证固化），投递链
        // 成本已经 DRAIN 对照实证为零（devlog 2026-10-29）。

        init {
            // G2-2：墓碑崩溃栈捕获库（SIGSEGV/SIGABRT/SIGBUS 落盘）——加载
            // 失败不阻断服务（[DEGRADE] 留痕，死因可见性退回 flag-only）。
            runCatching { System.loadLibrary("engine_tombstone") }
                .onFailure { Log.w(TAG, "[DEGRADE] engine_tombstone load failed: $it") }
        }

        // 由 engine_tombstone.cpp 实现（G2-2）：注册崩溃信号处理器。
        private external fun nativeInitTombstone(dir: String)
    }

    private var listener: IOnDeviceEngineListener? = null

    /// 数据面（§6.1）：initEngine 时建立，getSharedMemory/getEventFd 下发句柄；
    /// 失败降级为 null（控制面后续调用快速失败，不拖垮绑定）。
    private var dataPlane: com.zzh.goodhub.engine.EngineDataPlane? = null

    /// Genie 正式会话（S2 正式接线）：持久 Dialog 生成后端。
    private val session = GenieSession(this)

    /// 会话票据的**进程实例标识**（M1 Expand；设计 §2.2）：进程启动时生成的
    /// UUID——进程重建必变，故无需磁盘持久化即可判别「票据来自另一进程实例」。
    /// 不用 `elapsedRealtime`（重启归零可碰撞）也不用 pid（可复用）。
    private val instanceId = java.util.UUID.randomUUID().toString()

    /// 票据的资产身份（M1 Expand 简化 = 最近一次 `loadModel` 的目录名；
    /// M2 接资产面指纹）。装载受理即回填，驱逐不空（票据 status 已表达失效）。
    private var loadedModelId: String = ""

    /// S3-3 单执行槽（§6.6）：策略 B 驳回 + 前台抢占的原子判定面。
    private val slot = com.zzh.goodhub.engine.EngineSlot()

    /// S3-2 FGS 挂载（**路线 B 裁决 2026-10-30**；同锚见 [EngineServiceBridge]）。
    ///
    /// 口径 = **绑定即挂，驱逐 / 显式释放才撤**：
    ///  - 为什么必须挂：`:engine` 与主进程**同 UID**，进程隔离只隔离了崩溃
    ///    传播，**隔离不了 App 前后台状态**——主进程退后台即整个 UID 进
    ///    CACHED，:engine 随之落入 OEM 冻结 / mem-pressure 回收射程
    ///    （真机实证 `freezing <pid> com.zzh.goodhub:engine` +
    ///    `Rescheduling restart of crashed service ... for mem-pressure-event`）。
    ///  - 为什么挂在这里：Android 12+ **禁止后台启动** FGS
    ///    （`ForegroundServiceStartNotAllowedException`），故挂载点必须与
    ///    「绑定 / 装载 / 生成」这些前台或刚被唤起的时机对齐，严禁退后台补救。
    ///  - 撤下对称归 [lifecycle].onEvict（TTL / trim / 护栏驱逐 + 显式
    ///    release）——「只要还端着权重就挂着，权重一放就收」。
    private fun promoteFgs(title: String) {
        try {
            val icon = applicationInfo.icon
            val notification = android.app.Notification.Builder(this, FGS_CHANNEL_ID)
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
            // 后台启动被 ROM 拒绝：DEGRADE 留痕，不阻断生成（仅损失保活强度）。
            Log.w(TAG, "[DEGRADE] startForeground rejected (时序竞态兜底): $e")
        }
    }

    private fun stopFgs() {
        runCatching { stopForeground(Service.STOP_FOREGROUND_REMOVE) }
            .onFailure { Log.w(TAG, "[DEGRADE] stopForeground: $it") }
    }

    /// 数据面惰性重建（initEngine 与 loadModel 共用）：驱逐/TTL 回收清空
    /// dataPlane 后，onServiceConnected 不会再次触发，重入只能靠装载路径
    /// 就地重建。失败 = 生成路径不可用（控制面存活，§6.5 口径不等价熔断），
    /// 返回 false 交调用方快速失败并留痕。
    private fun ensureDataPlane(): Boolean {
        if (dataPlane != null) return true
        dataPlane = try {
            com.zzh.goodhub.engine.EngineDataPlane()
        } catch (e: Exception) {
            Log.e(TAG, "[DEGRADE] data plane init failed: $e")
            null
        }
        return dataPlane != null
    }

    /// F4 装载停滞看门狗（裁决 5「活体判据优先，时长作上界」）：阶段打点后
    /// [kLoadPhaseHardTimeoutMs] 内装载仍未完成（creating 且非 ready）= 停滞
    /// ——由 **:engine 自己**裁决：自签 `LOAD_STALLED` 真因（经 loadError 带
    /// 给主进程）后走单例纪律同款干净退出（冷启动新进程承载复载）。主进程
    /// **不新增跨进程 SIGKILL 权**——否则墓碑排除法把有意重启误判为 LMK
    /// 快死，fastKillStreak 抬水位反堵重载（2026-10-31 ADR 立法）。
    /// 上界取 90s 与既有请求侧口径对齐（冷重载数十秒实证，10~15s 会误杀慢盘）。
    private fun startLoadStallWatchdog() {
        val startedAt = android.os.SystemClock.elapsedRealtime()
        Thread({
            while (session.creating && !session.ready) {
                val elapsed = android.os.SystemClock.elapsedRealtime() - startedAt
                if (elapsed > kLoadPhaseHardTimeoutMs) {
                    Log.w(TAG, "[DEGRADE] load stall watchdog: no progress in " +
                        "${elapsed / 1000}s -> LOAD_STALLED, clean exit for cold reload")
                    session.loadError = "LOAD_STALLED: no phase progress in ${elapsed / 1000}ms"
                    runCatching { session.abort() }
                    runCatching {
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            android.os.Process.killProcess(android.os.Process.myPid())
                        }, 300)
                    }
                    return@Thread
                }
                Thread.sleep(1000)
            }
        }, "engine-load-stall-watchdog").start()
    }

    private val kLoadPhaseHardTimeoutMs: Long = 90_000L

    private fun notifyLoadPhase(phase: Int) {
        Log.i(TAG, "load phase -> $phase")
        runCatching { listener?.onLoadPhaseChanged(phase) }
    }

    /// G2-1 墓碑标记（死因可见性 ADR 2026-10-31）：`<pid>.flag` 生命周期状态
    /// 文件——FLAG_LOADING（loadModel 受理）/ FLAG_READY（doLoad 成功），
    /// 正常退出（onDestroy）清理。SIGKILL 不可捕获 → 死因对 App 不可见，
    /// 排除法裁定靠本文件：主进程 DeathRecipient 时「有 Crash Stack =
    /// HARD_CRASH；无 Stack + FLAG_LOADING + 整机内存低 = LMK_SIGKILL；
    /// FLAG_READY 无 Stack = 运行期外部终止」。目录与 Crash Stack 同置
    /// files/tombstone（同 App UID，主进程可读）。
    private fun tombstoneDir(): java.io.File =
        java.io.File(filesDir, "tombstone").apply { mkdirs() }

    private fun writeTombstoneFlag(state: String) {
        runCatching {
            java.io.File(tombstoneDir(), "${android.os.Process.myPid()}.flag")
                .writeText(state)
        }.onFailure { Log.w(TAG, "[DEGRADE] tombstone flag write failed: $it") }
    }

    private fun clearTombstoneFlag() {
        runCatching {
            java.io.File(tombstoneDir(), "${android.os.Process.myPid()}.flag").delete()
        }
    }

    /// B-1 装载窗口内存监控：4B 装载峰值 HWM ~3.2GB，跌破 abort 线 = 整机内存
    /// 进入 mem-pressure 击杀窗口——best-effort abort + 留证后退出。
    // UNCERTAIN: geniex 管线 create 阶段不可取消（abort 仅对 query 流生效，
    // wrapper 在 create 完成前为 null）——若中止无效，进程仍可能被 SIGKILL；
    // 本监控的实证底线 = 击杀前的日志证据链（availMem 轨迹），供装载存活
    // 策略（B 工作流）后续以真实数据定阈值。监控线程自 terminate（1s 节拍，
    // creating 清除/ready 置位即退出），无句柄泄漏面。
    private fun startLoadMemMonitor() {
        Thread({
            while (session.creating && !session.ready) {
                val avail = readAvailMem()
                if (avail < LOAD_ABORT_AVAIL_MEM_BYTES) {
                    Log.w(TAG, "[DEGRADE] load mem monitor: availMem=${avail shr 20}MB < " +
                        "${LOAD_ABORT_AVAIL_MEM_BYTES shr 20}MB - abort in-flight load (best effort)")
                    runCatching { session.abort() }
                    break
                }
                // 温控摘除（2026-10-31 用户裁决）：OEM 热档位（SoC 限频档）与
                // 壳温体感严重不符，误判史多次实证——装载期热监控随之退役，
                // 极端发热交 OEM 自身限频/降频保护。
                Thread.sleep(1000)
            }
        }, "engine-load-mem-monitor").start()
    }

    /// S2-4 三态生命周期状态机（§4.1）：驱逐动作 = Genie 会话 + 数据面释放。
    private val lifecycle = com.zzh.goodhub.engine.EngineLifecycle { reason ->
        Log.i(TAG, "lifecycle evict: $reason")
        session.close()
        dataPlane?.close()
        dataPlane = null
        // P0-3 收口：驱逐是 `:engine` **自发**的状态变更（TTL / trim / 护栏 /
        // 主动 release），必须上行主进程——否则 Dart 侧 `loadState` 停在
        // ready 说谎态，下一次端侧请求必败且归因误导（详见
        // IOnDeviceEngineListener.onEngineEvicted 的注释）。
        // 注：进程被外部处决的路径不走这里（Binder 已断，由主进程
        // ServiceConnection.onServiceDisconnected 合流）。
        notifyEngineEvicted(reason)
        // FGS 撤下对称（路线 B）：驱逐 = 权重释放，保活失去意义，常驻通知须收。
        stopFgs()
    }

    /// TTL 定时器（主线程 Handler；代次失配由状态机作废，防旧计时器杀新会话）。
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

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

    /// 装载单例纪律（用户拍板 2026-10-30）：一个 :engine 进程生命周期内只允许
    /// 一次有效装载——本进程装载过一次后，驱逐/释放引发的复载**不在本进程
    /// 重建**（geniex destroy 是否完整释放 ION/DSP PD 不可实证；真机三次实证
    /// 同进程重载数秒内 availMem 跌破 1GB 被杀），复载一律干净退出交 AMS
    /// 冷启动新进程装载（官方 demo 形态：单进程单装载，全新 ION 零叠加）。
    private var loadedOnce = false

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

    /// 生成期护栏周期采样（P2-11，2026-11-01）：守护线程每
    /// [GUARD_SAMPLE_INTERVAL_MS] 采样一次护栏，收尾由调用方中断——
    /// 旧实现仅 finally 采样一次，生成峰值段（数十秒）零覆盖，
    /// 「逼近 LMK 提前驱逐」只兑现 1/N。护栏触发走 [lifecycle.onGuardBreached]
    /// 与收尾采样同一路径（abort 在途 + 状态机驱逐），线程本体不做驱逐动作。
    private fun startGuardSampler(): Thread {
        val t = Thread {
            try {
                while (true) {
                    Thread.sleep(GUARD_SAMPLE_INTERVAL_MS)
                    checkMemoryGuard()
                }
            } catch (e: InterruptedException) {
                // 收尾中断 = 正常退出路径（finally 统一收口）。
            } catch (e: Exception) {
                Log.w(TAG, "[DEGRADE] guard sampler: $e")
            }
        }
        t.name = "engine-guard-sampler"
        t.isDaemon = true
        t.start()
        return t
    }

    /// 权威状态求值（S2 正式接线；M1 抽为单点供 `checkStatus` 与 `checkSession`
    /// 共用——两处口径必须同源，否则票据与序数会各说一套）。
    ///
    /// 会话状态：生成在途 → busy（仅监控展示，禁 TTL 缓存，v2.6）；会话 ready →
    /// ready；creating（装载中）→ **loading**（M4 受理态，P2-14 销账——受理态
    /// 不再复用 assetMissing 的「资产缺失」措辞误导补救方向）；未装载且非创建中
    /// → assetMissing（M4 起回归**终态**语义：真·未导入/校验不过）。设备可用性由
    /// loadModel 管线创建结果承载（探针已随换线退役）。
    private fun currentStatus(): EngineStatus {
        if (slot.isBusy) return EngineStatus.busy
        if (session.creating) return EngineStatus.loading
        return if (session.ready) EngineStatus.ready else EngineStatus.assetMissing
    }

    private val stub = object : IOnDeviceEngineService.Stub() {
        override fun initEngine(config: Bundle?, cb: IOnDeviceEngineListener?): Int {
            listener = cb
            ensureDataPlane()
            // 后端可用性（S3 换线）：QnnProbe/jniLibs 探针随裸 Genie C API 链
            // 退役——geniex-android AAR 自带 QNN 运行时全家桶，真伪由 loadModel
            // 的管线创建结果承载（失败置 loadError，主进程收口云端默认通路）。
            //
            // S3-2 FGS 挂载（**路线 B 裁决 2026-10-30**）：**绑定即挂**。
            // 机制根因 —— `:engine` 与主进程**同 UID**，进程隔离只切断崩溃传播，
            // **切不断 App 前后台状态**：主进程退后台即整个 UID 进 CACHED，:engine
            // 随之落入 OEM 冻结 / mem-pressure 回收射程（真机实证
            // `freezing <pid> com.zzh.goodhub:engine` + `Rescheduling restart of
            // crashed service ... for mem-pressure-event`）。FGS 是唯一能把该进程
            // 拉出「后台缓存」判定的机制；而 Android 12+ 禁止**后台启动** FGS，
            // 故挂载点必须与绑定握手对齐（此刻 App 在前台或刚被唤起，启动合法），
            // 严禁退后台补救。撤下对称 = [releaseEngine] + lifecycle 驱逐回调。
            promoteFgs("端侧引擎运行中")
            return EngineStatus.assetMissing.ordinal
        }

        override fun loadModel(modelDir: String?, modelId: String?): Int {
            // S2 正式接线：单飞闸 + 后台线程建 Genie 会话（~2.7s 暖机，不占
            // Binder 线程）。幂等：ready/creating 中重复调用不重建。
            if (modelDir.isNullOrEmpty()) return EngineStatus.unsupportedDevice.ordinal
            // 驱逐/TTL 回收后 dataPlane 已清（P0-3 释放沿），而 onServiceConnected
            // 不会因驱逐再次触发——此处必须惰性重建，否则永久静默短路 assetMissing
            // （真机实证：装载零日志 + 轮询 60s 超时报「模型装载失败（assetMissing）」）。
            if (dataPlane == null && !ensureDataPlane()) {
                Log.w(TAG, "[DEGRADE] loadModel: data plane rebuild failed, cloud fallback")
                return EngineStatus.unsupportedDevice.ordinal
            }
            if (session.ready) return EngineStatus.ready.ordinal
            // 装载单例纪律执行点：本进程已装载过（loadedOnce）且会话非 ready
            // （驱逐/释放后）——拒绝本进程重建，回**重启装载**信号后干净退出，
            // AMS 冷启动新进程承载复载（Dart 侧按可重试中断处理：短退避重绑，
            // 接住冷启动后的新进程）。杜绝同进程二次装载的 ION/DSP PD 叠加
            // （真机三次实证必死）。
            // Fix1：返回值由 assetMissing 改 reloading——assetMissing 是终态
            // 「真·未导入」，复用它把「回收后重载」报成「请重新导入模型」
            // （补救方向误导），且主进程按终态判死不再重试 → 端侧静默永久失效。
            if (loadedOnce) {
                Log.w(TAG, "[DEGRADE] loadModel: in-process reload refused " +
                    "(singleton-per-process) -> clean exit for cold reload")
                runCatching {
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }, 300)
                }
                return EngineStatus.reloading.ordinal
            }
            if (session.beginLoad()) {
                loadedOnce = true
                writeTombstoneFlag("FLAG_LOADING") // G2-1：死因排除法锚点
                // M2 §2.5 I3：资产身份由 Dart 资产面单点计算（目录名@meta版本
                // 摘要），票据回显承载 I3 对账；空值退化目录名。
                loadedModelId = modelId?.takeIf { it.isNotEmpty() }
                    ?: java.io.File(modelDir).name
                // 护栏口径（用户拍板 2026-10-30）：护栏是兜底不是限制——装载时刻
                // 不做前置拒绝（失败有后台重试自愈），此处仅留内存快照。同进程
                // 二次装载 ION 泄漏对账（真机实证：驱逐后同 pid 重载 5s 内
                // availMem 570MB 被杀，疑似 destroy 未释放 ION）：受理时快照 vs
                // 监控期谷值 vs 上轮装载基线三值对账定音，禁猜测性兜底。
                val availNow = readAvailMem()
                Log.i(TAG, "loadModel accepted: availMem=${availNow shr 20}MB " +
                    "creating=${session.creating}")
                // S2-4：COLD → WARM 档重入（快速暖机，资产在盘不重下载）；
                // 代次 +1 作废旧 TTL 定时器，新会话新计时基准。
                scheduleTtl(lifecycle.onWarmup())
                // S3 内存面：暖机前采集 availMem 基线——护栏增量自此起算，
                // 覆盖模型加载本身（ION 足迹含在内核 availMem 计账内）。
                warmupBaselineAvailMem = readAvailMem()
                // 装载走后台线程（不占 Binder 线程）。**FGS 不在此挂撤** ——
                // 已于 initEngine 绑定即挂（路线 B 收口）；旧口径「装载窗口挂、
                // 收尾撤」恰是「idle 态裸奔被 OEM 冻结」的成因之一。
                Thread({
                    // F4 活体打点（裁决 5）：阶段推进 = 活体信号，主进程可观测
                    // 装载是否推进（GenieX 黑盒内部不可细分，见 listener 契约）。
                    notifyLoadPhase(IOnDeviceEngineListener.LOAD_PHASE_PARSING)
                    notifyLoadPhase(IOnDeviceEngineListener.LOAD_PHASE_ALLOCATING)
                    startLoadStallWatchdog()
                    session.doLoad(modelDir)
                    // G2-1：装载终态落墓碑——成功 FLAG_READY；失败保持
                    // FLAG_LOADING（装载中死亡 = LMK 候选，排除法消费）。
                    if (session.ready) writeTombstoneFlag("FLAG_READY")
                }, "engine-model-load").start()
                startLoadMemMonitor()
            }
            // 受理即返回 loading（M4 受理态，P2-14 销账——不再复用 assetMissing
            // 的「资产缺失」措辞；就绪后经票据面转 ready）。
            return EngineStatus.loading.ordinal
        }

        override fun getDataSocketFd(): ParcelFileDescriptor =
            dataPlane?.dataSocketFd()
                ?: throw UnsupportedOperationException("data plane not initialized")

        override fun startGenerate(requestId: String?, promptJson: String?, generationParams: Bundle?,
                                   expectInstanceId: String?, expectSeq: Long, expectModelId: String?) {
            if (requestId == null) throw IllegalArgumentException("requestId required")
            // M3 原子自证（on-device-lifecycle-single-source.md §2.3 I4）：判定与
            // 受理在同一入口完成，主进程不再「先查后发」。epoch 是入口闸门非
            // 在途吊销令（I6）：受理后中途代次递增不影响本次生成。
            // 不匹配 = 投影说谎/进程重建/装载目标变更 → 主进程作废镜像走装载。
            // 匹配但装载中 = SESSION_LOADING（受理态，主进程有界等待后复核）。
            if (expectInstanceId != instanceId ||
                expectSeq != lifecycle.currentGeneration.toLong()) {
                throw UnsupportedOperationException(
                    "SESSION_EPOCH_MISMATCH: current=$instanceId#${lifecycle.currentGeneration} " +
                        "status=${currentStatus()} modelId=$loadedModelId " +
                        "(expected=$expectInstanceId#$expectSeq)")
            }
            // F2（2026-10-31 ADR）：资产身份（I3）同入口原子比对——票据 modelId
            // ≠ 装载 modelId = 资产变更（删除/重导入/换模型）→ 专属分码驱动
            // 主进程作废镜像重装，不再靠 epoch 偶发错位兜底（§2.5 兑现的另一半）。
            if (!expectModelId.isNullOrEmpty() &&
                loadedModelId.isNotEmpty() && expectModelId != loadedModelId) {
                throw UnsupportedOperationException(
                    "SESSION_MODEL_MISMATCH: loaded=$loadedModelId (expected=$expectModelId)")
            }
            if (!session.ready) {
                if (session.creating) {
                    throw UnsupportedOperationException(
                        "SESSION_LOADING: model loading in progress " +
                            "(modelId=$loadedModelId, loadError=${session.loadError})")
                }
                // 非 ready 且非装载中（驱逐/释放/进程半死）= 投影必然过期。
                throw UnsupportedOperationException(
                    "SESSION_EPOCH_MISMATCH: session not ready (loadModel first; " +
                        "loadError=${session.loadError})")
            }
            // S3-3 单执行槽 + 策略 B（§6.6）：epoch 闸之后原子抢占判定——后台忙
            // 即驳（切云，不排队）；前台忙则 abort 在途（§6.3 token 粒度中断）
            // + 有界等待让槽（绝不驳回用户；前台语义由主进程 Bridge 依
            // Activity 前台态注入）。
            val foreground = generationParams?.getBoolean("foreground", false) ?: false
            // 受理打点（诊断面，2026-10-30 真机实证「第二轮没有输出」）：
            // 「第二轮请求是否真的到达 :engine」是第一分叉点——未到达即主进程
            // 侧问题（通道/看门狗/熔断），到达但零产出即会话/模板侧问题。
            Log.i(TAG, "startGenerate: requestId=$requestId " +
                "promptChars=${promptJson?.length ?: 0} fg=$foreground")
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
            val dp = dataPlane ?: run {
                slot.release(requestId)
                throw UnsupportedOperationException("data plane not initialized")
            }
            // Bundle 缝收口：参数读取统一经 GenerationParams（键名/缺省值
            // 单源，禁缝外重抄——原 topP 缺省 0.8 与桥写 0.9 漂移即此弊）。
            val gp = com.zzh.goodhub.engine.GenerationParams.fromBundle(generationParams)
            val maxTokens = gp.maxTokens
            // 采样参数接线（2026-10-30 复读环修复）：此前 Dart 侧随 AIDL 送达
            // 却被丢弃，端侧跑 SDK 默认采样。
            val temperature = gp.temperature.toFloat()
            val topP = gp.topP.toFloat()
            lifecycle.onGenerateStart() // S2-4：WARM_STANDBY → ACTIVE（TTL 定时器随代次作废）
            // F3 大载荷通道（评审修复 2026-10-31）：promptFilePath 在场 = 超内联
            // 上限的 promptJson 经临时文件承载——**读取前移到本同步段**（受理
            // 返回前已读+删，消除「受理成功但生成线程读取前进程被杀」的残留
            // 竞态；~180KB 读耗毫秒级，且此时槽位已授予不放大占用）。评审 #5：
            // 读与删独立 try——读成功即用，删除失败仅 DEGRADE 留痕（由 Dart
            // 侧 finally 兜底删），不再连带丢弃已读 prompt 误拒本轮。
            val effectivePrompt = gp.promptFilePath?.takeIf { it.isNotEmpty() }?.let { path ->
                val text: String? = try {
                    java.io.File(path).readText()
                } catch (e: Exception) {
                    Log.w(TAG, "[DEGRADE] prompt file channel read failed: $e")
                    null
                }
                if (text != null) {
                    try {
                        java.io.File(path).delete()
                        Log.i(TAG, "prompt via file channel: ${text.length} chars")
                    } catch (e: Exception) {
                        Log.w(TAG, "[DEGRADE] prompt file delete failed (read ok): $e")
                    }
                }
                text
            } ?: promptJson.orEmpty()
            val cb = listener
            Thread({
                // S3-6 数据面（§6.1 v3.1 UDS 化）：token 流 = SocketTokenWriter
                // 长度前缀成帧写入（socketpair 写端），主进程 native worker
                //（libgdw）读 socket 帧经 Dart 端口投递。
                //  - 载荷 = 文本块 UTF-8 字节（identity 字节级；Dart 侧同构
                //    identity 表重组，跨帧边界无损流式 UTF-8 重组 = §6.4）；
                //  - 40ms 微批冲刷（§6.1 节拍契约不变）；
                //  - socket 写超时（500ms，内核 SO_SNDBUF 承载短时背压）=
                //    消费端死锁（IPC_DEADLOCK §6.3）：abort 在途生成 + 关闭
                //    数据面（EOF 通知对端）+ onIpcDeadlock 切云（不计熔断），
                //    绝不空转占硬件。
                // §1.2 吞吐打点（2026-10-31 替代）：TTFT/decodeSpan/
                // generatedTokens 单源 = SDK ProfilingData（GenieSession.
                // lastProfile，Completed 事件即达）；本 sink 只保留数据面专属
                // 对账（benchBytes 入环字节 + chunks 计数）。
                val sink = object : GenieChunkSink {
                    var pending: MutableList<Int> = ArrayList(64)
                    var lastFlush = System.currentTimeMillis()
                    var ipcDeadlock = false
                    var benchBytes = 0        // 写侧累计入环字节数（与 Dart 接收对账）
                    var benchBytesMark = 0
                    var benchChunks = 0       // 写侧 chunk 计数（数据面对账）

                    override fun onChunk(text: String) {
                        if (text.isEmpty() || session.abortRequested || ipcDeadlock) return
                        benchChunks++
                        val bytes = text.toByteArray(Charsets.UTF_8)
                        for (i in bytes.indices) pending.add(bytes[i].toInt() and 0xFF)
                        val now = System.currentTimeMillis()
                        if (now - lastFlush >= 40) {
                            flush()
                        }
                    }

                    /// 40ms 微批冲刷：SocketTokenWriter 写帧（socket 缓冲满时
                    /// poll 等可写，有界 ≤writeTimeoutMs=500ms——§6.3 有界背压；
                    /// 超时即消费端死锁）。异常不在 Genie 回调栈内穿透：就地
                    /// abort 并标记，query 返回后走 onIpcDeadlock 切云。
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
                            val payload = ByteArray(flushed)
                            for (i in 0 until flushed) payload[i] = pending[i].toByte()
                            dp.writer.writeToken(payload)
                        } catch (e: com.zzh.goodhub.engine.IpcDeadlockException) {
                            ipcDeadlock = true
                            Log.w(TAG, "[DEGRADE] ipc deadlock (consumer stalled): $e")
                            runCatching { session.abort() }
                            // 数据面整体关闭：EOF 通知读端 → worker 终态退出，
                            // 下次 enable 由 ensureDataPlane 重建（无游标，无需清理）。
                            runCatching { dp.close() }
                            dataPlane = null
                            pending.clear()
                            return
                        }
                        pending = ArrayList(64)
                        lastFlush = System.currentTimeMillis()
                        // 诊断打点（S2-5 字节流对账）：写侧累计字节数——与 Dart
                        // 接收侧累计对账，区分「socket/投递丢字节」与「解码器状态」。
                        benchBytes += flushed
                        if (benchBytes / 200 > benchBytesMark) {
                            benchBytesMark = benchBytes / 200
                            Log.i(TAG, "flushed cum=${benchBytes}B")
                        }
                    }
                }
                // P2-11：生成期护栏周期采样（峰值段覆盖，finally 中断收口）。
                // 声明在 try 外——try 块内局部量 finally 不可见。
                val guardSampler = startGuardSampler()
                try {
                    // F3 大载荷通道：effectivePrompt 已在受理同步段解析（评审
                    // 修复——读取前移，本线程不再触碰临时文件）。
                    // 同步生成：Genie 经回调流式投块（native → JNI → 本 sink），
                    // 本线程阻塞至完成/abort。返回 0=SUCCESS / 1=WARNING_ABORTED
                    //（cancel 生效）/ 负值=ERROR_*。
                    val status = session.query(effectivePrompt, maxTokens, sink, temperature, topP)
                    val cancelled = session.abortRequested || status == 1 || sink.ipcDeadlock
                    // 收尾打点（诊断面）：本轮写侧累计字节 + chunk 数 + 状态码
                    // ——「第二轮零产出」三值对账：bytes=0 即模型侧零产出（会话
                    // 重置失败 / 模板提前闭合 / 流错误），bytes>0 即数据面投递侧
                    // 问题（写侧已出字节但 Dart 未收）。
                    Log.i(TAG, "genie query done: requestId=$requestId status=$status " +
                        "bytes=${sink.benchBytes} chunks=${sink.benchChunks} " +
                        "cancelled=$cancelled")
                    if (!cancelled && sink.pending.isNotEmpty()) {
                        sink.flush()
                    }
                    // §6.3：cancel 清空在途后以 cancelled 收尾；正常完成 stop。
                    // IPC 死锁：上报切云沿（不计熔断口径，§6.3/§6.5）——流收尾
                    // 仍走 cancelled（partial 产出不得伪装完整答案）。查询失败
                    //（负状态码）同样以 cancelled 收尾：日志留痕。
                    //
                    // **尾字节不得丢 + 收尾顺序凭据 = EOS 帧**：无论正常/取消/
                    // 失败，收尾前必发 EOS（len=0 帧）——读端按序投递，Dart 收到
                    // 空批即「本代流终」，尾批必先于 onGenerateFinished 处理
                    // （替代旧 RingBuffer awaitDrained/read_idx 凭据，随游标退役）。
                    // 仅 IPC 死锁路径例外：写端已不可用（数据面已关闭，EOF 通知
                    // 对端），尾批语义由 onIpcDeadlock 切云收口。
                    if (!sink.ipcDeadlock) {
                        try {
                            dp.writer.writeEos()
                        } catch (e: Exception) {
                            Log.w(TAG, "[DEGRADE] writeEos failed: $e")
                        }
                    }
                    if (sink.ipcDeadlock) {
                        runCatching { cb?.onIpcDeadlock() }
                    }
                    if (status < 0) {
                        Log.w(TAG, "[DEGRADE] genie query failed: status=$status")
                    }
                    // 吞吐打点单源 = SDK ProfilingData（2026-10-31 替代宿主
                    // 手写秒表；profile 不可用 = 异常/取消路径，如实留痕）。
                    val p = session.lastProfile
                    if (p != null) {
                        Log.i(TAG, "bench: ttft=${p.ttftMs.toInt()}ms " +
                            "decodeSpan=${p.decodeTimeMs.toInt()}ms " +
                            "chunks=${sink.benchChunks} numGenerated=${p.generatedTokens} " +
                            "tpot=${java.lang.String.format(java.util.Locale.US, "%.1f",
                                if (p.generatedTokens > 1) p.decodeTimeMs / (p.generatedTokens - 1) else 0.0)}" +
                            "ms/token speed=${p.decodingSpeed}tok/s stopReason=${p.stopReason}")
                    } else {
                        Log.i(TAG, "bench: profile unavailable (aborted/error?) " +
                            "chunks=${sink.benchChunks} bytes=${sink.benchBytes}")
                    }
                    cb?.onGenerateFinished(requestId, if (cancelled || status < 0) 1 else 0)
                } catch (e: Exception) {
                    Log.w(TAG, "[DEGRADE] genie generate aborted: $e")
                    runCatching { dp.writer.writeEos() }
                    runCatching { cb?.onGenerateFinished(requestId, 1) }
                } finally {
                    // S3-3：槽释放（仅槽主生效；抢占方 CAS 等待即刻放行）。
                    slot.release(requestId)
                    // S3-2：**FGS 不在此卸载** —— 生成收尾 ≠ 释放权重，
                    // 撤通知会让随后 idle 窗口裸奔落入 OEM 冻结射程。仅把文案
                    // 复位为「运行中」表示空闲；真正撤通知统一由 lifecycle 驱逐
                    // 回调 + [releaseEngine] 承担（路线 B 收口）。
                    promoteFgs("端侧引擎运行中")
                    // S2-4：ACTIVE → WARM_STANDBY（重排 TTL + 内存预算护栏，
                    // §4.1「逼近 LMK 阈值即使 TTL 内也提前驱逐」）。
                    scheduleTtl(lifecycle.onGenerateFinished())
                    // P2-11：先停周期采样（正常路径/异常路径统一收口），
                    // 再做收尾单次采样（终态快照语义不变）。
                    guardSampler.interrupt()
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

        // M4 Contract：checkStatus 轮询面已退役——状态唯一来源 = checkSession
        // 票据面（currentStatus() 仍供 checkSession 与 startGenerate epoch 闸共用）。

        // M1 Expand：会话票据查询面（设计 §2.2）——一次返回权威状态 + 代次 +
        // 资产身份。M4 起为主进程**唯一**状态查询面（checkStatus 已删）。
        override fun checkSession(): Bundle {
            val t = com.zzh.goodhub.engine.SessionTicket(
                instanceId = instanceId,
                seq = lifecycle.currentGeneration.toLong(),
                status = currentStatus(),
                modelId = loadedModelId,
                runtime = session.activeRuntime,
                issuedAtMs = System.currentTimeMillis(),
            )
            return com.zzh.goodhub.engine.SessionTicketWire.run { t.toBundle() }
        }

        override fun promoteForeground() = promoteFgs("正在本地生成")

        // S2-5 熔断验证 diagPanic PATCH 已退役（F5 清账 2026-10-31）：
        // 熔断链由 kEngineInterruptCodes 消费路径 + 真机回归钉承载。
    }

    /// §6.2/§4.1：onTrimMemory 驱动三态状态机——RUNNING_CRITICAL /
    /// BACKGROUND 及以上立即 COLD-EVICTED（析构 Genie 会话 + 数据面，进程
    /// RSS 压至 50MB 以下）；低等级留痕不动作。
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        val evicted = lifecycle.onTrimMemory(level)
        Log.d(TAG, "trimMemory level=$level evicted=$evicted")
    }

    /// `:engine` 侧自发驱逐上行（P0-3；oneway 广播不阻塞）。§2.8 I6：驱逐
    /// 打断在途生成时携带被中断的 requestId（slot 主）——主进程以
    /// SESSION_ABORTED_BY_EVICTION 收口该流（可重试/切云），不误报 EngineDied。
    /// 进程刚被外部处决时 listener 可能已成尸体——RemoteException 静默吞，
    /// 该场景本就由主进程 onServiceDisconnected 接管。
    private fun notifyEngineEvicted(reason: String) {
        val evictingRequestId = if (slot.isBusy) slot.owner else null
        try {
            listener?.onEngineEvicted(reason, evictingRequestId)
        } catch (e: RemoteException) {
            Log.w(TAG, "listener dead while reporting engine evicted: $e")
        }
    }

    override fun onCreate() {
        super.onCreate()
        // 温控摘除（2026-10-31 用户裁决）：OEM 热档位与壳温体感严重不符，
        // 误判史多次实证——不再监听/调度，极端发热交 OEM 自身限频保护。
        // S3-2：FGS 通知渠道（幂等；IMPORTANCE_LOW = 静默栏位通知，不打扰）。
        runCatching {
            val nm = getSystemService(android.app.NotificationManager::class.java)
            nm?.createNotificationChannel(
                android.app.NotificationChannel(
                    FGS_CHANNEL_ID, "端侧本地生成", android.app.NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }.onFailure { Log.w(TAG, "[DEGRADE] notification channel: $it") }
        // G2-2：注册 SIGSEGV/SIGABRT/SIGBUS 崩溃栈落盘（目录与 G2-1 flag 同置，
        // 主进程 DeathRecipient 排除法据此区分 HARD_CRASH vs LMK_SIGKILL）。
        runCatching { nativeInitTombstone(tombstoneDir().absolutePath) }
            .onFailure { Log.w(TAG, "[DEGRADE] tombstone init failed: $it") }
    }

    override fun onDestroy() {
        super.onDestroy()
        // G2-1：正常退出清 flag——防 PID 复用后旧 flag 污染下一次死因裁定。
        clearTombstoneFlag()
    }

    override fun onBind(intent: Intent?): IBinder = stub

    override fun onLowMemory() {
        super.onLowMemory()
        Log.w(TAG, "[DEGRADE] engine process low memory (pre-eviction warning)")
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
