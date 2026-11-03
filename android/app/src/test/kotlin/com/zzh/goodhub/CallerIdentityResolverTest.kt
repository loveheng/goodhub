package com.zzh.goodhub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 调用方身份解析纯逻辑单测（task-capability W1-S07）。
 *
 * PackageManager 依赖面（getPackagesForUid / GET_SIGNING_CERTIFICATES）须真机
 * 或 Robolectric，纯 JVM 单测覆盖算法与值对象形状；resolve 的「失败返 null =
 * 拒绝语义」由反向通道接入时的集成测试 + 真机场次验收（W4）。
 */
class CallerIdentityResolverTest {

    @Test
    fun sha256Hex_同输入同输出_异输入异输出() {
        val a = CallerIdentityResolver.sha256Hex("com.example.app".toByteArray())
        val b = CallerIdentityResolver.sha256Hex("com.example.app".toByteArray())
        val c = CallerIdentityResolver.sha256Hex("com.example.app2".toByteArray())
        assertEquals(a, b)
        assertNotEquals(a, c)
    }

    @Test
    fun sha256Hex_格式口径_64位小写十六进制() {
        val hex = CallerIdentityResolver.sha256Hex(ByteArray(32))
        assertEquals(64, hex.length)
        assertTrue(hex.all { it in "0123456789abcdef" })
    }

    @Test
    fun callerIdentity_值对象形状_与信任白名单判据同源() {
        val id = CallerIdentityResolver.CallerIdentity(
            packageName = "com.example.app",
            signatureSha256 = "aa11",
        )
        assertEquals("com.example.app", id.packageName)
        assertEquals("aa11", id.signatureSha256)
        // 字段形状与 Dart 侧 Actor.app(packageName, signatureSha256) 对齐（S06）。
    }
}
