package com.zzh.goodhub.mcp.plugin

/**
 * 标记工具方法参数，提供参数名（覆盖反射所得形参名，避免混淆后丢失）、
 * 描述与必填性，用于生成 inputSchema 的 properties。
 */
@Target(AnnotationTarget.VALUE_PARAMETER)
@Retention(AnnotationRetention.RUNTIME)
annotation class Param(
    val value: String = "",
    val description: String = "",
    val required: Boolean = true
)
