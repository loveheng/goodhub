package com.zzh.goodhub

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
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
import io.flutter.plugin.common.EventChannel
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
    private const val EVENTS = "goodhub/binder_mcp_events"
    private const val DISCOVERY_CHANNEL = "goodhub/binder_discovery"
    private const val DISCOVERY_ACTION = "com.zzh.goodhub.action.MCP_SERVER"
    private const val META_SERVER_ID = "com.zzh.goodhub.SERVER_ID"
    private const val META_SERVER_TITLE = "com.zzh.goodhub.SERVER_TITLE"
    private const val COLD_START_TIMEOUT_MS = 5000L

    private val executor = Executors.newCachedThreadPool()
    private val transports = ConcurrentHashMap<String, HostTransport>()
    private val eventSinks = ConcurrentHashMap<String, EventChannel.EventSink>()
    private lateinit var appContext: Context
    private lateinit var discoveryChannel: MethodChannel

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
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
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
                        eventSinks.remove(id)
                        result.success(null)
                    }
                    "discover" -> result.success(scanLocalPlugins())
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("binder_error", e.message, null)
            }
        }
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                val tid = (args as? String) ?: ""
                if (sink != null) eventSinks[tid] = sink else eventSinks.remove(tid)
            }

            override fun onCancel(args: Any?) {
                val tid = (args as? String) ?: ""
                eventSinks.remove(tid)
            }
        })
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

        private val mainHandler = Handler(Looper.getMainLooper())

        private val callback = object : IMcpCallback.Stub() {
            override fun onEvent(jsonRpcMessage: String) {
                // 透传插件事件到 Dart（progress/反向请求消费在 Dart 侧完成）。
                // §1.2.3：onEvent 在 Binder 线程触发，须 post 回主线程再经 EventChannel 发 Dart。
                val tid = id
                val msg = jsonRpcMessage
                mainHandler.post {
                    eventSinks[tid]?.success(
                        mapOf("transportId" to tid, "message" to msg)
                    )
                }
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
        }
    }
}
