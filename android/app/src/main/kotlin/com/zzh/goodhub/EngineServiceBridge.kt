package com.zzh.goodhub

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import com.zzh.goodhub.engine.GenieXRuntime
import android.util.Log
import com.zzh.goodhub.engine.GenerationParams
import com.zzh.goodhub.engine.SessionTicketWire
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// 端侧引擎绑定桥（on-device epic S1-2）：主进程侧对 `:engine` 的唯一绑定 owner。
///
/// 绑定旗标按 on-device-npu-deployment.md §6.2 硬约束：
/// `Context.BIND_AUTO_CREATE | Context.BIND_IMPORTANT | Context.BIND_ABOVE_CLIENT`
/// ——`:engine` 的 oom_adj 提到前台客户端之上（2026-10-30 实证补强：4B 装载
/// 瞬态 ~5.4GB 把系统推到 LMK 低水位时，FGS 档位的 :engine 仍是击杀前排，
/// 官方 demo 前台进程却能熬过同款瞬态——差异就在击杀优先级，BIND_ABOVE_CLIENT
/// 对齐该保护级别）；由单例 ServiceConnection 常驻持有，避免反复 rebind 抖动。
///
/// S1-2：onServiceConnected 拿到的 Binder 经 AIDL Stub 声明为
/// `IOnDeviceEngineService` 跨进程代理，并立即 `initEngine`（携带 listener 承载
/// `onEngineDied` 回调，经 MethodChannel 反投 Dart）；生成/数据面归 S1-3/S1-5。
object EngineServiceBridge {
    private const val CHANNEL = "goodhub/on_device_engine"
    private const val TAG = "EngineServiceBridge"

    /// M-B 受理期保活（ai-capability-export §5）：外部 ai/complete 冷装载窗口
    /// 的 PARTIAL WakeLock（CPU 不休眠防「载到 90% 被冻」）。
    /// 15min 硬超时兜底键泄漏（三钥匙正常释放外的最后防线，防算力空挂耗电）。
    private const val KEEPALIVE_TIMEOUT_MS = 15L * 60 * 1000

    private var channel: MethodChannel? = null
    private var connection: ServiceConnection? = null
    private var engine: IOnDeviceEngineService? = null

    /// 保活键表（key → 持锁标记；引用计数在 Dart 侧 SupplyKeepalive，此处
    /// 只做键寻址 + 超时兜底；同进程单例，无需并发容器——MethodChannel 回调恒主线程）。
    private val keepaliveKeys = mutableSetOf<String>()
    private var keepaliveWakeLock: PowerManager.WakeLock? = null

    /// 绑定上下文（统一 applicationContext，进程级不变量）。
    /// ServiceDispatcher 按 (Context, connection) 键控——2026-11-02 真机定谳：
    /// bind 用 Activity context 时，ColorOS 后台销毁 Activity 重建后 context
    /// 变化，旧绑定成 zombie 残留（ServiceConnectionLeaked），zombie 持有
    /// conn 的「connected」态使重绑的 onServiceConnected 永不再来 →
    /// listener 通道断 → ready 事件丢失 → 装载链死锁（用户侧「长时间
    /// 加载不出来」）。context 固定为 applicationContext 后配对唯一，
    /// 泄漏路径恒不成立；FGS 预挂判据看 UID 前台态（与 context 无关），
    /// 保活语义不变。
    private var bindContext: Context? = null

    /// 前台态追踪器只注册一次（register 每 Activity 重建调一次——重复注册
    /// 使 started 计数倍增，前台判据失真）。
    private var lifecycleRegistered = false

    // S3-6 数据面消费 worker（NPU 稿 §6.4 v3.1 UDS 化）状态（主进程单实例）：
    // handle = native worker 句柄（GdwNative.start 返回，0 = 未运行）。
    @Volatile
    private var dataPlaneWorkerHandle = 0L

    /// 停止消费 worker 并释放映射（幂等）：disconnect / unbind / 显式 stop
    /// 三路共用。:engine 侧数据面重建（loadModel）后由 Dart 重新 start。
    /// 数据面启动失败诊断线索（无需重编 native 即可定位 -6 根因）：JVM 线程数
    /// 逼近上限 → EAGAIN（线程数到顶）；空闲内存吃紧 → ENOMEM。
    private fun dataPlaneDiag(): String {
        val threads = Thread.getAllStackTraces().size
        val rt = Runtime.getRuntime()
        val freeMb = (rt.freeMemory() shr 20)
        val maxMb = (rt.maxMemory() shr 20)
        return "threads=$threads freeMem=${freeMb}MB/max=${maxMb}MB"
    }

    private fun stopDataPlane() {
        val handle = dataPlaneWorkerHandle
        dataPlaneWorkerHandle = 0
        if (handle != 0L) {
            try {
                GdwNative.stop(handle)
            } catch (e: Exception) {
                Log.w(TAG, "[DEGRADE] gdw stop: $e")
            }
        }
    }

    /// S3-2 前台态判定（§6.2 v2.7「必须前台预挂」的主进程闸）：started Activity
    /// 计数——>0 即前台。promoteForeground 请求仅在此时放行（Android 12+ 后台
    /// startForeground 必抛 ForegroundServiceStartNotAllowedException）。
    @Volatile
    private var foregroundActivities = 0

    private val foregroundTracker = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            foregroundActivities++
        }

        override fun onActivityStopped(activity: Activity) {
            foregroundActivities = (foregroundActivities - 1).coerceAtLeast(0)
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    /// AIDL 回调线程（Binder 线程池）≠ Flutter 平台通道的线程约束（主线程强制）：
    /// R-P0 驻留策略位：bind 时下发的 TTL（毫秒，0 = 不下发用引擎缺省）。
    @Volatile
    private var residencyTtlMs = 0L

    /// P1 用户面驻留策略档位（ResidencyPolicy.Strategy 名；null = smart 不入键）。
    @Volatile
    private var residencyStrategy: String? = null

    /// initEngine 监听器缓存（Fix2 重绑幂等：bind 重放配置复用同一监听器实例，
    /// :engine 侧 initEngine 本就重设 listener + 幂等）。
    @Volatile
    private var engineListener: IOnDeviceEngineListener? = null

    /// 驻留策略位 Bundle 单源：onServiceConnected 握手与 bind 重放共用。
    private fun residencyInitConfig(): Bundle = Bundle().apply {
        if (residencyTtlMs > 0) {
            putLong(com.zzh.goodhub.engine.EngineLifecycle.KEY_RESIDENCY_TTL_MS, residencyTtlMs)
        }
        residencyStrategy?.takeIf { it.isNotBlank() }?.let {
            putString(com.zzh.goodhub.engine.EngineLifecycle.KEY_RESIDENCY_STRATEGY, it)
        }
    }

    /// 回调统一 post 主线程再 invokeMethod——否则每次回调抛 RuntimeException
    /// 消息全丢（真机实测：生成已跑完，Dart 永远收不到 token/finished → 无结果）。
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun invokeOnMain(method: String, args: Any?) {
        mainHandler.post { channel?.invokeMethod(method, args) }
    }

    fun register(activity: Activity, messenger: BinaryMessenger) {
        // 诊断留痕：MissingPluginException 排查（21:02 真机新进程 checkStatus
        // 报通道未挂载）——确认 register 是否被调、宿主是谁。
        Log.i(TAG, "register: host=${activity.javaClass.simpleName}")
        // S3-2：前台态追踪（Application 级注册一次，覆盖全部 Activity）。
        if (!lifecycleRegistered) {
            activity.application.registerActivityLifecycleCallbacks(foregroundTracker)
            lifecycleRegistered = true
        }
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                handleMethodCall(activity, call, result)
            } catch (e: Exception) {
                // 兜底 reply（S2-5 实证）：handler 内未捕获异常（如 :engine 死后的
                // DeadObjectException）不 reply 时，Dart 侧 MethodChannel 统一抛
                // MissingPluginException「No implementation found」——把 binder 中断
                // 伪造成通道未挂载，误导排查三轮。此处一律显式 error 收口。
                Log.w(TAG, "[DEGRADE] ${call.method} handler threw: $e")
                // :engine 进程死亡（binder 尸体）→ 主动解绑旧连接，后续 bind
                // 可重建；否则 AMS 退避期间（可达 ~11min）所有请求反复撞死代理。
                if (e is android.os.DeadObjectException) {
                    runCatching { unbind(activity) }
                }
                runCatching { result.error("engine_binder_error", "${e.javaClass.simpleName}: ${e.message}", null) }
            }
        }
    }

    private fun handleMethodCall(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
                // M-B 受理期保活（三钥匙释放的机械承载；防抖由 Dart 侧只在冷
                // 装载窗口调用）。任一键在途即持锁，全释放才松——15min 超时
                // 是键泄漏的最后防线，非正常释放路径。
                "keepaliveAcquire" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrEmpty()) {
                        result.error("bad_args", "keepaliveAcquire 缺 key", null)
                    } else {
                        keepaliveKeys.add(key)
                        if (keepaliveWakeLock?.isHeld != true) {
                            val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
                            keepaliveWakeLock = pm.newWakeLock(
                                PowerManager.PARTIAL_WAKE_LOCK, "goodhub:ai-acceptance"
                            ).apply {
                                setReferenceCounted(false)
                                acquire(KEEPALIVE_TIMEOUT_MS)
                            }
                            Log.d(TAG, "ai-keepalive acquired (${keepaliveKeys.size} keys)")
                        }
                        result.success(null)
                    }
                }
                "keepaliveRelease" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrEmpty()) {
                        result.error("bad_args", "keepaliveRelease 缺 key", null)
                    } else {
                        keepaliveKeys.remove(key)
                        if (keepaliveKeys.isEmpty()) {
                            runCatching { keepaliveWakeLock?.takeIf { it.isHeld }?.release() }
                            keepaliveWakeLock = null
                            Log.d(TAG, "ai-keepalive released (all keys gone)")
                        }
                        result.success(null)
                    }
                }
                // 熔断 armed/disarm 演进（对照 IRIDIS，2026-11-06）：系统权威退出
                // 理由（ApplicationExitInfo，API 30+）——精确区分真崩溃
                //（REASON_CRASH*/ANR）与 LMK 处决（REASON_LOW_MEMORY），细化
                // 墓碑排除法的 runtimeTerminated 模糊带（FLAG_READY 无栈死亡）。
                // <30 无此 API → 返回空串（调用方维持墓碑裁定原判）。
                "engineExitReason" -> {
                    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) {
                        result.success("")
                    } else {
                        runCatching {
                            val am = activity.getSystemService(android.app.ActivityManager::class.java)
                            val infos = am.getHistoricalProcessExitReasons(
                                "${activity.packageName}:engine", 0, 1)
                            if (infos.isEmpty()) ""
                            else {
                                val info = infos[0]
                                // reason 名 + 附加状态（SIGKILL 时 description 带信号号）。
                                "${info.reason}|${info.description ?: ""}"
                            }
                        }.onSuccess { result.success(it) }
                            .onFailure { result.success("") } // 查询失败 = 无增量证据，维持墓碑原判
                    }
                }
                "bind" -> {
                    // R-P0/P1 驻留策略位（on-device-residency S-R0-a + P1 用户面）：
                    // TTL/档位随 bind 下发（键缺失 = 复位缺省，零行为变化）。已连接
                    // 时就地重跑 initEngine（幂等）——设置页切档后 warmup() 重放即席
                    // 生效，未连接则随下次握手生效（residencyInitConfig 单源）。
                    residencyTtlMs = (call.argument<Any>("residencyTtlMs") as? Number)?.toLong() ?: 0L
                    residencyStrategy = call.argument<Any>("residencyStrategy") as? String
                    bind(activity)
                    (engine)?.let { svc ->
                        engineListener?.let { l ->
                            try {
                                val status = svc.initEngine(residencyInitConfig(), l)
                                Log.i(TAG, "initEngine(replay) -> EngineStatus ordinal=$status")
                            } catch (e: Exception) {
                                Log.w(TAG, "[DEGRADE] initEngine(replay) failed: $e")
                            }
                        }
                    }
                    result.success(null)
                }
                "unbind" -> {
                    unbind(activity)
                    result.success(null)
                }
                // S1-5 起承载 generate/cancel/status；S2 正式接线起承载 loadModel。
                // M4 Contract：checkStatus 轮询面已退役（状态唯一来源 = checkSession
                // 票据面），此处不再受理 checkStatus 调用（Dart 侧同步移除）。
                // S2 正式接线：模型装载转发（:engine 后台线程建 Genie 会话，
                // 幂等；立即返回 EngineStatus 序数，创建异步进行）。
                "loadModel" -> {
                    val svc = engine
                    val args = call.arguments
                    if (svc == null) {
                        result.error("not_bound", ":engine not connected", null)
                    } else if (args is Map<*, *>) {
                        // M2 §2.5：Dart 传 map{modelDir, modelId, backendHint}
                        //（资产身份经 Dart 资产面单点计算，票据回显承载 I3 对账；
                        // backendHint = 准入探针后端选择权注入，空 = Runner 自裁）。
                        result.success(
                            svc.loadModel(
                                args["modelDir"] as? String,
                                args["modelId"] as? String,
                                args["backendHint"] as? String ?: "",
                            )
                        )
                    } else {
                        // 兼容旧字符串形态（纯目录名）。
                        @Suppress("UNCHECKED_CAST")
                        result.success(svc.loadModel(args as? String, null, ""))
                    }
                }
                // M1 Expand：会话票据查询（设计 §2.2）——与 checkStatus 并存，
                // 主进程侧仅作影子对账（不参与判定）。
                "checkSession" -> {
                    val svc = engine
                    if (svc == null) {
                        result.error("not_bound", ":engine not connected", null)
                    } else {
                        // Bundle 缝唯一收口：经 SessionTicketWire 转 Map 回传
                        // （Bundle 非 MethodChannel 标准编解码类型，直传必炸
                        // engine_binder_error——2026-10-31 门禁/对账双失效事故）。
                        result.success(SessionTicketWire.ticketChannelMap(svc.checkSession()))
                    }
                }
                // S1-5：生成控制转发（参数 → AIDL generationParams Bundle）。
                "startGenerate" -> {
                    val svc = engine
                    val args = call.arguments as? Map<*, *>
                    if (svc == null || args == null) {
                        result.error("not_bound", ":engine not connected", null)
                    } else {
                        try {
                            // S3-3 单执行槽语义（§6.6；打断术语 S14e 订正）：前台态
                            // 由主进程判定注入（Activity started 计数）——前台=可请求
                            // 协作式打断让槽（打断非抢占式；窗口耗尽按策略性降级切云），
                            // 后台=忙即 ServiceBusy 驳回切云。
                            // Bundle 缝收口：Map→参数→Bundle 均经 GenerationParams
                            //（缺省值/键名单源，禁缝外手工逐键）。
                            val params = GenerationParams.fromArgs(
                                args,
                                foreground = foregroundActivities > 0,
                            ).toBundle()
                            svc.startGenerate(
                                args["requestId"] as? String,
                                args["promptJson"] as? String,
                                params,
                                args["expectInstanceId"] as? String,
                                (args["expectSeq"] as? Number)?.toLong() ?: -1L,
                                args["expectModelId"] as? String,
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            // S3-3：service_busy（策略 B 驳回 / 协作式打断未生效）
                            // 单独分码，Dart 侧识别后快速失败切云；AIDL RuntimeException
                            // 类型不保真，以 message 前缀机器判别。M3（设计 §2.2）：
                            // SESSION_EPOCH_MISMATCH / SESSION_LOADING 单独分码——
                            // 主进程作废镜像走装载后重试，不再当 start_rejected
                            // 用户报错（2026-10-31 会话未就绪事故的契约化收口）。
                            // 其余（数据面未建等）维持 start_rejected 语义。
                            val msg = e.message ?: ""
                            when {
                                msg.startsWith("SESSION_EPOCH_MISMATCH") ->
                                    result.error("session_epoch_mismatch", msg, null)
                                msg.startsWith("SESSION_MODEL_MISMATCH") ->
                                    // F2（2026-10-31 ADR）：资产身份失配分码——主进程
                                    // 作废镜像走重装（S2 机制化收口，禁再靠 epoch 兜底）。
                                    result.error("session_model_mismatch", msg, null)
                                msg.startsWith("SESSION_LOADING") ->
                                    result.error("session_loading", msg, null)
                                msg.startsWith(ServiceBusyException.MESSAGE_PREFIX) ->
                                    result.error("service_busy", msg, null)
                                else -> result.error("start_rejected", msg, null)
                            }
                        }
                    }
                }
                "cancelGenerate" -> {
                    val svc = engine
                    if (svc == null) {
                        result.success(null) // 未绑定无生成可取消
                    } else {
                        svc.cancelGenerate(call.arguments as? String)
                        result.success(null)
                    }
                }
                // §4.1 主动回收 → COLD-EVICTED（AIDL releaseEngine）：
                // :engine 侧 abort 在途生成后经 lifecycle.onRelease 单源驱动释放
                //（作废旧 TTL 定时器 + 与 TTL/trim/护栏驱逐同一条 onEvict 路径）。
                // **桥面必须接线**——Dart 侧 release() 经 MethodChannel 调本方法，
                // 漏接即恒落 notImplemented()（MissingPluginException 穿透无人
                // 监听的 unawaited future → root zone 未捕获异常；2026-10-30 审计
                // P0-1 实证：每次退后台一个）。
                // 释放后 checkStatus 回落 assetMissing，重新可用须 loadModel
                //（资产在盘，二次暖机秒级不重下载）。
                "releaseEngine" -> {
                    val svc = engine
                    if (svc == null) {
                        result.success(null) // 未绑定：无权重可释放
                    } else {
                        try {
                            svc.releaseEngine()
                            result.success(null)
                        } catch (e: Exception) {
                            if (e is android.os.DeadObjectException) {
                                runCatching { unbind(activity) }
                            }
                            result.error(
                                "engine_binder_error",
                                "${e.javaClass.simpleName}: ${e.message}",
                                null,
                            )
                        }
                    }
                }
                // §2.4 KV 前缀回滚（keepTokens=0 等价旧 resetContext）。
                // 与 releaseEngine 同一漏接缺口；:engine 侧为 no-op（Genie 无部分
                // 回滚 API），但通道必须通，否则 Dart 侧抛 MissingPluginException
                // （truncateContext 只 catch PlatformException，会穿透上抛）。
                "truncateContext" -> {
                    val svc = engine
                    val keep = (call.arguments as? Number)?.toInt() ?: 0
                    if (svc == null) {
                        result.success(null) // 未绑定：无会话可回滚
                    } else {
                        try {
                            svc.truncateContext(keep)
                            result.success(null)
                        } catch (e: Exception) {
                            if (e is android.os.DeadObjectException) {
                                runCatching { unbind(activity) }
                            }
                            result.error(
                                "engine_binder_error",
                                "${e.javaClass.simpleName}: ${e.message}",
                                null,
                            )
                        }
                    }
                }
                // S2-2 OTA 资产分发（NPU 稿 §4.6/§4.8）：磁盘门禁余量与
                // 驱动指纹（三要素之 Build.FINGERPRINT；Qnn_Version_t/Skel
                // 版本待 SDK 头文件接入后并入同指纹串）。
                "freeDiskSpace" -> {
                    val stat = StatFs(activity.filesDir.path)
                    result.success(stat.availableBytes)
                }
                "deviceFingerprint" -> result.success(Build.FINGERPRINT)
                // Hexagon 架构代际（运行库增配通道键，2026-11-02 三下载点拍板）：
                // SM8550→73 / 8650→75 / 8750→79 / 8850→81；null = 非高通/不支持。
                "hexagonArch" -> result.success(GenieXRuntime.hexagonArch())
                // S2-5 熔断验证 diagPanic PATCH 已退役（F5 清账 2026-10-31）。
                // S3-2 FGS 前台预挂（§6.2 v2.7）：前台态闸在此判定——前台才
                // 转发 :engine startForeground(dataSync)；已退后台则跳过留痕
                //（严禁后台补救，此处跳过 = 放弃本轮 OEM 冻结防御，不阻断生成）。
                "promoteForeground" -> {
                    val svc = engine
                    if (svc == null) {
                        result.success(null) // 未绑定无生成可保活，静默
                    } else if (foregroundActivities > 0) {
                        try {
                            svc.promoteForeground()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("promote_rejected", e.message, null)
                        }
                    } else {
                        Log.w(TAG, "[DEGRADE] promoteForeground skipped: app in background " +
                            "(FGS 时序硬约束：禁后台补救，退靠 BIND_IMPORTANT 梯队 + §4.1)")
                        result.success(null)
                    }
                }
                // S3-6 数据面消费 worker 启动（NPU 稿 §6.4 v3.1 UDS 化）：Dart 传
                // NativePort + initializeApiDLData 指针；本侧经 AIDL 取数据面
                // socket 读端（detachFd 移交所有权给 native），JNI 驱动 libgdw
                // 消费线程。
                "startDataWorker" -> {
                    val svc = engine
                    val args = call.arguments as? Map<*, *>
                    if (svc == null || args == null) {
                        result.error("not_bound", ":engine not connected", null)
                    } else if (dataPlaneWorkerHandle != 0L &&
                        GdwNative.isAlive(dataPlaneWorkerHandle)
                    ) {
                        result.success(null) // 已在运行（幂等）
                    } else {
                        // **幂等短路必须判活**：消费线程可能已退出（pipe 写端消失
                        // → EPOLLHUP / epoll 错误），句柄仍在但线程已死——旧短路
                        // 把「数据面死」当「数据面活」，后续生成必撞 ring 满 →
                        // 误判消费端失速（ipc deadlock）→ 反复切云且数据面永不
                        // 重建。先收旧（停线程 + 释放映射）再重建。
                        if (dataPlaneWorkerHandle != 0L) {
                            Log.w(
                                TAG,
                                "[DEGRADE] data worker thread dead (handle=" +
                                    "$dataPlaneWorkerHandle) → rebuild data plane consumer",
                            )
                            stopDataPlane()
                        }
                        try {
                            val port = (args["port"] as? Number)?.toLong() ?: 0L
                            val api = (args["api"] as? Number)?.toLong() ?: 0L
                            GdwNative.initApi(api)
                            val sock = svc.getDataSocketFd()
                            val handle = GdwNative.start(port, sock.detachFd())
                            // start 成功返回 Worker* 指针（Android 64 位 tagged
                            // heap 指针高位 0xB4…，转有符号 jlong **恒为负**）；
                            // 失败**恒返回 0**。故判定只能是 `!= 0L`——
                            // 判 >0 会把成功误判失败，把负值当错误码则会把失败
                            // 误判成功（→ 后续 stop 解引用负码 = 主进程 SEGV）。
                            if (handle != 0L) {
                                dataPlaneWorkerHandle = handle
                                result.success(null)
                            } else {
                                // 失败路径 sockFd 所有权已由 native 回收。
                                // message 附诊断线索：分类码 + errno（区分瞬时抖动
                                // EAGAIN 与持久资源不足 ENOMEM / 线程数触顶）+
                                // JVM 线程数/空闲内存（dataPlaneDiag）。
                                result.error(
                                    "worker_start_failed",
                                    "code=${GdwNative.lastError()} " +
                                        "errno=${GdwNative.lastErrno()} ${dataPlaneDiag()}",
                                    null,
                                )
                            }
                        } catch (e: Exception) {
                            result.error("worker_start_failed", e.message, null)
                        }
                    }
                }
                // S3-6 停止消费 worker（unbind/release 前置；幂等）。
                "stopDataWorker" -> {
                    stopDataPlane()
                    result.success(null)
                }
                // 装载收尾：归还模型分片页缓存（posix_fadvise + DONTNEED，经
                // libgdw native 通道——:engine 不加载 libgdw；页缓存按 inode
                // 记账，主进程丢弃等价有效）。**仅削装载后的稳态恢复，削不平
                // 装载瞬态尖峰**（边界见 native 侧注释）。
                "dropShardCache" -> {
                    val dir = call.arguments as? String
                    if (dir.isNullOrEmpty()) {
                        result.error("bad_args", "dir required", null)
                    } else {
                        try {
                            val shards = java.io.File(dir).listFiles { f ->
                                f.isFile && f.length() > 64L * 1024 * 1024
                            }
                            var dropped = 0
                            var failed = 0
                            shards?.forEach { f ->
                                val rc = GdwNative.dropFileCache(f.absolutePath)
                                if (rc == 0) dropped++ else failed++
                            }
                            Log.i(TAG, "dropShardCache: dropped=$dropped failed=$failed dir=$dir")
                            result.success(mapOf("dropped" to dropped, "failed" to failed))
                        } catch (e: Exception) {
                            result.error("drop_cache_failed", e.message, null)
                        }
                    }
                }
                // 前台态判定（S3-2 tracker 同一口径）：场景 A/B/C 切云语义拆分
                // 需要「本轮触发是否来自前台」——后台冷装载（场景 B）不切云、
                // 打 PendingForegroundLoad 暂存等前台；前台冷装载（场景 C）
                // 显式失败或按需降级云端。
                "isForeground" -> {
                    result.success(foregroundActivities > 0)
                }
                else -> result.notImplemented()
        }
    }

    fun bind(context: Context) {
        // Fix2 兜底重绑：幂等判据 = **活引擎**（engine != null），非「是否发起
        // 过绑定」——旧判据（connection != null）在 :engine 进程被外部处决 /
        // 自杀重启（Fix1 重载纪律）后恒为真 → bind() 永久 no-op → 引擎再也
        // 接不回来（恢复链路只剩 AMS 自动重启一条腿，其退避可达 ~11min），
        // 端侧静默永久失效、请求静默切云。断连后本方法即时重新发起
        // bindService；连接对象缓存复用（重绑复用同一 ServiceConnection，
        // Android 按 (Context, connection) 复用 ServiceDispatcher，不产生
        // 第二套回调）。
        if (engine != null) return
        // 绑定上下文统一 applicationContext（见 [bindContext] 注释——zombie
        // 绑定死锁的根治）。重绑前先按同一上下文解绑历史绑定（防御性：
        // 旧版本 Activity-context 绑定升级残留时亦能干净回收）。
        val appCtx = context.applicationContext
        val conn =
            connection ?: newServiceConnection().also { connection = it }
        bindContext?.let {
            runCatching { it.unbindService(conn) }
                .onFailure { e -> Log.w(TAG, "[DEGRADE] pre-rebind unbind: $e") }
        }
        bindContext = appCtx
        reissueBind(appCtx)
    }

    /// 重绑执行体（Fix2）：对缓存连接重新发起 bindService。
    private fun reissueBind(context: Context) {
        val conn = connection ?: return
        // 提权旗标（S2-5 对账实证 2026-10-30）：BIND_IMPORTANT 让 :engine 重要性
        // 不低于客户端（跟随主进程 adj 0，装载风暴中同为最后击杀档）。
        // **禁加 BIND_ABOVE_CLIENT**——真机实证它把客户端打上 hasAboveClient
        // 标记，ColorOS 将前台主进程 adj 由 curRaw=0 压成 VISIBLE(100)，装载
        // 风暴中主进程先被 LMK 击杀（=用户感知闪退），:engine 随失联跌回
        // cached(905) 双双被杀；demo（无任何绑定）同场景 adj=0 存活。
        val ok = try {
            context.bindService(
                Intent(context, EngineService::class.java),
                conn,
                Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT,
            )
        } catch (e: Exception) {
            Log.w(TAG, "[DEGRADE] bindService :engine threw: $e")
            false
        }
        if (!ok) {
            Log.e(TAG, "[DEGRADE] bindService :engine failed")
        }
    }

    /// 连接对象工厂（Fix2）：ServiceConnection 创建一次缓存复用——重绑不重建
    /// 回调面（多次 onServiceConnected 幂等：重设 engine 代理 + 重跑 initEngine）。
    private fun newServiceConnection(): ServiceConnection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                val svc = IOnDeviceEngineService.Stub.asInterface(binder)
                engine = svc
                Log.d(TAG, "engine service connected (AIDL proxy)")
                try {
                    // R-P0/P1：驻留策略位随握手下发（键缺失 = 缺省零变化）。
                    val listener = object : IOnDeviceEngineListener.Stub() {
                        override fun onLoadPhaseChanged(phase: Int) {
                            // F4 装载阶段活体打点：诊断面上行（阶段推进 = 活体信号）。
                            invokeOnMain("onLoadPhaseChanged", mapOf("phase" to phase))
                        }

                        override fun onLivenessTick() {
                            // W3-4 引擎存活打点（timeout-signaling）：oneway 单向
                            // 上行，主进程消费 = 重置无进展看门狗（数据流空档防误判）。
                            invokeOnMain("onLivenessTick", null)
                        }

                        override fun onEngineDied() {
                            Log.w(TAG, "[DEGRADE] engine reported onEngineDied: cloud fallback wiring pending S1-5")
                            invokeOnMain("onEngineDied", null)
                        }

                        override fun onIpcDeadlock() {
                            // S3-6 IPC 死锁切云沿（§6.3）：:engine 已 abort 在途
                            // 并关闭数据面（EOF 通知对端）；Dart 侧按 EngineDiedException
                            // 切云（不计熔断，仅冷却窗口）。
                            //
                            // **死锁现场诊断（S2-5 真机实证）**：消费端活性 + 排空
                            // 计数 + 投递字节——三值定位「消费端没排空（线程死/映射
                            // 错/唤醒断）」vs「排空但投不出去（端口关）」vs「排空
                            // 正常但写者看不到进度（游标地址语义错配）」。
                            val h = dataPlaneWorkerHandle
                            Log.w(
                                TAG,
                                "[DIAG] ipc deadlock: workerAlive=${h != 0L && GdwNative.isAlive(h)} " +
                                    "handle=$h drainCount=${GdwNative.lastDrainCount()} " +
                                    "postedBytes=${GdwNative.lastPostedBytes()}",
                            )
                            invokeOnMain("onIpcDeadlock", null)
                        }

                        override fun onGenerateFinished(requestId: String?, finishReason: Int) {
                            invokeOnMain(
                                "onGenerateFinished",
                                mapOf("requestId" to (requestId ?: ""), "finishReason" to finishReason),
                            )
                        }


                        // P0-3：:engine **自发**驱逐（TTL / trim / 护栏 /
                        // 主动 release）上行。数据面随会话一同析构（pipe 写端
                        // 关闭 → native worker 收 EPOLLHUP 终态退出），故此处主动
                        // 停消费端并清句柄——否则 `dataPlaneWorkerHandle != 0`
                        // 的幂等短路会拦掉下一次 startDataWorker，数据面死而
                        // 无人重建（审计 P0-3 的第二半）。
                        override fun onEngineEvicted(reason: String?, evictingRequestId: String?) {
                            stopDataPlane()
                            // M2 §2.8：reason + 在途打断信息（requestId 非空 =
                            // 驱逐打断了在途生成）一并上行，Dart 侧对被中断流
                            // SESSION_ABORTED_BY_EVICTION 收口，不再靠数据面
                            // EOF 间接收口（丢归因）。
                            invokeOnMain("onEngineEvicted", mapOf(
                                "reason" to (reason ?: "unknown"),
                                "evictingRequestId" to evictingRequestId,
                            ))
                        }
                    }
                    engineListener = listener
                    val status = svc.initEngine(residencyInitConfig(), listener)
                    Log.i(TAG, "initEngine -> EngineStatus ordinal=$status")
                    // S2 正式接线：ready 事件 = bind 时序竞态的收口点——
                    // onServiceConnected 内 initEngine 同步完成即 :engine 控制面
                    // 就绪；Dart 侧 waitReady 由此解除挂起（取代固定 sleep）。
                    // initEngine 失败路径不发（Dart 侧以超时 DEGRADE 收口）。
                    channel?.invokeMethod("onEngineReady", status)
                } catch (e: Exception) {
                    // initEngine 失败不等价熔断（§6.5 口径）：后端未接入/远端抛错，
                    // 主进程保持云端默认通路，DEGRADE 留痕。
                    Log.w(TAG, "[DEGRADE] initEngine remote call failed: $e")
                    engine = null
                }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                // §6.5：进程死亡 → 主进程 EngineDiedException 切云。外部处决
                //（OEM SIGKILL / LMK）**不计入熔断计数**（§6.5 v2.6 收窄口径），
                // 但仍维护 500ms 冷却窗口；计数与冷却归 Dart 侧熔断器（S1-6）。
                engine = null
                // S3-6：:engine 死 → 其数据面（共享内存/pipe）随进程消失，
                // 消费 worker 立即停（Dart 侧下次 generate 经 onEngineReady
                // 重建）。
                stopDataPlane()
                Log.w(TAG, "[DEGRADE] engine process died: cloud fallback wiring pending S1-5")
                invokeOnMain("onProcessDied", null)
                // Fix2：**不在此清 connection**——连接对象须保留供 bind() 重绑
                // 复用（断连 ≠ 客户端解绑，ServiceDispatcher 仍在）；重绑判据
                // 已由 engine != null 承担。清了它会让下一次 bind() 走全新连接
                // （多一套回调，且 unbind 收口对不上）。
            }
        }

    fun unbind(context: Context) {
        // S3-6：解绑前先停数据面消费 worker（fd/映射属 :engine 数据面）。
        stopDataPlane()
        connection?.let {
            // 记账分叉修复（2026-11-02 真机定谳）：unbind 必须与 bind 同
            // 上下文（framework 要求，否则 IAE）；且**仅在解绑成功时清引用**——
            // 旧代码 IAE 被吞后仍清 connection/engine，框架里绑定变 zombie
            // 而 bridge 失忆，后续重绑全乱（ServiceConnectionLeaked 死锁链
            // 第二环）。失败保留引用 → 下次 bind 走同上下文重绑（幂等）。
            val ok = bindContext?.let { ctx ->
                try {
                    ctx.unbindService(it)
                    true
                } catch (e: IllegalArgumentException) {
                    Log.w(TAG, "unbind without active binding: $e")
                    false
                }
            } ?: true
            if (ok) {
                connection = null
                engine = null
                bindContext = null
            }
        }
    }
}
