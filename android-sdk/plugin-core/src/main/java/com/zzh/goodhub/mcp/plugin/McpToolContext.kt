package com.zzh.goodhub.mcp.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CompletableFuture

/**
 * 异步工具执行上下文（T-sdk-2）：仅注入给 `@McpTool(async = true)` 工具的首参。
 *
 * 通过宿主回注的 [IMcpCallback.onEvent]（oneway）投递全部事件，闭环见
 * docs/design/thirdconnect.md §1.2.2（_async 异步终帧）/ §5（进度 + 反向请求）：
 *  - [progress]：推送 `notifications/progress`（带 request 中 `_meta.progressToken`，
 *    供宿主 BinderTransport 按 token 归属到在途 callWithProgress）；
 *  - [complete] / [completeRaw] / [fail]：推送同 `id` 异步终帧（success / error），
 *    唤醒宿主 `_async` completer（宿主对 `_async` 应答保持 completer 开启直到同 id 终帧）；
 *  - [reverseRequest]：向宿主发 server→client 反向请求（如 `sampling/createMessage`），
 *    经 `answerReverse` 回程（§5 闭环）。
 *
 * 类型对外可见、构造 [internal]——第三方只能「接收」该上下文，不能自行构造。
 */
class McpToolContext internal constructor(
    private val service: GoodHubPluginService,
    private val id: Any?,
    private val progressToken: Any?
) {
    /** 推送进度通知（MCP `notifications/progress`）。[progress] ∈ [0,1]，[total]/[message] 可选。 */
    fun progress(progress: Double, total: Double? = null, message: String? = null) {
        val params = JSONObject().apply {
            put("progressToken", progressToken ?: JSONObject.NULL)
            put("progress", progress)
            if (total != null) put("total", total)
            if (!message.isNullOrEmpty()) put("message", message)
        }
        service.pushEvent(
            JSONObject().apply {
                put("jsonrpc", "2.0")
                put("method", "notifications/progress")
                put("params", params)
            }.toString()
        )
    }

    /** 异步终帧（success）：文本结果包成标准 `content` 块。 */
    fun complete(text: String) {
        completeRaw(
            JSONObject().apply {
                put(
                    "content",
                    JSONArray().apply {
                        put(JSONObject().apply { put("type", "text"); put("text", text) })
                    }
                )
            }
        )
    }

    /** 异步终帧（success）：任意结构化 `result` 对象。 */
    fun completeRaw(result: JSONObject) {
        service.pushEvent(
            JSONObject().apply {
                put("jsonrpc", "2.0")
                put("id", id ?: JSONObject.NULL)
                put("result", result)
            }.toString()
        )
    }

    /** 异步终帧（error）。 */
    fun fail(code: Int, message: String) {
        service.pushEvent(
            JSONObject().apply {
                put("jsonrpc", "2.0")
                put("id", id ?: JSONObject.NULL)
                put(
                    "error",
                    JSONObject().apply { put("code", code); put("message", message) }
                )
            }.toString()
        )
    }

    /**
     * 反向请求（server→client，§5）：向宿主发 request 帧，返回 [CompletableFuture]
     * 待 `answerReverse` 回程。例：`sampling/createMessage`。
     * 宿主未注册回调 → 立即异常完成（绝不悬挂）。
     */
    fun reverseRequest(method: String, params: JSONObject? = null): CompletableFuture<JSONObject> =
        service.reverseRequest(method, params)
}
