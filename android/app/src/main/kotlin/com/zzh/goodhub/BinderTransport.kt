package com.zzh.goodhub

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Binder
import android.os.DeadObjectException
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.RemoteException
import android.util.Log
import java.security.MessageDigest
import com.zzh.goodhub.mcp.IMcpCallback
import com.zzh.goodhub.mcp.IMcpChannel
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import org.json.JSONArray
import org.json.JSONObject

/**
 * 宿主侧 Binder 传输桥（T-trans-2）：把单个本地插件的 IMcpChannel 客户端封装为
 * 与 HttpTransport 对等的原生实现，经 MethodChannel goodhub/binder_mcp 暴露给 Dart。
 *
 * 对齐 thirdconnect.md §1.2.2 / §1.2.3 / §9.1：
 *  - 连接状态机 IDLE→CONNECTING→READY→DEAD + 挂起请求队列（PendingRequestQueue）；
 *  - bindService 纯异步冷启动竞态：首个 send 触发连接，CONNECTING 期间请求入队，不重复 bind；
 *    onServiceConnected 后置 READY 按序排空队列；DEAD→下次 send 自动 rebind(BIND_AUTO_CREATE)；
 *  - 冷启动 5s 超时：CONNECTING 超时才向上抛错（binder_error），不静默吞/不卡线程；
 *  - call 必须在后台线程执行（主线程同步 call 超 5s 触发 ANR，§1.2.3）；
 *  - DeathRecipient 感知崩溃：binderDied → DEAD，下次调用自动 rebind；
 *  - Binder 断连(DeadObject/Remote) 映射为 binder_error PlatformException 上抛 Dart，
 *    不伪装成 JSON-RPC error 帧（§1.2.3）；
 *  - registerCallback：bind 完成后、首次 call 前调用一次（§1.2.2）；onEvent 经 EventChannel
 *    透传 Dart（progress/反向请求消费留 T-trans-3）。
 */
object BinderTransportBridge {

    private const val TAG = "BinderTransport"
    private const val CHANNEL = "goodhub/binder_mcp"
    private const val DISCOVERY_CHANNEL = "goodhub/binder_discovery"

    // 发现约定四常量（线级契约，永久冻结）：
    //   SSOT = goodhub-mcp-sdk 仓 :contract 模块的 com.zzh.goodhub.mcp.McpContract
    //   宿主侧副本由 scripts/agent-tools/check-contract-sync.sh 机械校验（golden 指纹 + 与契约仓逐字节比对）
    //   改这里 = 打断存量插件的自动发现；改契约必须先改契约仓。
    private const val DISCOVERY_ACTION = "com.zzh.goodhub.action.MCP_SERVER"
    private const val META_SERVER_ID = "com.zzh.goodhub.SERVER_ID"
    private const val META_SERVER_TITLE = "com.zzh.goodhub.SERVER_TITLE"
    private const val COLD_START_TIMEOUT_MS = 5000L

    private val executor = Executors.newCachedThreadPool()
    private val transports = ConcurrentHashMap<String, HostTransport>()
    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var discoveryChannel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 原生→Dart 事件投递 ACK 回调：Dart 路由表按 transportId 命中才回
    /// `delivered=true`。EventChannel 只能单向无脑发、丢件无感知；
    /// MethodChannel 推挽让原生精确知道帧是否抵达 Dart isolate（消费级
    /// 确认仍由上层 120s 看门狗保证，ACK 只证明「到达路由表」）。
    /// 丢件不静默：debug 留痕（正常路径恒不触发）。
    private val eventAck = object : MethodChannel.Result {
        override fun success(result: Any?) {
            val delivered = result is Map<*, *> && result["delivered"] == true
            if (!delivered) Log.d(TAG, "event dropped (routed miss): $result")
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            Log.d(TAG, "event dropped (dart error): $errorCode $errorMessage")
        }

        override fun notImplemented() {
            Log.d(TAG, "event dropped (no dart handler)")
        }
    }

    /// 本地插件包变更广播（安装/卸载/替换 → 通知 Dart 重扫，§1.2.4）。
    private val packageChangeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_PACKAGE_ADDED,
                Intent.ACTION_PACKAGE_REMOVED,
                Intent.ACTION_PACKAGE_REPLACED,
                -> notifyPluginsChanged()
            }
        }
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        methodChannel = MethodChannel(messenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "bind" -> {
                            val id = call.argument<String>("transportId")!!
                            val pkg = call.argument<String>("packageName")!!
                            val svc = call.argument<String>("serviceClassName")!!
                            bind(id, pkg, svc)
                            result.success(null)
                        }
                        "send" -> {
                            val id = call.argument<String>("transportId")!!
                            val body = call.argument<String>("requestBody")!!
                            send(id, body) { resp, err ->
                                if (err != null) result.error("binder_error", err.message, null)
                                else result.success(resp)
                            }
                        }
                        "answerReverse" -> {
                            val id = call.argument<String>("transportId")!!
                            val body = call.argument<String>("responseBody")!!
                            transports[id]?.answerReverse(body)
                            result.success(null)
                        }
                        "close" -> {
                            val id = call.argument<String>("transportId")!!
                            transports.remove(id)?.close()
                            result.success(null)
                        }
                        "resetAllTransports" -> {
                            // Hot Restart / isolate 重建对齐（#3）：清空上一轮
                            // isolate 遗留的僵尸 Client 与 Callback，原生与 Dart
                            // 状态机对齐。前置条件：全进程仅一个 isolate 创建
                            // BinderTransport（现网事实，多 isolate 场景需先改
                            // 此约定，否则会清掉他 isolate 的连接）。
                            for (t in transports.values) {
                                runCatching { t.close() }
                            }
                            transports.clear()
                            result.success(null)
                        }
                        "discover" -> result.success(scanLocalPlugins())
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    result.error("binder_error", e.message, null)
                }
            }
        }
        // 本地插件发现：Dart 侧拉扫 + 系统包变更通知（§1.2.4）。
        discoveryChannel = MethodChannel(messenger, DISCOVERY_CHANNEL)
        runCatching {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_PACKAGE_ADDED)
                addAction(Intent.ACTION_PACKAGE_REMOVED)
                addAction(Intent.ACTION_PACKAGE_REPLACED)
                addDataScheme("package")
            }
            @Suppress("MissingPermission")
            appContext.registerReceiver(
                packageChangeReceiver, filter, Context.RECEIVER_NOT_EXPORTED,
            )
        }.onFailure { e -> Log.w(TAG, "register package receiver failed: $e") }
    }

    /// 宿主自身签名 SHA-256 集合（判定本地插件是否同签名私有生态，§1.2.6；
    /// 同签名 = 零弹窗自动信任，非同签名第三方需信任卡片白名单）。
    private val ownSignatureSha256: Set<String> by lazy {
        runCatching {
            val pm = appContext.packageManager
            val pi = pm.getPackageInfo(
                appContext.packageName, PackageManager.GET_SIGNING_CERTIFICATES,
            )
            pi.signingInfo?.apkContentsSigners
                ?.mapNotNull { sha256Hex(it.toByteArray()) }
                ?.toSet() ?: emptySet()
        }.getOrDefault(emptySet())
    }

    /// 扫描已安装且声明 [DISCOVERY_ACTION] 的本地插件 Service，读取 meta-data 入目录
    /// （§1.2.4 / §1.2.1）。附带签名 SHA-256 与同签名标记，供信任闸门判定（§1.2.6）。
    /// MATCH_CURRENT_USER 规避跨 User 越界 IPC（§9.4）；失败返空目录（不炸）。
    private fun scanLocalPlugins(): String {
        return try {
            val pm = appContext.packageManager
            val intent = Intent(DISCOVERY_ACTION)
            // 默认即当前 User 空间扫描（§9.4：不附加 MATCH_ALL 等跨 User 标志，规避越界 IPC）。
            val resolved = pm.queryIntentServices(intent, PackageManager.GET_META_DATA)
            val arr = JSONArray()
            for (ri in resolved) {
                val si = ri.serviceInfo ?: continue
                val md = si.metaData ?: continue
                val serverId = md.getString(META_SERVER_ID) ?: continue
                val serverTitle = md.getString(META_SERVER_TITLE) ?: serverId
                val sig = runCatching {
                    val pi = pm.getPackageInfo(si.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                    pi.signingInfo?.apkContentsSigners?.firstOrNull()?.toByteArray()
                }.getOrNull()
                val sha = sig?.let { sha256Hex(it) } ?: ""
                val sameSig = sha.isNotEmpty() && ownSignatureSha256.contains(sha)
                arr.put(JSONObject().apply {
                    put("packageName", si.packageName)
                    put("serviceClassName", si.name)
                    put("serverId", serverId)
                    put("serverTitle", serverTitle)
                    put("signatureSha256", sha)
                    put("sameSignature", sameSig)
                })
            }
            arr.toString()
        } catch (e: Throwable) {
            Log.w(TAG, "scanLocalPlugins failed: $e")
            JSONArray().toString()
        }
    }

    /// 计算字节数组的 SHA-256 十六进制串（插件签名指纹，§1.2.6 信任卡片展示用）。
    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
    }

    /// 包变更 → 经 discovery channel 通知 Dart 重扫（native→Dart；Dart 未就绪时静默丢帧，不阻塞）。
    private fun notifyPluginsChanged() {
        runCatching { discoveryChannel.invokeMethod("onPluginsChanged", null) }
    }

    private fun bind(id: String, pkg: String, svc: String) {
        transports.computeIfAbsent(id) { HostTransport(appContext, id, pkg, svc) }.startBind()
    }

    private fun send(id: String, body: String, cb: (String?, Throwable?) -> Unit) {
        val t = transports[id]
        if (t == null) {
            cb(null, RuntimeException("unknown transport: $id"))
            return
        }
        t.send(body).whenComplete { resp, err ->
            if (err != null) cb(null, err) else cb(resp, null)
        }
    }

    /// 原生→Dart 事件推送（T-trans-3 回程，全量 MethodChannel 推挽化）：
    /// 调用方已在本 transport 的保序专线上，此处转主线程经 MethodChannel
    /// invokeMethod 推给 Dart 路由表（按 transportId 分发），Dart 回 ACK。
    /// 与 EventChannel 的本质区别：无按频道名的全局 handler 状态机——
    /// 多实例 listen/cancel 互不干扰（2026-10-17 卡死根因的根治）。
    ///
    /// [caller] = 平台侧已解析的调用方身份（S07/S07b，可 null = 解析失败）：
    /// 非空时随信封附 `caller` 字段 {packageName, signatureSha256}，Dart 侧
    /// 反向请求据此消费已解析身份（载荷不承载身份，红线）。
    private fun dispatchEvent(tid: String, msg: String, caller: CallerIdentityResolver.CallerIdentity?) {
        mainHandler.post {
            runCatching {
                val payload = mutableMapOf<String, Any?>(
                    "transportId" to tid,
                    "message" to msg,
                )
                if (caller != null) {
                    payload["caller"] = mapOf(
                        "packageName" to caller.packageName,
                        "signatureSha256" to caller.signatureSha256,
                    )
                }
                methodChannel.invokeMethod("onNativeEvent", payload, eventAck)
            }.onFailure { Log.w(TAG, "dispatchEvent failed: $it") }
        }
    }

    /// 连接死亡信封推送（binderDied → Dart 秒级收敛在途，拒绝 120s 干等）。
    private fun dispatchTransportError(tid: String, code: String, message: String) {
        mainHandler.post {
            runCatching {
                methodChannel.invokeMethod(
                    "onTransportError",
                    mapOf(
                        "transportId" to tid,
                        "error" to mapOf("code" to code, "message" to message),
                    ),
                    eventAck,
                )
            }.onFailure { Log.w(TAG, "dispatchTransportError failed: $it") }
        }
    }

    /// 调用方死亡事件推送（**新增链路**，W5 调用方进程死亡联动打断）：
    /// 平台侧为**调用方链路**注册的独立死亡代理触发时推此事件，驱动宿主
    /// 协作式打断该调用方名下在途的端侧执行（K17）。
    ///
    /// 与 [dispatchTransportError] 的死亡信封是**两条独立链路、互不替代**：
    /// - 既有链路（`binderDied` → `onTransportError`）：收敛**宿主 client 在途
    ///   请求**（宿主作客户端感知对端死亡）；
    /// - 本链路（`callerDeathRecipient` → `onCallerDied`）：驱动**反向路径**的
    ///   算力打断（宿主作算力提供方时感知调用方死亡）。
    ///
    /// 红线：既有方向的死亡代理**不覆盖**反向路径，须新增链路而非复用既有
    /// 字段/回调（设计稿 §6「调用方进程死亡须联动打断算力」）。
    ///
    /// [callerKey] = 调用方身份键（目标插件包名，物理主键 §9.3）——必须与
    /// Dart 侧在途执行注册的 callerKey 同源，否则死亡通知匹配不上（漏打断
    /// = 孤儿算力空跑）。
    private fun dispatchCallerDied(tid: String, callerKey: String) {
        mainHandler.post {
            runCatching {
                methodChannel.invokeMethod(
                    "onCallerDied",
                    mapOf(
                        "transportId" to tid,
                        "callerKey" to callerKey,
                    ),
                    eventAck,
                )
            }.onFailure { Log.w(TAG, "dispatchCallerDied failed: $it") }
        }
    }

    private class HostTransport(
        val context: Context,
        val id: String,
        val packageName: String,
        val serviceClassName: String,
    ) {
        enum class State { IDLE, CONNECTING, READY, DEAD }

        @Volatile
        private var state = State.IDLE
        private val lock = Any()
        private var channel: IMcpChannel? = null
        private var connection: ServiceConnection? = null
        private val pending = LinkedBlockingQueue<PendingCall>()

        private data class PendingCall(val body: String, val future: CompletableFuture<String>)

        private val deathRecipient = IBinder.DeathRecipient { markDead() }

        /// 反向路径调用方死亡代理（W5 调用方进程死亡联动打断，**新增链路**）：
        /// 宿主在反向请求链路（宿主作算力提供方、同机插件 App 作调用方）上为
        /// 调用方进程注册的独立死亡代理。
        ///
        /// 与 [deathRecipient] 是**两条独立链路、语义不同、互不替代**：
        /// - [deathRecipient] → [markDead]：宿主 client 在途请求收敛（既有方向
        ///   的死亡代理，宿主作客户端感知对端死亡）；
        /// - 本代理 → [pushCallerDied]：驱动宿主打断该调用方名下在途的端侧执行
        ///   （反向路径，K17）。
        ///
        /// 红线：既有方向的死亡代理不覆盖反向路径——须新增链路而非复用既有
        /// 字段/回调。此处独立注册独立 recipient，物理上不复用既有状态机。
        private val callerDeathRecipient = IBinder.DeathRecipient { pushCallerDied() }

        private val mainHandler = Handler(Looper.getMainLooper())

        /// 事件保序专线（乱序防御）：Binder 回调在系统 Binder 线程池并发执行，
        /// 两个线程各自 `mainHandler.post` 不保序（进度帧可能晚于终帧入主线程
        /// 队列）——单线程串行化后，本 transport 的事件严格按到达顺序 post。
        /// 死亡信封与 JSON-RPC 事件同走此线，保证「终帧 → 死亡」相对有序。
        private val eventExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "binder-events-$id")
        }

        private val callback = object : IMcpCallback.Stub() {
            override fun onEvent(jsonRpcMessage: String) {
                // 透传插件事件到 Dart（progress / 异步终帧 / 反向请求在 Dart 侧完成）。
                // §1.2.3：Binder 线程触发 → 保序专线串行化 → 主线程 MethodChannel 推送。
                // S07/S07b：调用方身份须在本 Binder 事务线程内解析（getCallingUid
                // 仅事务内有效，严禁异步补取），解析结果随事件信封下发。
                val tid = id
                val msg = jsonRpcMessage
                val caller = resolveCallerOnce()
                eventExecutor.execute {
                    dispatchEvent(tid, msg, caller)
                }
            }
        }

        /// 已解析的调用方身份缓存（S07/S07b）：peer 进程身份随本连接固定，解析
        /// 成功一次即缓存（双检锁）；失败**不缓存**（PM 瞬时故障下次事件重试），
        /// 持续失败时每事件回 null → Dart 侧对反向请求按拒绝处置（禁匿名放行）。
        ///
        /// 红线：身份只从内核调用方 UID 推导（[CallerIdentityResolver] 单源），
        /// 严禁从请求载荷或 transport 元数据读取（载荷自声明即允许冒充任意包名）。
        @Volatile
        private var resolvedCaller: CallerIdentityResolver.CallerIdentity? = null

        /// 解析调用方身份（成功缓存，失败不缓存）：必须在 onEvent（Binder 事务
        /// 线程）内调用 [Binder.getCallingUid]。
        private fun resolveCallerOnce(): CallerIdentityResolver.CallerIdentity? {
            resolvedCaller?.let { return it }
            synchronized(lock) {
                resolvedCaller?.let { return it }
                val identity = CallerIdentityResolver.resolve(context, Binder.getCallingUid())
                if (identity != null) resolvedCaller = identity
                return identity
            }
        }

        /// 推送连接死亡信封（binderDied → Dart 秒级收敛在途）：`_async` 占位后
        /// 干等终帧的调用拒绝 120s 看门狗兜底。与 D18 断连语义合流
        /// （connection_manager 预留的 DeathRecipient 显式驱动位）。
        private fun pushTransportDied() {
            val tid = id
            eventExecutor.execute {
                dispatchTransportError(
                    tid,
                    "SERVER_DIED",
                    "remote MCP server process terminated",
                )
            }
        }

        /// 推送调用方死亡事件（**新增链路**，W5 调用方进程死亡联动打断）：
        /// 独立死亡代理 [callerDeathRecipient] 触发 → 通知 Dart 打断该调用方
        /// 名下在途的端侧执行（宿主侧协作式打断 + 作废本次调用，K17）。
        ///
        /// **不复用既有死亡信封**（`onTransportError`）：既有链路的终态是
        /// 「宿主 client 在途请求失败」，与「宿主在途算力执行被打断」是两种
        /// 语义，分派到不同消费面。
        private fun pushCallerDied() {
            val tid = id
            val callerKey = packageName
            eventExecutor.execute {
                dispatchCallerDied(tid, callerKey)
            }
        }

        fun startBind() {
            synchronized(lock) {
                if (state == State.READY || state == State.CONNECTING) return
                state = State.CONNECTING
            }
            val intent = Intent().setClassName(packageName, serviceClassName)
            val conn = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, rawBinder: IBinder?) {
                    val ch = IMcpChannel.Stub.asInterface(rawBinder)
                    try {
                        rawBinder?.linkToDeath(deathRecipient, 0)
                        // 新增链路（K17 调用方进程死亡联动打断）：为反向请求链路
                        // 的调用方进程注册**独立**死亡代理——既有 recipient 服务
                        // 「宿主 client 在途收敛」，本 recipient 服务「宿主在途
                        // 端侧执行打断」，两条链路互不替代。
                        rawBinder?.linkToDeath(callerDeathRecipient, 0)
                    } catch (_: Throwable) {
                    }
                    synchronized(lock) {
                        channel = ch
                        state = State.READY
                    }
                    try {
                        ch?.registerCallback(callback)
                    } catch (e: RemoteException) {
                        Log.w(TAG, "registerCallback failed: $e")
                    }
                    flushPending(ch)
                }

                override fun onServiceDisconnected(name: ComponentName?) {
                    // 系统正常断开（非崩溃）：标记 DEAD，下次 send 自动重连
                    synchronized(lock) {
                        state = State.DEAD
                        channel = null
                    }
                }
            }
            connection = conn
            val ok = runCatching {
                context.bindService(intent, conn, Context.BIND_AUTO_CREATE)
            }.getOrDefault(false)
            if (!ok) {
                synchronized(lock) {
                    state = State.DEAD
                }
                failPending(RuntimeException("bindService failed: $packageName/$serviceClassName"))
                return
            }
            // 冷启动 5s 超时（§9.1）：CONNECTING 超时才抛错，不静默吞/不卡线程
            executor.submit {
                try {
                    Thread.sleep(COLD_START_TIMEOUT_MS)
                } catch (_: InterruptedException) {
                }
                synchronized(lock) {
                    if (state == State.CONNECTING) {
                        state = State.DEAD
                        failPending(
                            RuntimeException("plugin cold-start timeout (${COLD_START_TIMEOUT_MS}ms)")
                        )
                    }
                }
            }
        }

        fun send(body: String): CompletableFuture<String> {
            val future = CompletableFuture<String>()
            synchronized(lock) {
                when (state) {
                    State.READY -> {
                        val ch = channel
                        if (ch == null) {
                            future.completeExceptionally(RuntimeException("no channel"))
                            return future
                        }
                        submitCall(ch, body, future)
                    }

                    State.IDLE, State.DEAD -> {
                        state = State.CONNECTING
                        pending.add(PendingCall(body, future))
                        startBind()
                    }

                    State.CONNECTING -> pending.add(PendingCall(body, future))
                }
            }
            return future
        }

        private fun submitCall(
            ch: IMcpChannel,
            body: String,
            future: CompletableFuture<String>,
        ) {
            executor.submit {
                try {
                    // call 离主线程（§1.2.3：主线程同步 call 超 5s 触发 ANR）
                    val resp = ch.call(body)
                    future.complete(resp)
                } catch (e: DeadObjectException) {
                    markDead()
                    future.completeExceptionally(RuntimeException("plugin died: ${e.message}"))
                } catch (e: RemoteException) {
                    future.completeExceptionally(RuntimeException("binder remote error: ${e.message}"))
                } catch (e: Throwable) {
                    future.completeExceptionally(e)
                }
            }
        }

        private fun flushPending(ch: IMcpChannel?) {
            if (ch == null) return
            while (true) {
                val p = synchronized(lock) { pending.poll() } ?: break
                submitCall(ch, p.body, p.future)
            }
        }

        private fun failPending(e: Throwable) {
            while (true) {
                val p = synchronized(lock) { pending.poll() } ?: break
                p.future.completeExceptionally(e)
            }
        }

        private fun markDead() {
            synchronized(lock) {
                state = State.DEAD
                channel = null
            }
            // ① 排队中的调用秒级失败（不留给冷启动超时兜底）；
            // ② 死亡信封推 Dart：_async 占位后干等终帧的调用秒级收敛。
            //    同步在途的 ch.call 自身会抛 DeadObjectException（submitCall 已
            //    收敛），此处补的正是「占位已回、终帧永不到达」的盲区。
            failPending(RuntimeException("plugin died (binderDied)"))
            pushTransportDied()
        }

        fun answerReverse(body: String) {
            val ch = synchronized(lock) { channel } ?: return
            executor.submit {
                try {
                    ch.answerReverse(body)
                } catch (e: Throwable) {
                    Log.w(TAG, "answerReverse failed: $e")
                }
            }
        }

        fun close() {
            synchronized(lock) {
                connection?.let { runCatching { context.unbindService(it) } }
                connection = null
                channel = null
                state = State.IDLE
                failPending(RuntimeException("transport closed"))
            }
            eventExecutor.shutdown()
        }
    }
}
