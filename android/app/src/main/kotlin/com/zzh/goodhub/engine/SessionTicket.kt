package com.zzh.goodhub.engine

import com.zzh.goodhub.EngineStatus

/**
 * 会话票据（M1 Expand；设计 SSOT =
 * `docs/design/on-device-lifecycle-single-source.md` §2.2）。
 *
 * `:engine` 每次状态变更签发一张票据，主进程只持有「最近见证的票据」——这是
 * 状态单源化的对账载体，取代主进程侧分散的布尔量推断。
 *
 * **epoch = `(instanceId, seq)` 复合键，不做磁盘持久化**：`instanceId` 是
 * `:engine` 进程启动时生成的 UUID，进程重建必变；`seq` 复用
 * [EngineLifecycle] 的代次（装载受理 / 驱逐 / 释放均 +1）。端侧被 LMK/OEM
 * 强杀时页缓存不可信、`fsync` 又不可能每次状态变更都做，持久化计数器是
 * **伪保证**（值回退会让持有旧票据的客户端逃过比对）。不持久化则零 IO、零
 * 坏账，且「进程重建」这一事实由 instanceId 天然表达。
 *
 * 纯逻辑件（无 Android 依赖，JVM 单测覆盖）；Bundle 编解码由接线方
 * （`EngineService`）承载。
 */
data class SessionTicket(
    /** `:engine` 进程实例标识（UUID，进程启动时生成）。 */
    val instanceId: String,
    /** 实例内单调代次（= `EngineLifecycle.generation`）。 */
    val seq: Long,
    /** 权威状态（终态语义；受理态待 `EngineStatus.loading` 追加，M4）。 */
    val status: EngineStatus,
    /**
     * 资产身份。M1（Expand）简化口径 = 最近一次 `loadModel` 的**目录名**；
     * M2 接资产面指纹（目录名 + `.asset-meta.json` 的 version/sizes/runtime
     * 摘要），接入后删除本注。
     */
    val modelId: String,
    /** 生效运行时（qairt / llama_cpp），诊断与 UI 归因，不参与路由判定。 */
    val runtime: String,
    /** 运行环境实况明细（2026-11-05 资源中心实况面：`runtime/计算单元
     *  [|unfit=原因]|sdk=版本`；空串 = Runner 未承载，向后兼容缺省）。 */
    val runtimeDetail: String = "",
    /** 装载失败真因（2026-11-05 文案误归因修复：getLoadError 立法意图的
     *  票据承载——终态失败时主进程据此白话化，禁再把「运行库未装」报成
     *  「模型未导入」；空串 = 无失败/未承载，向后兼容缺省）。 */
    val loadError: String = "",
    /** 签发时刻（诊断面）。 */
    val issuedAtMs: Long,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        KEY_INSTANCE_ID to instanceId,
        KEY_SEQ to seq,
        KEY_STATUS to status.ordinal,
        KEY_MODEL_ID to modelId,
        KEY_RUNTIME to runtime,
        KEY_RUNTIME_DETAIL to runtimeDetail,
        KEY_LOAD_ERROR to loadError,
        KEY_ISSUED_AT to issuedAtMs,
    )

    /** 同实例同代次 = 同一会话（进程重建 instanceId 必变，故无需跨进程单调）。 */
    fun sameEpoch(other: SessionTicket?): Boolean =
        other != null && instanceId == other.instanceId && seq == other.seq

    companion object {
        const val KEY_INSTANCE_ID = "instanceId"
        const val KEY_SEQ = "seq"
        const val KEY_STATUS = "status"
        const val KEY_MODEL_ID = "modelId"
        const val KEY_RUNTIME = "runtime"
        const val KEY_RUNTIME_DETAIL = "runtimeDetail"
        const val KEY_LOAD_ERROR = "loadError"
        const val KEY_ISSUED_AT = "issuedAtMs"

        /** 反向解析（对端 Map 视角的对称校验：缺字段 / 越界序数 → null）。 */
        fun fromMap(m: Map<String, *>): SessionTicket? {
            val instanceId = m[KEY_INSTANCE_ID] as? String ?: return null
            val seq = (m[KEY_SEQ] as? Number)?.toLong() ?: return null
            val ordinal = (m[KEY_STATUS] as? Number)?.toInt() ?: return null
            val status = EngineStatus.values().getOrNull(ordinal) ?: return null
            return SessionTicket(
                instanceId = instanceId,
                seq = seq,
                status = status,
                modelId = m[KEY_MODEL_ID] as? String ?: "",
                runtime = m[KEY_RUNTIME] as? String ?: "",
                runtimeDetail = m[KEY_RUNTIME_DETAIL] as? String ?: "",
                loadError = m[KEY_LOAD_ERROR] as? String ?: "",
                issuedAtMs = (m[KEY_ISSUED_AT] as? Number)?.toLong() ?: 0L,
            )
        }
    }
}
