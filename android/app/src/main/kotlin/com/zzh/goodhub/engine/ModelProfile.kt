package com.zzh.goodhub.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 声明式解析元数据（`.asset-meta.json` 的 `modelProfile` 块，2026-11-02）：
 * 导入/安装期 Dart 侧探测落盘，各 Runner 装载期经 [ModelProfile.read] 从
 * 自有 modelDir 读取消费——**不动 AIDL**（AIDL 契约只承载请求语义，模型
 * 静态属性走磁盘 meta 单源）。禁中心化 token 级解析（D-3）：本类只承载
 * 声明式属性，解析逻辑仍归各 Runner 自治。
 *
 * 字段全可空：meta 无块 / 探测失败 = 调用方按既有内建口径走（禁臆造默认）。
 */
data class ModelProfile(
    /** 模板家族（qwen_chatml / llama3 / gemma / unknown）。null = 未标注。 */
    val chatTemplateFamily: String?,
    /** 模型级默认停用词（请求未下发时的回退位；当前写入侧暂不产出）。 */
    val stopSequences: List<String>,
    /** 模型上下文窗口（token 上限）；仅诊断日志用（预算裁剪归 Dart 侧）。 */
    val contextTokens: Int?,
) {
    companion object {
        /**
         * 从 modelDir 的 `.asset-meta.json` 读 `modelProfile` 块。文件缺失 /
         * 无块 / 解析失败一律返 null（不阻断装载——meta 是增强面非门禁）。
         */
        fun read(modelDir: String): ModelProfile? {
            return try {
                val metaFile = File(modelDir, ".asset-meta.json")
                if (!metaFile.exists()) return null
                val meta = JSONObject(metaFile.readText())
                val raw = meta.optJSONObject("modelProfile") ?: return null
                val family = raw.optString("chatTemplateFamily", "").trim()
                    .ifEmpty { null }
                val stops = raw.optJSONArray("stopSequences")?.let { arr ->
                    (0 until arr.length())
                        .mapNotNull { arr.optString(it, "").ifEmpty { null } }
                } ?: emptyList()
                val ctx = if (raw.has("contextTokens")) raw.getLong("contextTokens") else null
                if (family == null && stops.isEmpty() && ctx == null) return null
                ModelProfile(
                    chatTemplateFamily = family,
                    stopSequences = stops,
                    contextTokens = ctx?.toInt(),
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}
