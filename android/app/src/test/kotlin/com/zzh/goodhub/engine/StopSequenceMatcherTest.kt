package com.zzh.goodhub.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 跨帧停用词匹配器（D-3 契约重构）：跨帧切断 / 最早命中 / 直通 / flush 语义。 */
class StopSequenceMatcherTest {

    @Test
    fun `停用词跨帧切断不漏检`() {
        val m = StopSequenceMatcher(listOf("<|im_end|>"))
        val r1 = m.feed("你好<|im_")
        assertEquals("", r1.release) // 缓冲 6 字符 < keep(9)，全部滞留防跨帧切断
        assertFalse(r1.stopped)
        val r2 = m.feed("end|>后续")
        assertEquals("你好", r2.release) // 帧一累积的命中前文本随 STOP 帧一并放行
        assertTrue(r2.stopped)
    }

    @Test
    fun `最早命中优先且命中前文本完整下发`() {
        val m = StopSequenceMatcher(listOf("\nUser:", "<|im_end|>"))
        val r = m.feed("答案A\nUser:答案B<|im_end|>尾巴")
        assertEquals("答案A", r.release)
        assertTrue(r.stopped)
    }

    @Test
    fun `未命中缓冲不足时全滞留 终态放行`() {
        val m = StopSequenceMatcher(listOf("<|im_end|>"))
        val r = m.feed("普通文本没有停用词") // 9 字符 = keep，不超不放行
        assertEquals("", r.release)
        assertFalse(r.stopped)
        assertEquals("普通文本没有停用词", m.flush()) // 终态放行滞留
    }

    @Test
    fun `空停用词表直通不缓冲`() {
        val m = StopSequenceMatcher(emptyList())
        val r = m.feed("任意文本")
        assertEquals("任意文本", r.release)
        assertFalse(r.stopped)
        assertEquals("", m.flush())
    }

    @Test
    fun `默认表为 ChatML 闭合 token`() {
        assertEquals(listOf("<|im_end|>"), StopSequenceMatcher.DEFAULT)
        val m = StopSequenceMatcher(StopSequenceMatcher.DEFAULT)
        val r = m.feed("正文<|im_end|>")
        assertEquals("正文", r.release)
        assertTrue(r.stopped)
    }

    @Test
    fun `多次 feed 累计拼接后命中`() {
        val m = StopSequenceMatcher(listOf("STOP"))
        m.feed("a")
        m.feed("bc")
        val r = m.feed("deSTOPf")
        assertEquals("abcde", r.release)
        assertTrue(r.stopped)
    }
}
