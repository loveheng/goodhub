package com.zzh.goodhub.engine

/**
 * 跨帧停用词匹配器（D-3 契约重构 2026-11-01，decisions.md ADR「首发节奏」同轮）。
 *
 * 背景：Genie SDK 拒收 stop sequences（ErrorCode -100016，deployment §6.7 落位
 * 实证），终止判定只能在 `:engine` 文本流上做——但流按 chunk 到达，停用词可能
 * 被切在 chunk 边界（如 `"<|im_"` + `"end|>"`）。本匹配器持未判定尾部缓冲：
 *  - [feed]：拼接缓冲 → 取所有停用词的最早命中 → 命中返回 STOP（命中前文本，
 *    缓冲清空）；未命中仅放行「安全前缀」（保留末尾 maxStop-1 字符防跨帧切断）；
 *  - [flush]：流终态（EOS/Completed 无命中）放行全部滞留文本。
 *
 * 空停用词表 = 全部直接放行（直通语义）。默认表 = [DEFAULT]（对齐 GenieSession
 * 既有 `<|im_end|>` 截断语义；AIDL `stopSequences` 下发序列追加参与匹配——
 * 编码判定由各自 Runner 的 tokenizer 自治，D-3 契约：禁预编码 id 跨后端下发）。
 */
class StopSequenceMatcher(stops: List<String>) {
    private val sequences: List<String> = stops.filter { it.isNotEmpty() }
    private val maxStopLen: Int = sequences.maxOfOrNull { it.length } ?: 0
    private var pending = StringBuilder()

    /** 匹配结果：[release] = 可安全下发的文本；[stopped] = 命中停用词（应终止生成）。 */
    data class Result(val release: String, val stopped: Boolean)

    fun feed(chunk: String): Result {
        if (sequences.isEmpty()) return Result(chunk, false)
        pending.append(chunk)
        var hit = -1
        for (s in sequences) {
            val i = pending.indexOf(s)
            if (i >= 0 && (hit < 0 || i < hit)) hit = i
        }
        return if (hit >= 0) {
            val head = pending.substring(0, hit)
            pending.setLength(0)
            Result(head, true)
        } else {
            val keep = maxStopLen - 1
            val safe = if (pending.length > keep) {
                pending.substring(0, pending.length - keep)
            } else ""
            if (safe.isNotEmpty()) pending.delete(0, safe.length)
            Result(safe, false)
        }
    }

    /** 流终态放行全部滞留文本（无停用词命中时的收尾）。 */
    fun flush(): String {
        val rest = pending.toString()
        pending.setLength(0)
        return rest
    }

    companion object {
        /** 默认停用词：ChatML 模板闭合 token（对齐 GenieSession 既有截断语义）。 */
        val DEFAULT: List<String> = listOf("<|im_end|>")
    }
}
