package com.zzh.goodhub.engine

import com.geniex.sdk.bean.ChatMessage
import org.json.JSONArray

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
     * 解析消息序列 JSON 并构造多轮 ChatML。非法输入（非数组 / 空 / 缺字段 /
     * 未知角色）返回 null——调用方 fallback 旧单轮包装（防御旁路调用方）。
     */
    fun compose(promptJson: String): String? {
        val arr = try {
            JSONArray(promptJson)
        } catch (e: Exception) {
            return null
        }
        if (arr.length() == 0) return null
        val sb = StringBuilder()
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
            val isLast = i == arr.length() - 1
            sb.append("<|im_start|>").append(role).append('\n').append(content)
            when {
                // 开放尾：末段 assistant 保持开放（模型续写起点，禁闭合——
                // 闭合 = 无续写上下文，模型立即 EOS 收尾 = 空产出）。
                isLast && role == "assistant" -> Unit
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
     * 非法输入返回 null。清洗在此层统一做（进 SDK 前最后一道）。
     */
    fun parseMessages(promptJson: String): Array<ChatMessage>? {
        val arr = try {
            JSONArray(promptJson)
        } catch (e: Exception) {
            return null
        }
        if (arr.length() == 0) return null
        val out = ArrayList<ChatMessage>(arr.length())
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
            out.add(ChatMessage(role, content))
        }
        return out.toTypedArray()
    }
}
