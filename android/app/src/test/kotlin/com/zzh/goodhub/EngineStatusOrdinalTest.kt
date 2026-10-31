package com.zzh.goodhub

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * EngineStatus 双端序数锚定（Fix1 恢复语义去歧义回归钉）。
 *
 * 序数 = AIDL int 传输契约（禁调序，仅允许末尾追加）——Dart 侧
 * `test/llm/on_device_engine_status_test.dart` 同轮锚定 reloading == 8，
 * 任一侧漂移即测试红。
 *
 * 事故背景（2026-10-31）：拒绝同进程重载（loadedOnce 自杀纪律）此前返回
 * assetMissing 终态序数 → 主进程当「模型未导入」误导重下且不再重试
 * → 端侧静默永久失效、后续请求静默切云。改为专用 reloading 信号后，
 * 主进程按可重试中断处理（短退避重绑 → 接住冷启动后的新进程）。
 */
class EngineStatusOrdinalTest {
    @Test
    fun `reloading 固定末尾 ordinal 8（与 Dart 侧同轮锚定）`() {
        assertEquals(8, EngineStatus.reloading.ordinal)
    }

    @Test
    fun `unknownNeedReconcile 固定末尾 ordinal 9（F2 越界收容态，与 Dart 侧同轮锚定）`() {
        assertEquals(9, EngineStatus.unknownNeedReconcile.ordinal)
    }

    @Test
    fun `loading 保持 ordinal 7（M4 追加位不动，禁调序）`() {
        assertEquals(7, EngineStatus.loading.ordinal)
    }

    @Test
    fun `assetMissing 保持 ordinal 2（终态语义，禁再被重载路径借用）`() {
        assertEquals(2, EngineStatus.assetMissing.ordinal)
    }
}
