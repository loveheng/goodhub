package com.zzh.goodhub.engine

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * NPU 熔断器重置语义（2026-11-02 复合键 `fingerprint|versionCode`）：
 * 单测环境无 Android 框架，走 internal (sp, resetKey) 重载 + 内存 [FakeSp]。
 */
/** 哨兵：FakeSp.Editor 的删除标记（顶层——inner 跨非 inner 嵌套不可引用成员）。 */
private val REMOVED = Any()

class NpuCircuitBreakerTest {

    private class FakeSp : SharedPreferences {
        private val map = HashMap<String, Any?>()

        override fun getAll(): MutableMap<String, *> = HashMap(map)
        override fun getString(key: String?, defValue: String?): String? =
            map[key] as? String ?: defValue
        override fun getStringSet(
            key: String?, defValues: MutableSet<String>?
        ): MutableSet<String> =
            map[key] as? MutableSet<String> ?: defValues ?: mutableSetOf()
        override fun getInt(key: String?, defValue: Int): Int = map[key] as? Int ?: defValue
        override fun getLong(key: String?, defValue: Long): Long = map[key] as? Long ?: defValue
        override fun getFloat(key: String?, defValue: Float): Float =
            map[key] as? Float ?: defValue
        override fun getBoolean(key: String?, defValue: Boolean): Boolean =
            map[key] as? Boolean ?: defValue
        override fun contains(key: String?): Boolean = key != null && map.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?
        ) {}
        override fun unregisterOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?
        ) {}

        private inner class Editor : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private var toClear = false

            override fun putString(key: String?, value: String?) =
                apply { if (key != null) pending[key] = value }
            override fun putStringSet(key: String?, values: MutableSet<String>?) =
                apply { if (key != null) pending[key] = values?.toMutableSet() }
            override fun putInt(key: String?, value: Int) =
                apply { if (key != null) pending[key] = value }
            override fun putLong(key: String?, value: Long) =
                apply { if (key != null) pending[key] = value }
            override fun putFloat(key: String?, value: Float) =
                apply { if (key != null) pending[key] = value }
            override fun putBoolean(key: String?, value: Boolean) =
                apply { if (key != null) pending[key] = value }
            override fun remove(key: String?) =
                apply { if (key != null) pending[key] = REMOVED }
            override fun clear() = apply { toClear = true }
            override fun commit(): Boolean {
                if (toClear) {
                    map.clear()
                    toClear = false
                }
                for ((k, v) in pending) {
                    if (v === REMOVED) map.remove(k) else map[k] = v
                }
                pending.clear()
                return true
            }
            override fun apply() {}
        }
    }

    private fun sp() = FakeSp()

    @Test
    fun `trip 后同重置键 isTripped 为 true`() {
        val s = sp()
        NpuCircuitBreaker.trip(s, "fp1|100", "geniex", 79, "sun", "qairt_build_failed:X")
        assertTrue(NpuCircuitBreaker.isTripped(s, "fp1|100", "geniex", 79, "sun"))
    }

    @Test
    fun `App 版本变更 → 自动重置放行（坏机型用户升级新包后 NPU 复活）`() {
        val s = sp()
        NpuCircuitBreaker.trip(s, "fp1|100", "geniex", 79, "sun", "r")
        assertTrue(NpuCircuitBreaker.isTripped(s, "fp1|100", "geniex", 79, "sun"))
        assertFalse(NpuCircuitBreaker.isTripped(s, "fp1|101", "geniex", 79, "sun"))
    }

    @Test
    fun `系统指纹变更（OTA）→ 自动重置放行`() {
        val s = sp()
        NpuCircuitBreaker.trip(s, "fp1|100", "geniex", 79, "sun", "r")
        assertFalse(NpuCircuitBreaker.isTripped(s, "fp2|100", "geniex", 79, "sun"))
    }

    @Test
    fun `重置键变更时旧标记被清空（防残留）`() {
        val s = sp()
        NpuCircuitBreaker.trip(s, "fp1|100", "geniex", 79, "sun", "r")
        assertTrue(s.contains("breaker_geniex_79_sun"))
        NpuCircuitBreaker.isTripped(s, "fp1|101", "geniex", 79, "sun") // 触发重置
        assertFalse(s.contains("breaker_geniex_79_sun"))
        assertFalse(s.contains("breaker_geniex_79_sun_reason"))
        assertTrue(s.contains("last_reset_key"))
    }

    @Test
    fun `族粒度独立：litertlm 熔断不影响 geniex`() {
        val s = sp()
        val key = "fp1|100"
        NpuCircuitBreaker.trip(s, key, "litertlm", 79, "sun", "r")
        assertTrue(NpuCircuitBreaker.isTripped(s, key, "litertlm", 79, "sun"))
        assertFalse(NpuCircuitBreaker.isTripped(s, key, "geniex", 79, "sun"))
    }

    @Test
    fun `trippedReason 留痕与 reset 全清`() {
        val s = sp()
        val key = "fp1|100"
        NpuCircuitBreaker.trip(s, key, "geniex", 79, "sun", "npu_init_failed:Timeout")
        assertEquals(
            "npu_init_failed:Timeout",
            NpuCircuitBreaker.trippedReason(s, "geniex", 79, "sun")
        )
        NpuCircuitBreaker.reset(s)
        assertFalse(NpuCircuitBreaker.isTripped(s, key, "geniex", 79, "sun"))
        assertEquals(null, NpuCircuitBreaker.trippedReason(s, "geniex", 79, "sun"))
    }
}
