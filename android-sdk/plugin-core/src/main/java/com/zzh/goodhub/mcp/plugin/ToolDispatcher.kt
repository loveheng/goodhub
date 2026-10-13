package com.zzh.goodhub.mcp.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * 运行时反射派发器：扫描宿主 Service 子类中标注 [McpTool] 的方法，
 * 生成 tools/list Schema，并把 tools/call 路由到目标 Kotlin 函数。
 *
 * 红线对齐：
 *  - 业务异常在派发层拦截并转 -32603（§1.2.7 异常隔离），绝不穿透 Binder 致宿主跨进程 Crash。
 *  - 仅上报 SERVER_ID（来自基类构造入参），不做命名主权仲裁（§9.3 / §1.2.7）。
 *  - v1 用运行时反射（非 KSP），基础类型 String/Int/Boolean（红线 #1，避免过度设计）。
 *
 * T-sdk-2：`@McpTool(async = true)` 工具首参注入 [McpToolContext]，call 内立即回
 * `{"_async": true}`，真实结果经 ctx.complete/fail 异步投递（§1.2.2）；worker 线程
 * 隔离长任务，避免阻塞 Binder 事务（§1.2.3）。
 */
internal class ToolDispatcher(private val service: GoodHubPluginService) {

    private data class ParamMeta(
        val name: String,
        val description: String,
        val required: Boolean,
        val type: String, // json-schema type: string/integer/boolean/number
        val isContext: Boolean = false // true = McpToolContext 注入参数（不进 Schema、不参与 JSON 入参）
    )

    private data class ToolMeta(
        val name: String,
        val description: String,
        val method: java.lang.reflect.Method,
        val params: List<ParamMeta>
    )

    private val tools: List<ToolMeta> by lazy { scan() }

    // 异步工具 worker 线程池（守护线程，§1.2.3 离 Binder 线程跑长任务）。
    private val executor = Executors.newCachedThreadPool { r ->
        val t = Thread(r, "mcp-tool-async")
        t.isDaemon = true
        t
    }

    private fun scan(): List<ToolMeta> {
        val result = mutableListOf<ToolMeta>()
        for (m in service.javaClass.declaredMethods) {
            val ann = m.getAnnotation(McpTool::class.java) ?: continue
            m.isAccessible = true
            val params = m.parameters.mapIndexed { idx, p ->
                val pa = p.getAnnotation(Param::class.java)
                val isContext = p.type == McpToolContext::class.java
                val name = if (isContext) {
                    "<ctx>"
                } else {
                    pa?.value?.takeIf { it.isNotEmpty() } ?: (p.name ?: "arg$idx")
                }
                ParamMeta(
                    name = name,
                    description = if (isContext) "" else (pa?.description ?: ""),
                    required = if (isContext) false else (pa?.required ?: true),
                    type = jsonType(p.type),
                    isContext = isContext
                )
            }
            result.add(ToolMeta(m.name, ann.description, m, params))
        }
        return result
    }

    private fun jsonType(klass: Class<*>): String = when (klass) {
        Int::class.java, Integer::class.java, Long::class.java -> "integer"
        Boolean::class.java -> "boolean"
        Float::class.java, Double::class.java -> "number"
        else -> "string"
    }

    fun handle(requestJson: String): String {
        return try {
            val req = JSONObject(requestJson)
            val method = req.optString("method", "")
            val id = req.opt("id")
            when (method) {
                "initialize" -> initialize(id)
                "tools/list" -> toolsList(id)
                "tools/call" -> toolsCall(id, req)
                else -> errorFrame(id, McpErrors.METHOD_NOT_FOUND, "method not found: $method")
            }
        } catch (e: Exception) {
            // 解析层异常同样兜成 -32603，不向外抛。
            errorFrame(null, McpErrors.INTERNAL_ERROR, e.message ?: "parse error")
        }
    }

    private fun initialize(id: Any?): String {
        val result = JSONObject().apply {
            put("protocolVersion", "2025-06-18")
            put("capabilities", JSONObject().apply { put("tools", JSONObject()) })
            put("serverInfo", JSONObject().apply {
                put("name", service.serverId)
                put("title", service.serverTitle)
                put("version", "1.0.0")
            })
        }
        return successFrame(id, result)
    }

    private fun toolsList(id: Any?): String {
        val list = JSONArray()
        for (t in tools) {
            val props = JSONObject()
            val requiredArr = JSONArray()
            for (p in t.params) {
                if (p.isContext) continue // 上下文参数不进 tools/list Schema
                props.put(p.name, JSONObject().apply {
                    put("type", p.type)
                    if (p.description.isNotEmpty()) put("description", p.description)
                })
                if (p.required) requiredArr.put(p.name)
            }
            val inputSchema = JSONObject().apply {
                put("type", "object")
                put("properties", props)
                if (requiredArr.length() > 0) put("required", requiredArr)
            }
            list.put(JSONObject().apply {
                put("name", t.name)
                put("description", t.description)
                put("inputSchema", inputSchema)
            })
        }
        return successFrame(id, JSONObject().apply { put("tools", list) })
    }

    private fun toolsCall(id: Any?, req: JSONObject): String {
        val paramsObj = req.optJSONObject("params")
            ?: return errorFrame(id, McpErrors.INVALID_PARAMS, "missing params")
        val name = paramsObj.optString("name", "")
        val tool = tools.firstOrNull { it.name == name }
            ?: return errorFrame(id, McpErrors.METHOD_NOT_FOUND, "tool not found: $name")

        val ann = tool.method.getAnnotation(McpTool::class.java)
            ?: return errorFrame(id, McpErrors.INTERNAL_ERROR, "missing @McpTool annotation")

        // 异步长任务：立即回 _async 占位，真实结果经 McpToolContext 异步投递（§1.2.2）。
        if (ann.async) {
            return handleAsync(id, tool, paramsObj)
        }

        val args = buildArgs(tool, paramsObj.optJSONObject("arguments") ?: JSONObject(), null)
            ?: return errorFrame(id, McpErrors.INVALID_PARAMS, "argument mismatch")
        return try {
            val raw = tool.method.invoke(service, *args)
            val text = raw?.toString() ?: ""
            val content = JSONArray().apply {
                put(JSONObject().apply { put("type", "text"); put("text", text) })
            }
            successFrame(id, JSONObject().apply { put("content", content) })
        } catch (e: java.lang.reflect.InvocationTargetException) {
            // 业务函数真实异常：取 cause，转 -32603（§1.2.7 异常隔离）。
            val cause = e.cause ?: e
            errorFrame(id, McpErrors.INTERNAL_ERROR, cause.message ?: cause.javaClass.simpleName)
        } catch (e: Throwable) {
            errorFrame(id, McpErrors.INTERNAL_ERROR, e.message ?: e.javaClass.simpleName)
        }
    }

    /**
     * 异步工具派发（T-sdk-2）：注入 [McpToolContext]，从 request 的 `_meta.progressToken`
     * 取出进度令牌（供宿主按 token 归属），worker 线程跑真实工作；业务异常转 fail 帧，
     * 确保宿主 `_async` completer 必被唤醒（不悬挂）。
     */
    private fun handleAsync(id: Any?, tool: ToolMeta, paramsObj: JSONObject): String {
        val progressToken = paramsObj.optJSONObject("_meta")?.opt("progressToken")
        val ctx = McpToolContext(service, id, progressToken)
        val args = buildArgs(tool, paramsObj.optJSONObject("arguments") ?: JSONObject(), ctx)
            ?: return errorFrame(id, McpErrors.INVALID_PARAMS, "argument mismatch")
        executor.execute {
            try {
                tool.method.invoke(service, *args)
            } catch (e: java.lang.reflect.InvocationTargetException) {
                val cause = e.cause ?: e
                ctx.fail(McpErrors.INTERNAL_ERROR, cause.message ?: cause.javaClass.simpleName)
            } catch (e: Throwable) {
                ctx.fail(McpErrors.INTERNAL_ERROR, e.message ?: e.javaClass.simpleName)
            }
        }
        return successFrame(id, JSONObject().apply { put("_async", true) })
    }

    /**
     * 构造调用实参：McpToolContext 参数注入 ctx；其余按 JSON `arguments` 的 name 映射并 coerce。
     * 缺必填入参 → 返回 null（调用方转 INVALID_PARAMS）；可选缺省 → null。
     */
    private fun buildArgs(
        tool: ToolMeta,
        argsJson: JSONObject,
        ctx: McpToolContext?
    ): Array<Any?>? {
        val result = arrayOfNulls<Any?>(tool.params.size)
        for ((i, p) in tool.params.withIndex()) {
            if (p.isContext) {
                result[i] = ctx
                continue
            }
            if (!argsJson.has(p.name)) {
                if (p.required) return null
                result[i] = null
                continue
            }
            result[i] = coerce(argsJson.opt(p.name), tool.method.parameterTypes[i])
        }
        return result
    }

    private fun coerce(value: Any?, klass: Class<*>): Any? {
        if (value == null) return null
        return when {
            klass == Int::class.java || klass == Integer::class.java ->
                (value as? Number)?.toInt() ?: value.toString().toInt()
            klass == Long::class.java ->
                (value as? Number)?.toLong() ?: value.toString().toLong()
            klass == Boolean::class.java -> when (value) {
                is Boolean -> value
                is Number -> value.toInt() != 0
                else -> value.toString().toBoolean()
            }
            klass == Float::class.java ->
                (value as? Number)?.toFloat() ?: value.toString().toFloat()
            klass == Double::class.java ->
                (value as? Number)?.toDouble() ?: value.toString().toDouble()
            else -> value.toString()
        }
    }

    private fun successFrame(id: Any?, result: JSONObject): String =
        JSONObject().apply {
            put("jsonrpc", "2.0")
            put("id", id ?: JSONObject.NULL)
            put("result", result)
        }.toString()

    private fun errorFrame(id: Any?, code: Int, message: String): String =
        JSONObject().apply {
            put("jsonrpc", "2.0")
            put("id", id ?: JSONObject.NULL)
            put("error", JSONObject().apply { put("code", code); put("message", message) })
        }.toString()
}
