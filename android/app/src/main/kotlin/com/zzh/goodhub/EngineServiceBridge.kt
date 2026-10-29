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
import android.os.StatFs
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// 端侧引擎绑定桥（on-device epic S1-2）：主进程侧对 `:engine` 的唯一绑定 owner。
///
/// 绑定旗标按 on-device-npu-deployment.md §6.2 硬约束：
/// `Context.BIND_AUTO_CREATE | Context.BIND_IMPORTANT`——使 `:engine` 的 oom_adj
/// 与主应用同生命周期梯队，避免无前台依附时被 LMK 优先强杀；由单例 ServiceConnection
/// 常驻持有，避免反复 rebind 抖动。
///
/// S1-2：onServiceConnected 拿到的 Binder 经 AIDL Stub 声明为
/// `IOnDeviceEngineService` 跨进程代理，并立即 `initEngine`（携带 listener 承载
/// `onEngineDied` 回调，经 MethodChannel 反投 Dart）；生成/数据面归 S1-3/S1-5。
object EngineServiceBridge {
    private const val CHANNEL = "goodhub/on_device_engine"
    private const val TAG = "EngineServiceBridge"

    private var channel: MethodChannel? = null
    private var connection: ServiceConnection? = null
    private var engine: IOnDeviceEngineService? = null

    // S3-6 数据面消费 worker（NPU 稿 §6.4）状态（主进程单实例）：
    // handle = native worker 句柄（GdwNative.start 返回，0 = 未运行）；
    // buffer = SharedMemory.mapReadOnly() 直接 ByteBuffer——native 侧映射
    // 生命周期锚（stop 时 SharedMemory.unmap 释放，防 :engine 重建数据面
    // 后旧映射悬挂）。
    @Volatile
    private var dataPlaneWorkerHandle = 0L
    @Volatile
    private var dataPlaneBuffer: java.nio.ByteBuffer? = null

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
        dataPlaneBuffer?.let { runCatching { android.os.SharedMemory.unmap(it) } }
        dataPlaneBuffer = null
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
        activity.application.registerActivityLifecycleCallbacks(foregroundTracker)
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
                "bind" -> {
                    bind(activity)
                    result.success(null)
                }
                "unbind" -> {
                    unbind(activity)
                    result.success(null)
                }
                // S1-5 起承载 generate/cancel/status；S2 正式接线起承载 loadModel。
                "checkStatus" -> {
                    val svc = engine
                    if (svc == null) {
                        result.error("not_bound", ":engine not connected", null)
                    } else {
                        result.success(svc.checkStatus())
                    }
                }
                // S2 正式接线：模型装载转发（:engine 后台线程建 Genie 会话，
                // 幂等；立即返回 EngineStatus 序数，创建异步进行）。
                "loadModel" -> {
                    val svc = engine
                    if (svc == null) {
                        result.error("not_bound", ":engine not connected", null)
                    } else {
                        result.success(svc.loadModel(call.arguments as? String))
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
                            val params = Bundle().apply {
                                putInt("maxTokens", (args["maxTokens"] as? Number)?.toInt() ?: 512)
                                putDouble("temperature", (args["temperature"] as? Number)?.toDouble() ?: 0.7)
                                putDouble("topP", (args["topP"] as? Number)?.toDouble() ?: 0.9)
                                putIntArray(
                                    "stopTokenIds",
                                    (args["stopTokenIds"] as? List<*>)?.map { (it as Number).toInt() }?.toIntArray()
                                        ?: IntArray(0),
                                )
                                // S3-3 抢占语义（§6.6）：前台态由主进程判定注入
                                //（Activity started 计数）——前台=可抢占让槽
                                //（绝不驳回用户），后台=忙即 ServiceBusy 驳回切云。
                                putBoolean("foreground", foregroundActivities > 0)
                            }
                            svc.startGenerate(
                                args["requestId"] as? String,
                                args["promptJson"] as? String,
                                params,
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            // S3-3：service_busy（策略 B 驳回/抢占超时）单独分码，
                            // Dart 侧识别后快速失败切云；AIDL RuntimeException
                            // 类型不保真，以 message 前缀机器判别。其余
                            //（数据面未建等）维持 start_rejected 语义。
                            if (e.message?.startsWith(ServiceBusyException.MESSAGE_PREFIX) == true) {
                                result.error("service_busy", e.message, null)
                            } else {
                                result.error("start_rejected", e.message, null)
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
                // S2-2 OTA 资产分发（NPU 稿 §4.6/§4.8）：磁盘门禁余量与
                // 驱动指纹（三要素之 Build.FINGERPRINT；Qnn_Version_t/Skel
                // 版本待 SDK 头文件接入后并入同指纹串）。
                "freeDiskSpace" -> {
                    val stat = StatFs(activity.filesDir.path)
                    result.success(stat.availableBytes)
                }
                "deviceFingerprint" -> result.success(Build.FINGERPRINT)
                // S2-5 熔断验证（PATCH：诊断接口）：经 AIDL 触发 :engine 侧
                // 模拟驱动 Panic（oneway，不等待远端回执）。
                "diagPanic" -> {
                    val svc = engine
                    if (svc == null) {
                        result.error("not_bound", ":engine not connected", null)
                    } else {
                        svc.diagPanic()
                        result.success(null)
                    }
                }
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
                // S3-6 数据面消费 worker 启动（NPU 稿 §6.4）：Dart 传
                // NativePort + initializeApiDLData 指针 + RingBuffer 容量；
                // 本侧经 AIDL 取 SharedMemory/唤醒 fd（detachFd 移交所有权
                // 给 native），JNI 驱动 libgdw 消费线程。
                "startDataWorker" -> {
                    val svc = engine
                    val args = call.arguments as? Map<*, *>
                    if (svc == null || args == null) {
                        result.error("not_bound", ":engine not connected", null)
                    } else if (dataPlaneWorkerHandle != 0L) {
                        result.success(null) // 已在运行（幂等）
                    } else {
                        try {
                            val port = (args["port"] as? Number)?.toLong() ?: 0L
                            val api = (args["api"] as? Number)?.toLong() ?: 0L
                            val capacity =
                                (args["capacity"] as? Number)?.toInt() ?: 1024
                            GdwNative.initApi(api)
                            val shm = svc.getSharedMemory()
                            val wake = svc.getEventFd()
                            // 必须读写映射：SPSC 消费端要写 read_idx（header+4）——
                            // mapReadOnly 下 native 首次推进 read_idx 即 SEGV_ACCERR
                            // （S2-5 真机实证，fault addr 恒为基址+4）。
                            val buf = shm.mapReadWrite()
                            val handle =
                                GdwNative.start(port, buf, wake.detachFd(), capacity)
                            // start 成功返回 Worker* 指针（Android 64 位 tagged
                            // heap 指针高位 0xB4…，转有符号 jlong 为负）；失败才
                            // 返回 -1~-6。必须判非零，判 >0 会把成功误判为失败。
                            if (handle != 0L) {
                                dataPlaneWorkerHandle = handle
                                dataPlaneBuffer = buf
                                result.success(null)
                            } else {
                                // 失败路径 wakeFd 所有权已由 native 回收。
                                // message 附诊断线索（线程数/空闲内存）便于确认真因。
                                result.error(
                                    "worker_start_failed",
                                    "handle=$handle ${dataPlaneDiag()}",
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
                else -> result.notImplemented()
        }
    }

    fun bind(context: Context) {
        if (connection != null) return
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                val svc = IOnDeviceEngineService.Stub.asInterface(binder)
                engine = svc
                Log.d(TAG, "engine service connected (AIDL proxy)")
                try {
                    val status = svc.initEngine(Bundle(), object : IOnDeviceEngineListener.Stub() {
                        override fun onEngineDied() {
                            Log.w(TAG, "[DEGRADE] engine reported onEngineDied: cloud fallback wiring pending S1-5")
                            invokeOnMain("onEngineDied", null)
                        }

                        override fun onIpcDeadlock() {
                            // S3-6 IPC 死锁切云沿（§6.3）：:engine 已 abort 在途
                            // 并清空 RingBuffer；Dart 侧按 EngineDiedException
                            // 切云（不计熔断，仅冷却窗口）。
                            invokeOnMain("onIpcDeadlock", null)
                        }

                        override fun onGenerateFinished(requestId: String?, finishReason: Int) {
                            invokeOnMain(
                                "onGenerateFinished",
                                mapOf("requestId" to (requestId ?: ""), "finishReason" to finishReason),
                            )
                        }

                        // S3-1 热调度：切云沿透传（:engine 侧 PowerManager
                        // thermal listener 为权威，§5.3 公共 API）。
                        override fun onThermalCutover(active: Boolean) {
                            invokeOnMain("onThermalCutover", active)
                        }
                    })
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
            }
        }
        val ok = context.bindService(
            Intent(context, EngineService::class.java),
            conn,
            Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT,
        )
        if (ok) {
            connection = conn
        } else {
            Log.e(TAG, "[DEGRADE] bindService :engine failed")
        }
    }

    fun unbind(context: Context) {
        // S3-6：解绑前先停数据面消费 worker（fd/映射属 :engine 数据面）。
        stopDataPlane()
        connection?.let {
            try {
                context.unbindService(it)
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "unbind without active binding: $e")
            }
            connection = null
            engine = null
        }
    }
}
