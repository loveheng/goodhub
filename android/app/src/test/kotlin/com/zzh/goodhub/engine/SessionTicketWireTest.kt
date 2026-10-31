package com.zzh.goodhub.engine

import com.zzh.goodhub.EngineStatus
import com.zzh.goodhub.engine.GenerationParams
import com.zzh.goodhub.engine.SessionTicket
import com.zzh.goodhub.engine.SessionTicketWire.ticketFromBundle
import com.zzh.goodhub.engine.SessionTicketWire.toBundle
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Bundle 缝回归钉（2026-10-31 checkSession 事故）：
 * `SessionTicketWire` / `GenerationParams` 是 AIDL↔MethodChannel Bundle 缝的
 * **唯一**转换点——本测钉死 Bundle↔参数↔Map 往返不丢键不失真；适配点字段
 * 演进时漏改任一侧在此即红。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SessionTicketWireTest {

    @Test
    fun `票据 toBundle - fromBundle 往返保真`() {
        val t = SessionTicket(
            instanceId = "inst-uuid",
            seq = 7L,
            status = EngineStatus.ready,
            modelId = "qwen3-4b",
            runtime = "qairt",
            issuedAtMs = 1730000000000L,
        )
        val back = SessionTicketWire.ticketFromBundle(t.toBundle())
        assertEquals(t, back)
    }

    @Test
    fun `票据 Bundle 转通道 Map 与 toMap 对称（Dart tryParse 契约面）`() {
        val t = SessionTicket(
            instanceId = "inst-uuid",
            seq = 3L,
            status = EngineStatus.busy,
            modelId = "m",
            runtime = "llama_cpp",
            issuedAtMs = 42L,
        )
        val map = SessionTicketWire.ticketChannelMap(t.toBundle())
        assertEquals(t.toMap(), map)
    }

    @Test
    fun `空 Bundle 解码为 null 或空 Map（禁造票据）`() {
        assertNull(SessionTicketWire.ticketFromBundle(android.os.Bundle()))
        assertTrue(SessionTicketWire.ticketChannelMap(android.os.Bundle()).isEmpty())
    }

    @Test
    fun `生成参数 args - Bundle - 解码往返保真（键名缺省值单源）`() {
        val p = GenerationParams(
            maxTokens = 1024,
            temperature = 0.3,
            topP = 0.95,
            stopTokenIds = intArrayOf(1, 2, 3),
            foreground = true,
        )
        val back = GenerationParams.fromBundle(p.toBundle())
        assertEquals(p, back)
        // 通道 Map 入向等价：fromArgs 与直接构造产物 Bundle 一致。
        val viaArgs = GenerationParams.fromArgs(
            mapOf(
                "maxTokens" to 1024,
                "temperature" to 0.3,
                "topP" to 0.95,
                "stopTokenIds" to listOf(1, 2, 3),
            ),
            foreground = true,
        )
        assertEquals(p, viaArgs)
    }

    @Test
    fun `生成参数缺省值单源 空args与空Bundle落同一缺省 topP漂移防再犯`() {
        val fromArgs = GenerationParams.fromArgs(emptyMap<Object, Object>(), foreground = false)
        val fromBundle = GenerationParams.fromBundle(null)
        assertEquals(fromArgs, fromBundle)
        assertEquals(0.9, fromBundle.topP, 0.0)
        assertEquals(512, fromBundle.maxTokens)
        assertEquals(0.7, fromBundle.temperature, 0.0)
        assertArrayEquals(IntArray(0), fromBundle.stopTokenIds)
    }
}
