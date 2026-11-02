package com.zzh.goodhub.engine

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 复读环检测看门狗：数字环 / 句级环 / 合法重复误报边界。
 *
 * 阈值口径（2026-11-02 第三次真机反证定谳）：DEFAULT_MIN_REPEAT = 4——现场
 * 「12222」（2×4 连）在旧 6 阈值下完整放行；4 阈值下截停为「122」。本测以
 * 显式参数钉住 6 语义回归位、默认构造钉住 4 现行位，防双档漂移。
 */
class RepetitionGuardTest {

    @Test
    fun `现场样本：12222 默认构造命中（2×4 达 4 阈值）`() {
        assertTrue(RepetitionGuard().feed("12222"))
    }

    @Test
    fun `现场样本截停形态：122 前缀放行、凑齐 2×4 命中`() {
        val g = RepetitionGuard()
        assertFalse(g.feed("122"))
        assertFalse(g.feed("2")) // "1222" = 2×3（前导 1 打断），未达
        assertTrue(g.feed("2")) // "12222" = 2×4 命中
    }

    @Test
    fun `数字环：2×4 默认命中，2×3 不达（4 阈值）`() {
        val g = RepetitionGuard()
        assertTrue(RepetitionGuard.isRepeating("2222", RepetitionGuard.DEFAULT_MIN_REPEAT, 8))
        assertFalse(g.feed("222"))
    }

    @Test
    fun `显式 6 档仍可用（回归位）：2×6 命中，2×5 不达`() {
        assertTrue(RepetitionGuard.isRepeating("222222", 6, 8))
        assertFalse(RepetitionGuard.isRepeating("22222", 6, 8))
    }

    @Test
    fun `数字环前缀正常字符不影响尾部判定（有状态 feed）`() {
        val g = RepetitionGuard()
        assertFalse(g.feed("答：1"))
        assertFalse(g.feed("2"))
        assertFalse(g.feed("22"))
        assertTrue(g.feed("2")) // 累计尾部 2×4
    }

    @Test
    fun `句级环：好的×4 默认命中（可接受误伤面：截尾不熔断）`() {
        assertTrue(RepetitionGuard.isRepeating("好的好的好的好的", RepetitionGuard.DEFAULT_MIN_REPEAT, 8))
    }

    @Test
    fun `跨 chunk 拼合的环命中（单 chunk 不达，累计达）`() {
        val g = RepetitionGuard()
        assertFalse(g.feed("好的好的"))
        assertFalse(g.feed("好的"))
        assertTrue(g.feed("好的")) // 累计 好的×4
    }

    @Test
    fun `短数字串环：2024×4 命中（p=4 单元）`() {
        assertTrue(
            RepetitionGuard.isRepeating("2024202420242024", RepetitionGuard.DEFAULT_MIN_REPEAT, 8)
        )
    }

    @Test
    fun `标点环不触发（防误报：逗号、省略号、分隔线、空白）`() {
        assertFalse(RepetitionGuard.isRepeating("，，，，", 4, 8))
        assertFalse(RepetitionGuard.isRepeating("…………", 4, 8))
        assertFalse(RepetitionGuard.isRepeating("----", 4, 8))
        assertFalse(RepetitionGuard.isRepeating("    ", 4, 8))
        assertFalse(RepetitionGuard.isRepeating("----------------", 4, 8))
    }

    @Test
    fun `合法文本不误伤（正常句、低于阈值）`() {
        assertFalse(RepetitionGuard.isRepeating("今天天气不错，我我我觉得挺好", 4, 8))
        assertFalse(RepetitionGuard.isRepeating("我我我", 4, 8))
        assertFalse(RepetitionGuard.isRepeating("ABABAB", 4, 8))
        assertFalse(RepetitionGuard.isRepeating("", 4, 8))
    }

    @Test
    fun `reset：新 query 状态清零`() {
        val g = RepetitionGuard()
        g.feed("2222")
        g.reset()
        assertFalse(g.feed("hello"))
        assertTrue(g.totalChars == 5)
    }

    @Test
    fun `空 chunk 直通且不计字符`() {
        val g = RepetitionGuard()
        assertFalse(g.feed(""))
        assertTrue(g.totalChars == 0)
    }
}
