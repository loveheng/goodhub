package com.zzh.goodhub.engine

import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 内存预算护栏评估器单测（on-device S3 内存面）：availMem 基线增量预算、
 * 绝对地板、采样噪声容忍、非法采样防护。
 */
class MemoryGuardEvaluatorTest {
    private val gb = 1024L * 1024 * 1024

    @Test
    fun `足迹增量未达预算返回 null`() {
        // 基线 6GB，当前 4608MB → 持有 1536MB < 预算（预算随 HELD_BUDGET_BYTES
        // 校准漂移——本测从常量派生，禁再硬编码预算值）。
        assertNull(MemoryGuardEvaluator.evaluate(6144L * 1024 * 1024, 4608L * 1024 * 1024))
    }

    @Test
    fun `足迹增量达预算触发驱逐并给出理由`() {
        // 基线 8GB，当前 1.5GB → 持有 6.5GB ≥ 预算（HELD_BUDGET_BYTES）
        val reason = MemoryGuardEvaluator.evaluate(
            baselineAvailMemBytes = 8 * gb,
            currentAvailMemBytes = gb + gb / 2,
        )
        assertTrue(reason != null && reason.contains("availMem-delta"))
    }

    @Test
    fun `绝对地板独立触发——增量小但系统可用内存见底也驱逐`() {
        // 基线 1638MB，当前 819MB：持有 819MB 未达预算，但跌破 1GB 地板
        val reason = MemoryGuardEvaluator.evaluate(1638L * 1024 * 1024, 819L * 1024 * 1024)
        assertTrue(reason != null && reason.contains("floor"))
    }

    @Test
    fun `地板判定带 8MB 采样噪声容忍`() {
        // 地板 +8MB（容差带内）：不触发
        assertNull(MemoryGuardEvaluator.evaluate(2 * gb, MemoryGuardEvaluator.ABSOLUTE_FLOOR_BYTES + 8 * 1024 * 1024))
        // 跌破容差带（地板 −8MB）：触发
        val reason = MemoryGuardEvaluator.evaluate(2 * gb, MemoryGuardEvaluator.ABSOLUTE_FLOOR_BYTES - 8 * 1024 * 1024)
        assertTrue(reason != null && reason.contains("floor"))
    }

    @Test
    fun `非法采样（非正值）不触发——防采集侧故障误杀会话`() {
        assertNull(MemoryGuardEvaluator.evaluate(0, 4 * gb))
        assertNull(MemoryGuardEvaluator.evaluate(6 * gb, 0))
        assertNull(MemoryGuardEvaluator.evaluate(-1, 4 * gb))
    }

    @Test
    fun `阈值可注入（接线方口径，评估器无魔法数纪律）`() {
        // 自定义收紧预算：持有 600MB 即触发（1408MB = 2GB − 600MB）
        val reason = MemoryGuardEvaluator.evaluate(
            baselineAvailMemBytes = 2 * gb,
            currentAvailMemBytes = 1408L * 1024 * 1024,
            heldBudgetBytes = 512 * 1024 * 1024,
            floorBytes = 0,
        )
        assertTrue(reason != null && reason.contains("availMem-delta"))
    }

    @Test
    fun `暖机常驻态停用地板线——稳态均衡下不 thrash（2026-11-07 真机实证）`() {
        // 常驻 ~2GB 把 availMem 压到 956MB（稳态均衡）：floorLineEnforced=false
        // 时地板线跳过、足迹增量线照判。
        assertNull(
            MemoryGuardEvaluator.evaluate(
                1638L * 1024 * 1024, 819L * 1024 * 1024,
                floorLineEnforced = false,
            ),
        )
    }

    @Test
    fun `地板停用不豁免足迹增量线——引擎自身吃内存照判`() {
        // 持有 6.5GB ≥ 预算：即使地板停用也触发（delta 线不受豁免）。
        val reason = MemoryGuardEvaluator.evaluate(
            baselineAvailMemBytes = 8 * gb,
            currentAvailMemBytes = gb + gb / 2,
            floorLineEnforced = false,
        )
        assertTrue(reason != null && reason.contains("availMem-delta"))
    }

    @Test
    fun `冷进程（默认）恢复地板全量判定`() {
        // 冷进程未装载过：地板线默认生效，触地板即驱逐（系统饥饿防护）。
        val reason = MemoryGuardEvaluator.evaluate(
            1638L * 1024 * 1024, 819L * 1024 * 1024,
            floorLineEnforced = true,
        )
        assertTrue(reason != null && reason.contains("floor"))
    }
}
