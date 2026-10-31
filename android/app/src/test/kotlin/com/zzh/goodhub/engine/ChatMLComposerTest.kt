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
}
