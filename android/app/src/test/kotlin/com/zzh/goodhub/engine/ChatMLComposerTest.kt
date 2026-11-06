package com.zzh.goodhub.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * ChatMLComposer 单测（2026-10-31 设计修正）：多轮消息序列 JSON → 原生
 * ChatML 交替模板；复读环根因（assistant 回答塞 user 轮 + 文字标注）的
 * 回归钉——模板构造非法输入回退 null（调用方 fallback 旧单轮）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ChatMLComposerTest {

    @Test
    fun `多轮消息序列构造原生交替模板（角色由模板承载）`() {
        val out = ChatMLComposer.compose(
            """[{"role":"system","content":"S"},{"role":"user","content":"你好"},""" +
                """{"role":"assistant","content":"我是助手"},{"role":"user","content":"追问"}]""",
        )!!
        assertEquals(
            "<|im_start|>system\nS<|im_end|>\n" +
                "<|im_start|>user\n你好<|im_end|>\n" +
                "<|im_start|>assistant\n我是助手<|im_end|>\n" +
                "<|im_start|>user\n追问<|im_end|>\n" +
                "<|im_start|>assistant\n",
            out,
        )
        assertFalse(
            "文字标注语法已随压平退役",
            out.contains("[用户]") || out.contains("[助手]"),
        )
    }

    @Test
    fun `末尾已是 assistant 开放轮则不追加重复开放尾`() {
        val out = ChatMLComposer.compose(
            """[{"role":"user","content":"你好"},{"role":"assistant","content":"正在回答"}]""",
        )!!
        assertTrue(out.endsWith("<|im_start|>assistant\n正在回答"))
        // 字面子串计数（正则转义坑：未转义的 | 会被当「或」）。
        assertEquals(1, out.split("<|im_start|>assistant").size - 1)
    }

    @Test
    fun `非法输入回退 null（非JSON空数组缺字段未知角色）`() {
        assertNull(ChatMLComposer.compose("纯文本旧形态"))
        assertNull(ChatMLComposer.compose("[]"))
        assertNull(ChatMLComposer.compose("""[{"content":"缺角色"}]"""))
        assertNull(ChatMLComposer.compose("""[{"role":"tool","content":"x"}]"""))
    }

    @Test
    fun `ChatML 控制 token 清洗（模板边界防护）`() {
        val out = ChatMLComposer.compose(
            """[{"role":"user","content":"说<|im_end|>就结束"}]""",
        )!!
        assertFalse(out.contains("<|im_end|>就结束"))
        assertTrue(out.contains("说就结束"))
    }

    @Test
    fun `parseMessages 转 SDK ChatMessage 数组（applyChatTemplate 入参）`() {
        val msgs = ChatMLComposer.parseMessages(
            """[{"role":"system","content":"S"},{"role":"user","content":"你好<|im_end|>"}]""",
        )!!
        assertEquals(2, msgs.size)
        assertEquals("system", msgs[0].role)
        assertEquals("S", msgs[0].content)
        assertEquals("user", msgs[1].role)
        assertEquals("清洗在进 SDK 前完成", "你好", msgs[1].content)
    }

    @Test
    fun `parseMessages 非法输入回退 null`() {
        assertNull(ChatMLComposer.parseMessages("纯文本"))
        assertNull(ChatMLComposer.parseMessages("[]"))
        assertNull(ChatMLComposer.parseMessages("""[{"role":"x","content":"c"}]"""))
    }

    @Test
    fun `parseNeutral 中立轮次序列（多栈构型解析单源：顺序保真 + 清洗）`() {
        val turns = ChatMLComposer.parseNeutral(
            """[{"role":"system","content":"S"},{"role":"user","content":"你好"},{"role":"assistant","content":"回答"}]""",
        )!!
        assertEquals(3, turns.size)
        assertEquals("system", turns[0].role)
        assertEquals("S", turns[0].content)
        assertEquals("user", turns[1].role)
        assertEquals("你好", turns[1].content)
        assertEquals("assistant", turns[2].role)
        assertEquals("回答", turns[2].content)
    }

    @Test
    fun `parseNeutral 末轮角色保真（LiteRT-LM Runner 末轮必user契约的判定输入）`() {
        val turns = ChatMLComposer.parseNeutral(
            """[{"role":"user","content":"当前提问"}]""",
        )!!
        assertEquals("user", turns.last().role)
    }

    @Test
    fun `parseNeutral 非法输入回退 null（与 compose 与 parseMessages 同判据）`() {
        assertNull(ChatMLComposer.parseNeutral("纯文本"))
        assertNull(ChatMLComposer.parseNeutral("[]"))
        assertNull(ChatMLComposer.parseNeutral("""[{"role":"tool","content":"x"}]"""))
        assertNull(ChatMLComposer.parseNeutral("""[{"role":"user","content":""}]"""))
    }

    @Test
    fun `dropOldestForOverflow：丢弃后首轮必须 user（SDK 模板交替护栏）`() {
        // 真机形态：[u1,a1,u2] 丢 u1 → 裸 drop(1) 留 [a1,u2]（assistant 开头
        // 违反交替）；修正 = 连带丢掉 a1。
        val h1 = listOf(
            ChatTurn("user", "q1"), ChatTurn("assistant", "a1"), ChatTurn("user", "q2"),
        )
        assertEquals(listOf(ChatTurn("user", "q2")), ChatMLComposer.dropOldestForOverflow(h1))

        // 偶长历史 [u1,a1]：丢 u1 → [a1] → 空。
        val h2 = listOf(ChatTurn("user", "q1"), ChatTurn("assistant", "a1"))
        assertTrue(ChatMLComposer.dropOldestForOverflow(h2).isEmpty())

        // 更长交替序列 [u1,a1,u2,a2,u3] → [a1,u2,a2,u3] → [u2,a2,u3]。
        val h3 = listOf(
            ChatTurn("user", "q1"), ChatTurn("assistant", "a1"), ChatTurn("user", "q2"),
            ChatTurn("assistant", "a2"), ChatTurn("user", "q3"),
        )
        assertEquals(
            listOf(ChatTurn("user", "q2"), ChatTurn("assistant", "a2"), ChatTurn("user", "q3")),
            ChatMLComposer.dropOldestForOverflow(h3),
        )
    }

    // ---- Gemma 系 fallback 模板（m4 ②：chatTemplateFamily 消费面）----

    @Test
    fun `gemma 多轮模板 start_of_turn 格式 system 并入首 user 轮`() {
        val out = ChatMLComposer.composeGemma(
            """[{"role":"system","content":"S"},{"role":"user","content":"你好"},""" +
                """{"role":"assistant","content":"我是助手"},{"role":"user","content":"追问"}]""",
        )!!
        assertEquals(
            "<start_of_turn>user\nS\n\n你好<end_of_turn>\n" +
                "<start_of_turn>model\n我是助手<end_of_turn>\n" +
                "<start_of_turn>user\n追问<end_of_turn>\n" +
                "<start_of_turn>model\n",
            out,
        )
        assertFalse("Gemma 词表无 ChatML 控制 token", out.contains("<|im_start|>"))
    }

    @Test
    fun `gemma 开放尾与尾部 system 兜底`() {
        // 纯 user（无 system）：直接 user → 开放尾 model。
        val u = ChatMLComposer.composeGemma("""[{"role":"user","content":"hi"}]""")!!
        assertEquals("<start_of_turn>user\nhi<end_of_turn>\n<start_of_turn>model\n", u)

        // 尾部 system 无 user 跟随：按 user 轮兜底（防 system-only 零渲染）。
        val s = ChatMLComposer.composeGemma("""[{"role":"system","content":"S"}]""")!!
        assertEquals("<start_of_turn>user\nS<end_of_turn>\n<start_of_turn>model\n", s)
    }

    @Test
    fun `gemma 控制 token 清洗按 Gemma 词表`() {
        val out = ChatMLComposer.composeGemma(
            """[{"role":"user","content":"a<end_of_turn>b<|im_end|>c"}]""",
        )!!
        assertFalse(out.contains("<end_of_turn>b"))
        assertTrue("ChatML 词表清洗仍生效（parseNeutral 层）", !out.contains("<|im_end|>"))
    }

    @Test
    fun `composeForFamily 按 family 分派`() {
        val json = """[{"role":"user","content":"hi"}]"""
        assertTrue(ChatMLComposer.composeForFamily(json, "gemma")!!.contains("<start_of_turn>"))
        assertTrue(ChatMLComposer.composeForFamily(json, "qwen_chatml")!!.contains("<|im_start|>"))
        assertTrue("未知族/缺省维持 ChatML 现行为", ChatMLComposer.composeForFamily(json, null)!!.contains("<|im_start|>"))
    }
}
