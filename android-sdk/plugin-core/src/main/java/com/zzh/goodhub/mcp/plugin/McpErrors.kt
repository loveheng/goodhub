package com.zzh.goodhub.mcp.plugin

/**
 * JSON-RPC 错误码常量（对齐 MCP / §1.2.7 异常隔离红线）。
 */
object McpErrors {
    const val METHOD_NOT_FOUND = -32601
    const val INVALID_PARAMS = -32602
    const val INTERNAL_ERROR = -32603
}
