package com.zzh.goodhub.engine

import com.geniex.sdk.bean.ChatMessage
import org.json.JSONArray

/**
 * 中立轮次（消息 JSON → role+content）：多栈构型 ADR 2026-11-01 的能力单源。
 *
 * [ChatMLComposer.parseNeutral] 是「消息序列 JSON → 轮次序列」的**唯一解析点**——
 * 模板渲染归各 Runner 自治（GenieX = SDK applyChatTemplate/ChatML 手写模板，
 * LiteRT-LM = SDK 原生 bundle 模板经 Conversation 角色映射），解析不再随 Runner
 * 复制（否决信号 #2 收口）。
 */
data class ChatTurn(val role: String, val content: String)

/**
 * 多轮 ChatML 模板构造器（纯逻辑件，JVM 单测覆盖）。
 *
 * **2026-10-31 设计修正（用户裁决：从底层设计找根因）**：复读环（带历史的
 * 轮次复述首轮回答）根因 = 旧「单发压平」把 assistant 历史回答塞进 user 轮
 * （外加 `[用户]/[助手]` 人造标注），违背 Qwen 系训练分布（ChatML 多轮
 * 交替），4B 模型对 OOD 输入的行为退化 = 复述上下文。修正 = 消息序列
 * （`promptJson` = `[{"role":..,"content":..}]`）按**原生多轮交替模板**构造，
 * 角色表达归还模板层（单一职责归位），文字标注语法整体退役。
 *
 * 模板（Qwen/ChatML；家族假设与旧单轮同源，见 GenieSession 注）：
 * ```
 * <|im_start|>system\n…<|im_end|>\n
 * <|im_start|>user\n…<|im_end|>\n
 * <|im_start|>assistant\n…<|im_end|>\n
 * …
 * <|im_start|>user\n…<|im_end|>\n
 * <|im_start|>assistant\n        ← 开放尾：模型从此续写
 * ```
 */
object ChatMLComposer {

    /**
     * 解析消息序列 JSON 为中立轮次序列（**全部消费方的唯一解析源**：
     * [compose] / [parseMessages] / LiteRtLmRunner 角色映射）。
     * 非法输入（非数组 / 空 / 缺字段 / 未知角色 / 空 content）返回 null——
     * 调用方按各自契约处理（GenieX 走旧单轮包装 fallback；LiteRT-LM 显式失败）。
     */
    fun parseNeutral(promptJson: String): List<ChatTurn>? {
        val arr = try {
            JSONArray(promptJson)
        } catch (e: Exception) {
            return null
        }
        if (arr.length() == 0) return null
        val out = ArrayList<ChatTurn>(arr.length())
        for (i in 0 until arr.length()) {
            val obj = try {
                arr.getJSONObject(i)
            } catch (e: Exception) {
                return null
            }
            val role = obj.optString("role", "")
            val content = sanitizeChatMLControlTokens(obj.optString("content", ""))
            if (role !in setOf("system", "user", "assistant") || content.isEmpty()) {
                return null
            }
            out.add(ChatTurn(role, content))
        }
        return out
    }

    /**
     * 解析消息序列 JSON 并构造多轮 ChatML。非法输入返回 null——调用方
     * fallback 旧单轮包装（防御旁路调用方）。
     */
    fun compose(promptJson: String): String? {
        val turns = parseNeutral(promptJson) ?: return null
        val sb = StringBuilder()
        for ((i, t) in turns.withIndex()) {
            val isLast = i == turns.size - 1
            sb.append("<|im_start|>").append(t.role).append('\n').append(t.content)
            when {
                // 开放尾：末段 assistant 保持开放（模型续写起点，禁闭合——
                // 闭合 = 无续写上下文，模型立即 EOS 收尾 = 空产出）。
                isLast && t.role == "assistant" -> Unit
                isLast -> sb.append("<|im_end|>\n").append("<|im_start|>assistant\n")
                else -> sb.append("<|im_end|>\n")
            }
        }
        return sb.toString()
    }

    /** 模板级清洗双保险的 Kotlin 侧（与 Dart 侧 kChatMLControlToken 同语义）。 */
    fun sanitizeChatMLControlTokens(text: String): String =
        text.replace(Regex("<\\|(?:im_start|im_end|im_sep|endoftext)\\|>"), "")

    /**
     * 解析消息序列 JSON 为 SDK `ChatMessage[]`（官方 applyChatTemplate 入参）。
     * 中立解析之上的薄映射（2026-11-01 多栈构型：解析单源 = [parseNeutral]）。
     * 非法输入返回 null。清洗在 [parseNeutral] 层统一做（进 SDK 前最后一道）。
     */
    fun parseMessages(promptJson: String): Array<ChatMessage>? =
        parseNeutral(promptJson)?.map { ChatMessage(it.role, it.content) }?.toTypedArray()

    /**
     * 上下文溢出丢弃修正（2026-11-02 真机反证）：丢最老历史轮后首轮必须
     * user——SDK 模板严格要求 user/assistant 交替（in template:15），单丢
     * 一轮可能留 assistant 开头 → 模板交替违规 → 零产出（1291>=1280 溢出
     * → drop → "roles must alternate" 真机日志）。数据面保证原序列严格
     * 交替，故至多再丢一轮；while 为防御（异常输入序列）。
     */
    fun dropOldestForOverflow(history: List<ChatTurn>): List<ChatTurn> {
        var dropped = history.drop(1)
        while (dropped.isNotEmpty() && dropped.first().role != "user") {
            dropped = dropped.drop(1)
        }
        return dropped
    }
}
