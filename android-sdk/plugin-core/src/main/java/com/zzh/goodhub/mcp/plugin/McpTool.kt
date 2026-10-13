package com.zzh.goodhub.mcp.plugin

/**
 * 标记插件业务函数为 MCP 工具。SDK 运行时反射扫描此注解生成 tools/list Schema
 * 并把 tools/call 路由到对应方法。
 *
 * @param description 工具描述（进入 inputSchema.description）
 * @param timeoutMs   同步调用预算红线（§1.2.3）；T-sdk-1 仅作为元数据记录，
 *                   真正超时降级由 T-sdk-2 的 _async 投递落地
 * @param async       true 时该工具在 call 内立即返回 {"_async": true} 轻量分支骨架
 *                   （§1.2.2 长任务异步约定；真实结果投递留 T-sdk-2）
 */
@Target(AnnotationTarget.FUNCTION)
@Retention(AnnotationRetention.RUNTIME)
annotation class McpTool(
    val description: String = "",
    val timeoutMs: Long = 5000,
    val async: Boolean = false
)
