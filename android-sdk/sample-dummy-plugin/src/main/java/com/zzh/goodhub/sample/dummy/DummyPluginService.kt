package com.zzh.goodhub.sample.dummy

import com.zzh.goodhub.mcp.plugin.GoodHubPluginService
import com.zzh.goodhub.mcp.plugin.McpTool
import com.zzh.goodhub.mcp.plugin.McpToolContext
import com.zzh.goodhub.mcp.plugin.Param
import org.json.JSONArray
import org.json.JSONObject

/**
 * 验证靶子（T-sdk-1 交付物 #4）：提供 echo / add 两个轻量同步工具，外加 T-sdk-2 的
 * 异步进度工具 slowEcho 与反向请求演示工具 reverseDemo，作为 T-trans-3 事件回传链路
 * 的真机联调靶子。安装即被 GoodHub（T-trans-4 后）经 action 扫描自动发现。
 */
class DummyPluginService : GoodHubPluginService(
    serverId = "dummy",
    serverTitle = "Dummy 测试插件"
) {
    @McpTool(description = "原样回显输入文本")
    fun echo(@Param("text", description = "要回显的文本") text: String): String = text

    @McpTool(description = "两个整数相加")
    fun add(
        @Param("a", description = "加数") a: Int,
        @Param("b", description = "被加数") b: Int
    ): Int = a + b

    /**
     * 异步长任务演示（T-sdk-2 / T-trans-3）：call 立即回 `_async`，worker 线程分段推进度，
     * 终帧经 McpToolContext.complete 异步投递——宿主 BinderTransport 保持 completer 开启
     * 直到同 id 终帧（callWithProgress 收侧即达 progress + result）。
     */
    @McpTool(
        description = "异步长任务：分段推送进度后回显（T-trans-3 e2e 靶子）",
        async = true
    )
    fun slowEcho(ctx: McpToolContext, @Param("text", description = "要回显的文本") text: String) {
        val steps = 4
        for (i in 1..steps) {
            Thread.sleep(400)
            ctx.progress(progress = i.toDouble() / steps, message = "处理中 $i/$steps")
        }
        ctx.complete("async: $text")
    }

    /**
     * 反向请求演示（T-sdk-2 / §5）：向宿主发 sampling/createMessage，宿主经 answerReverse
     * 回程推理结果；宿主未接线（onServerRequest 未设）则回 -32601，本工具降级为失败文案，
     * 绝不悬挂（future 异常完成即触发 whenComplete 的 err 分支）。
     */
    @McpTool(
        description = "反向请求演示：请宿主做 sampling 推理后回传（T-trans-3 闭环靶子）",
        async = true
    )
    fun reverseDemo(ctx: McpToolContext, @Param("prompt", description = "交给宿主推理的提示") prompt: String) {
        val future = ctx.reverseRequest(
            "sampling/createMessage",
            JSONObject().apply {
                put("maxTokens", 256)
                put("messages", JSONArray().apply {
                    put(JSONObject().apply {
                        put("role", "user")
                        put("content", JSONObject().apply { put("text", prompt) })
                    })
                })
            }
        )
        future.whenComplete { result, err ->
            if (err != null) {
                ctx.complete("reverse failed: ${err.message}")
            } else {
                val text = result?.optJSONObject("content")?.optString("text", "")
                ctx.complete("sampling result: $text")
            }
        }
    }
}
