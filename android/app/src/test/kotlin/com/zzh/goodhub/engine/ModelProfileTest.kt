package com.zzh.goodhub.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * ModelProfile 回归钉（声明式解析元数据，2026-11-02）：`.asset-meta.json`
 * 的 modelProfile 块读取面——缺失/无块/空块/坏 JSON 一律 null 不抛（meta
 * 是增强面非门禁），合法块全字段解析。
 *
 * Robolectric 运行器（org.json 本地单测依赖，同 ChatMLComposerTest）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ModelProfileTest {

    @get:Rule
    val tmp = org.junit.rules.TemporaryFolder()

    /** 每用例独占目录（单用例内可多次覆写 meta，禁重复 newFolder）。 */
    private lateinit var dir: File

    private fun writeMeta(json: String?) {
        if (!::dir.isInitialized) dir = tmp.newFolder("model")
        val f = File(dir, ".asset-meta.json")
        if (json != null) f.writeText(json) else f.delete()
    }

    private fun read(): ModelProfile? = ModelProfile.read(dir.absolutePath)

    @Test
    fun 合法块全字段解析() {
        writeMeta(
            """{"runtime":"llama_cpp","modelProfile":{
                "chatTemplateFamily":"qwen_chatml",
                "stopSequences":["<|im_end|>"],
                "contextTokens":32768}}""",
        )
        val p = read()!!
        assertEquals("qwen_chatml", p.chatTemplateFamily)
        assertEquals(listOf("<|im_end|>"), p.stopSequences)
        assertEquals(32768, p.contextTokens)
    }

    @Test
    fun 无meta文件_无块_空块_坏JSON_一律null不抛() {
        // meta 文件缺席（空目录）
        dir = tmp.newFolder("missing")
        assertNull(ModelProfile.read(dir.absolutePath))

        // 无块
        writeMeta("""{"runtime":"llama_cpp"}""")
        assertNull(read())
        // 空块
        writeMeta("""{"modelProfile":{}}""")
        assertNull(read())
        // 坏 JSON
        writeMeta("""{"modelProfile": """)
        assertNull(read())
    }

    @Test
    fun 停用词数组空串过滤_仅空串等价无字段() {
        writeMeta(
            """{"modelProfile":{"stopSequences":["","<end_of_turn>"]}}""",
        )
        val p = read()!!
        assertTrue(p.stopSequences.size == 1 && p.stopSequences[0] == "<end_of_turn>")

        writeMeta("""{"modelProfile":{"stopSequences":[""]}}""")
        assertNull(read())
    }
}
