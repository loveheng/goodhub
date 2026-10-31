package com.zzh.goodhub.engine

import com.zzh.goodhub.EngineStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// 会话票据回归钉（M1 Expand；设计 =
/// `docs/design/on-device-lifecycle-single-source.md` §2.2）。
///
/// epoch = `(instanceId, seq)` 复合键、**不做磁盘持久化**：进程重建即换
/// `instanceId`，因此「代次相同但实例不同」必须判为新会话——这是去持久化
/// 后唯一的正确性依据（端侧被 LMK 强杀时页缓存不可信，持久化单调是伪保证）。
class SessionTicketTest {
    private fun ticket(
        instanceId: String = "inst-a",
        seq: Long = 7,
        status: EngineStatus = EngineStatus.ready,
    ) = SessionTicket(
        instanceId = instanceId,
        seq = seq,
        status = status,
        modelId = "qwen3-5-2b-q4-0",
        runtime = "qairt",
        issuedAtMs = 1234L,
    )

    @Test
    fun `toMap-fromMap 往返无损`() {
        val t = ticket(status = EngineStatus.busy)
        val back = SessionTicket.fromMap(t.toMap())
        assertEquals(t, back)
    }

    @Test
    fun `fromMap 缺失关键字段 → null（解析失败禁造票据）`() {
        val full = ticket().toMap().toMutableMap()
        assertNull(SessionTicket.fromMap(full - SessionTicket.KEY_INSTANCE_ID))
        assertNull(SessionTicket.fromMap(full - SessionTicket.KEY_SEQ))
        assertNull(SessionTicket.fromMap(full - SessionTicket.KEY_STATUS))
        assertNull(SessionTicket.fromMap(emptyMap<String, Any?>()))
    }

    @Test
    fun `fromMap 序数越界 → null（防跨端漂移崩溃）`() {
        val m = ticket().toMap().toMutableMap()
        m[SessionTicket.KEY_STATUS] = 99
        assertNull(SessionTicket.fromMap(m))
    }

    @Test
    fun `sameEpoch：同实例同代次 = 同一会话`() {
        assertTrue(ticket().sameEpoch(ticket()))
    }

    @Test
    fun `sameEpoch：代次相同但进程重建（实例标识变）= 新会话`() {
        assertFalse(ticket().sameEpoch(ticket(instanceId = "inst-b")))
    }

    @Test
    fun `sameEpoch：同实例代次递增或递减 = 新会话；null = 非同会话`() {
        assertFalse(ticket(seq = 7).sameEpoch(ticket(seq = 8)))
        assertFalse(ticket(seq = 7).sameEpoch(ticket(seq = 6)))
        assertFalse(ticket().sameEpoch(null))
    }
}
