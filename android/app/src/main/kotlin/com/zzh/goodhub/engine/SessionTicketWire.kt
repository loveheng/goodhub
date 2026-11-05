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
        putString(SessionTicket.KEY_RUNTIME_DETAIL, runtimeDetail)
        putString(SessionTicket.KEY_LOAD_ERROR, loadError)
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
            runtimeDetail = b.getString(SessionTicket.KEY_RUNTIME_DETAIL) ?: "",
            loadError = b.getString(SessionTicket.KEY_LOAD_ERROR) ?: "",
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
    val stopSequences: List<String>,
    /** 前台态由主进程判定注入（S3-3 单执行槽语义 §6.6；打断术语 S14e 订正）。 */
    val foreground: Boolean,
    /** F3 大载荷通道（2026-10-31 ADR）：超内联上限的 promptJson 落临时文件，
     * 此处携路径（Binder 只传短元数据——§8 载荷上限立法）。:engine 读取后
     * 即删，双方都不留存。null/空 = 内联 promptJson 口径。 */
    val promptFilePath: String? = null,
    /** S17b（task-capability，D4 前提）：约束解码规格——type = 'json'|'regex'，
     * value = Schema 文本/正则。null = 无约束（Dart 侧键缺席语义）。Runner
     * 侧自治匹配（token 级解析禁中心化，D-3 纪律；K15：解码失败带同一份
     * 规格回退云端，禁截断降级档）。 */
    val responseFormatType: String? = null,
    val responseFormatValue: String? = null,
) {
    fun toBundle(): Bundle = Bundle().apply {
        putInt(KEY_MAX_TOKENS, maxTokens)
        putDouble(KEY_TEMPERATURE, temperature)
        putDouble(KEY_TOP_P, topP)
        putStringArrayList(KEY_STOP_SEQUENCES, ArrayList(stopSequences))
        putBoolean(KEY_FOREGROUND, foreground)
        if (!promptFilePath.isNullOrEmpty()) putString(KEY_PROMPT_FILE_PATH, promptFilePath)
        if (!responseFormatType.isNullOrEmpty()) putString(KEY_RESPONSE_FORMAT_TYPE, responseFormatType)
        if (!responseFormatValue.isNullOrEmpty()) putString(KEY_RESPONSE_FORMAT_VALUE, responseFormatValue)
    }

    override fun equals(other: Any?): Boolean = other is GenerationParams &&
        maxTokens == other.maxTokens && temperature == other.temperature &&
        topP == other.topP && stopSequences == other.stopSequences &&
        foreground == other.foreground &&
        responseFormatType == other.responseFormatType &&
        responseFormatValue == other.responseFormatValue

    override fun hashCode(): Int = listOf(
        maxTokens, temperature, topP, stopSequences, foreground,
        responseFormatType, responseFormatValue,
    ).hashCode()

    companion object {
        const val KEY_MAX_TOKENS = "maxTokens"
        const val KEY_TEMPERATURE = "temperature"
        const val KEY_TOP_P = "topP"
        const val KEY_STOP_SEQUENCES = "stopSequences"
        const val KEY_FOREGROUND = "foreground"
        const val KEY_PROMPT_FILE_PATH = "promptFilePath"
        const val KEY_RESPONSE_FORMAT_TYPE = "responseFormatType"
        const val KEY_RESPONSE_FORMAT_VALUE = "responseFormatValue"

        // 双端缺省单源（2026-11-03 对齐）：与 Dart 侧 GenerationConfig 内建默认
        // 同值——此前 0.7/0.9 与 Dart 1.0/0.95 漂移，任一侧漏传即落回低温窄
        // 分布（12222 复读事故同款陷阱）。改 Dart 缺省须同步改这里。
        const val DEFAULT_MAX_TOKENS = 512
        const val DEFAULT_TEMPERATURE = 1.0
        const val DEFAULT_TOP_P = 0.95

        /** :engine 入向：Bundle → 参数（缺省值单源同上，禁缝外重抄默认值）。 */
        fun fromBundle(b: Bundle?): GenerationParams = GenerationParams(
            maxTokens = b?.getInt(KEY_MAX_TOKENS, DEFAULT_MAX_TOKENS) ?: DEFAULT_MAX_TOKENS,
            temperature = b?.getDouble(KEY_TEMPERATURE, DEFAULT_TEMPERATURE) ?: DEFAULT_TEMPERATURE,
            topP = b?.getDouble(KEY_TOP_P, DEFAULT_TOP_P) ?: DEFAULT_TOP_P,
            stopSequences = b?.getStringArrayList(KEY_STOP_SEQUENCES) ?: emptyList(),
            foreground = b?.getBoolean(KEY_FOREGROUND, false) ?: false,
            responseFormatType = b?.getString(KEY_RESPONSE_FORMAT_TYPE),
            responseFormatValue = b?.getString(KEY_RESPONSE_FORMAT_VALUE),
        )

        /** 桥入向：通道 Map args → Bundle（缺省值单源在此）。Dart 侧 responseFormat
         * 传 Map{type,value}（LlmResponseFormat.toChannelArgs），缺席 = 无约束。 */
        fun fromArgs(args: Map<*, *>, foreground: Boolean): GenerationParams {
            val fmt = args["responseFormat"] as? Map<*, *>
            return GenerationParams(
                maxTokens = (args["maxTokens"] as? Number)?.toInt() ?: DEFAULT_MAX_TOKENS,
                temperature = (args["temperature"] as? Number)?.toDouble() ?: DEFAULT_TEMPERATURE,
                topP = (args["topP"] as? Number)?.toDouble() ?: DEFAULT_TOP_P,
                stopSequences = (args["stopSequences"] as? List<*>)
                    ?.map { it?.toString().orEmpty() } ?: emptyList(),
                foreground = foreground,
                promptFilePath = args["promptFilePath"] as? String,
                responseFormatType = fmt?.get("type")?.toString(),
                responseFormatValue = fmt?.get("value")?.toString(),
            )
        }
    }
}
