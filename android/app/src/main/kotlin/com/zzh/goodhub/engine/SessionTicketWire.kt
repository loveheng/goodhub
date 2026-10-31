package com.zzh.goodhub.engine

import android.os.Bundle
import com.zzh.goodhub.EngineStatus

/**
 * AIDL↔通道边界适配点（Bundle 缝唯一收口）。
 *
 * 背景（2026-10-31 checkSession 事故）：AIDL 世界类型 = Bundle/Parcel，
 * MethodChannel 世界类型 = Map/List/基本类型（StandardMessageCodec）。两世界
 * 之间所有 Bundle 编解码**必须**经本适配件单点转换，禁缝外手工逐键——
 * 此前 checkSession 出向漏转，Bundle 直进 result.success() 必炸
 * `engine_binder_error`（门禁探测/session-mirror 双双失效）。
 *
 * [SessionTicket] 保持纯逻辑件（无 Android 依赖，JVM 单测覆盖）；本件是其
 * Android 侧接线适配（SessionTicket.kt 注释「Bundle 编解码由接线方承载」
 * 的承载者），与 Dart 侧 `SessionTicket.tryParse`（Map 契约）对称。
 */
object SessionTicketWire {

    // ---- 会话票据缝（checkSession 出向）----

    fun SessionTicket.toBundle(): Bundle = Bundle().apply {
        putString(SessionTicket.KEY_INSTANCE_ID, instanceId)
        putLong(SessionTicket.KEY_SEQ, seq)
        putInt(SessionTicket.KEY_STATUS, status.ordinal)
        putString(SessionTicket.KEY_MODEL_ID, modelId)
        putString(SessionTicket.KEY_RUNTIME, runtime)
        putLong(SessionTicket.KEY_ISSUED_AT, issuedAtMs)
    }

    /** 解码失败（缺关键键）→ null，调用方按未知态处理，禁造票据。 */
    fun ticketFromBundle(b: Bundle): SessionTicket? {
        val instanceId = b.getString(SessionTicket.KEY_INSTANCE_ID) ?: return null
        if (instanceId.isEmpty()) return null
        val ordinal = b.getInt(SessionTicket.KEY_STATUS, -1)
        val status = EngineStatus.values().getOrNull(ordinal) ?: return null
        return SessionTicket(
            instanceId = instanceId,
            seq = b.getLong(SessionTicket.KEY_SEQ),
            status = status,
            modelId = b.getString(SessionTicket.KEY_MODEL_ID) ?: "",
            runtime = b.getString(SessionTicket.KEY_RUNTIME) ?: "",
            issuedAtMs = b.getLong(SessionTicket.KEY_ISSUED_AT),
        )
    }

    /** 通道侧载荷 = 票据 Map（与 Dart tryParse 对称）。 */
    fun ticketChannelMap(b: Bundle): Map<String, Any?> =
        ticketFromBundle(b)?.toMap() ?: emptyMap()
}

/**
 * 生成参数缝（startGenerate 双向）：通道 Map（Dart args）↔ AIDL Bundle 的
 * 唯一转换点。键名常量双端单源（:engine 读 / 桥写均经本件，禁散落字面量）。
 */
data class GenerationParams(
    val maxTokens: Int,
    val temperature: Double,
    val topP: Double,
    val stopTokenIds: IntArray,
    /** 前台态由主进程判定注入（S3-3 抢占语义 §6.6）。 */
    val foreground: Boolean,
) {
    fun toBundle(): Bundle = Bundle().apply {
        putInt(KEY_MAX_TOKENS, maxTokens)
        putDouble(KEY_TEMPERATURE, temperature)
        putDouble(KEY_TOP_P, topP)
        putIntArray(KEY_STOP_TOKEN_IDS, stopTokenIds)
        putBoolean(KEY_FOREGROUND, foreground)
    }

    override fun equals(other: Any?): Boolean = other is GenerationParams &&
        maxTokens == other.maxTokens && temperature == other.temperature &&
        topP == other.topP && stopTokenIds.contentEquals(other.stopTokenIds) &&
        foreground == other.foreground

    override fun hashCode(): Int = listOf(
        maxTokens, temperature, topP, stopTokenIds.contentHashCode(), foreground,
    ).hashCode()

    companion object {
        const val KEY_MAX_TOKENS = "maxTokens"
        const val KEY_TEMPERATURE = "temperature"
        const val KEY_TOP_P = "topP"
        const val KEY_STOP_TOKEN_IDS = "stopTokenIds"
        const val KEY_FOREGROUND = "foreground"

        const val DEFAULT_MAX_TOKENS = 512
        const val DEFAULT_TEMPERATURE = 0.7
        const val DEFAULT_TOP_P = 0.9

        /** :engine 入向：Bundle → 参数（缺省值单源同上，禁缝外重抄默认值）。 */
        fun fromBundle(b: Bundle?): GenerationParams = GenerationParams(
            maxTokens = b?.getInt(KEY_MAX_TOKENS, DEFAULT_MAX_TOKENS) ?: DEFAULT_MAX_TOKENS,
            temperature = b?.getDouble(KEY_TEMPERATURE, DEFAULT_TEMPERATURE) ?: DEFAULT_TEMPERATURE,
            topP = b?.getDouble(KEY_TOP_P, DEFAULT_TOP_P) ?: DEFAULT_TOP_P,
            stopTokenIds = b?.getIntArray(KEY_STOP_TOKEN_IDS) ?: IntArray(0),
            foreground = b?.getBoolean(KEY_FOREGROUND, false) ?: false,
        )

        /** 桥入向：通道 Map args → Bundle（缺省值单源在此）。 */
        fun fromArgs(args: Map<*, *>, foreground: Boolean): GenerationParams = GenerationParams(
            maxTokens = (args["maxTokens"] as? Number)?.toInt() ?: DEFAULT_MAX_TOKENS,
            temperature = (args["temperature"] as? Number)?.toDouble() ?: DEFAULT_TEMPERATURE,
            topP = (args["topP"] as? Number)?.toDouble() ?: DEFAULT_TOP_P,
            stopTokenIds = (args["stopTokenIds"] as? List<*>)
                ?.map { (it as Number).toInt() }?.toIntArray() ?: IntArray(0),
            foreground = foreground,
        )
    }
}
