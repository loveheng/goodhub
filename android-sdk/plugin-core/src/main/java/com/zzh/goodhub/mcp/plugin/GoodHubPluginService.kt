package com.zzh.goodhub.mcp.plugin

import android.app.Service
import android.content.Intent
import android.os.IBinder
import com.zzh.goodhub.mcp.IMcpChannel
import com.zzh.goodhub.mcp.IMcpCallback
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * 插件侧 SDK 服务基类（server 端）：自动实现 [IMcpChannel.Stub]。
 * 子类用 [McpTool] 标注业务方法即可，零手写 AIDL / ServiceConnection。
 *
 * 角色边界（§11.3 五处纠正·1）：仅实现 Stub；不 bindService、不持 DeathRecipient
 * （client 端连接生命周期 / 挂起队列状态机完全归 GoodHub 宿主 BinderTransport）。
 * 红线（§1.2.7 / §9.3）：仅上报 SERVER_ID（构造入参），不做命名主权仲裁、不做包名拼接。
 *
 * T-sdk-2：补齐事件发射端——[pushEvent] 投 progress / 异步终帧 / 反向请求；
 * [reverseRequest] + [IMcpChannel.answerReverse] 实现反向请求闭环（§5）。
 */
abstract class GoodHubPluginService(
    val serverId: String,
    val serverTitle: String
) : Service() {

    private val dispatcher = ToolDispatcher(this)

    // 宿主回注的回调；volatile：异步终帧/反向应答可能从 worker 线程读取。
    @Volatile
    private var callback: IMcpCallback? = null

    // 反向请求在途表：key = 反向请求 id，value = 待 answerReverse 回程的 future（§5）。
    private val pendingReverse = ConcurrentHashMap<Long, CompletableFuture<JSONObject>>()
    private val reverseCounter = AtomicLong(1)

    private val binder = object : IMcpChannel.Stub() {
        override fun call(jsonRpcRequest: String): String {
            // 离主线程由宿主侧保证（§1.2.3）；此处同步处理并在派发层隔离异常。
            return dispatcher.handle(jsonRpcRequest)
        }

        override fun registerCallback(cb: IMcpCallback?) {
            callback = cb
        }

        override fun answerReverse(jsonRpcResponse: String) {
            // 宿主回答插件经 onEvent 发出的反向请求（§1.2.2 / §5）：按 id 关联并唤醒 future。
            try {
                val r = JSONObject(jsonRpcResponse)
                val id = r.optLong("id", -1L)
                val future = pendingReverse.remove(id) ?: return
                if (r.has("error")) {
                    val err = r.optJSONObject("error")
                    future.completeExceptionally(
                        IllegalStateException("reverse request $id failed: ${err?.optString("message")}")
                    )
                } else {
                    future.complete(r.optJSONObject("result") ?: JSONObject())
                }
            } catch (_: Throwable) {
                // 解析失败：静默（宿主侧会超时兜底，不悬挂）。
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    /** 供 [McpToolContext] / 子类经 onEvent 推事件（progress / 异步终帧 / 反向请求）。 */
    internal fun pushEvent(jsonRpcMessage: String) {
        try {
            callback?.onEvent(jsonRpcMessage)
        } catch (_: Throwable) {
            // 回调断连由宿主 DeathRecipient 感知，此处静默。
        }
    }

    /**
     * 发起反向请求（server→client），返回 [CompletableFuture] 待 [answerReverse] 回程（§5）。
     * 经 [IMcpCallback.onEvent] 推 request 帧；宿主处理后经 answerReverse 应答。
     * 宿主未注册回调 → 立即异常完成（绝不悬挂）。
     */
    internal fun reverseRequest(
        method: String,
        params: JSONObject?
    ): CompletableFuture<JSONObject> {
        val cb = callback
        val future = CompletableFuture<JSONObject>()
        if (cb == null) {
            future.completeExceptionally(IllegalStateException("no host callback registered for reverse request"))
            return future
        }
        val rid = reverseCounter.getAndIncrement()
        pendingReverse[rid] = future
        val frame = JSONObject().apply {
            put("jsonrpc", "2.0")
            put("method", method)
            put("id", rid)
            if (params != null) put("params", params)
        }
        try {
            cb.onEvent(frame.toString())
        } catch (e: Throwable) {
            pendingReverse.remove(rid)
            future.completeExceptionally(e)
        }
        return future
    }
}
