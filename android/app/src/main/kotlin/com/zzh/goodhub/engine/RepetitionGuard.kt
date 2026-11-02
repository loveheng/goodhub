package com.zzh.goodhub.engine

/**
 * 复读环检测看门狗（2026-11-02）：小模型（2B 级）在低熵陷阱里卡死重复同一
 * token / 短句（"12222222" 数字环、既知「首问 222222」现场、"好的好的好的…"
 * 句级环）。repetitionPenalty（1.05）只能缓解不能消除——本组件在 :engine
 * 文本流消费循环里对**已放行文本**做尾部复读检测，命中即令调用方 abort
 * （保留已放行内容，**不计数熔断**——复读 = 模型质量问题，非设备缺陷；
 * [DEGRADE] 日志留现场取证）。
 *
 * 判据（防误报优先）：尾部存在「短单元连续重复」——某长度 1~[maxUnitLen]
 * 的子串在末尾连续出现 ≥[minRepeat] 次，且单元含字母/数字（isLetterOrDigit）
 * ——排除 "，，，"、"……"、"----" 等纯标点/空白/分隔线环，正常停顿与
 * markdown 分隔线不误伤。
 *
 * 纯 Kotlin（无 Android 依赖），单测可直测；检测为纯函数 [isRepeating]，
 * 有状态 [feed] 只保留有界尾部窗口（环恒在尾部展开，前文无关）。
 */
class RepetitionGuard(
    private val minRepeat: Int = DEFAULT_MIN_REPEAT,
    private val maxUnitLen: Int = DEFAULT_MAX_UNIT_LEN,
) {
    private val cap = maxUnitLen * (minRepeat + maxUnitLen)
    private var tail = StringBuilder()
    private var total = 0

    /** 累计放行字符数（日志取证用，不受尾部窗口 cap 影响）。 */
    val totalChars: Int get() = total

    /** 喂入已放行文本；返回 true = 检测到复读环（应 abort）。 */
    fun feed(chunk: String): Boolean {
        if (chunk.isEmpty()) return false
        tail.append(chunk)
        if (tail.length > cap) tail.delete(0, tail.length - cap)
        total += chunk.length
        return isRepeating(tail.toString(), minRepeat, maxUnitLen)
    }

    /** 复位（新 query）。 */
    fun reset() {
        tail.setLength(0)
        total = 0
    }

    companion object {
        /**
         * 同单元连续出现次数下限。
         *
         * **4 定谳（2026-11-02 第三次真机反证）**：现场「12222」=「2」×4 连，
         * 6 阈值完整放行（用户可见退化输出）；降到 4 后 12222 截停为
         * 「122」。误伤面评估：判据要求单元含字母/数字，「哈哈哈哈」「好的
         * 好的」在 4 阈值下会截停尾部——正常中文语气词 4 连罕见、截停只截
         * 尾部不熔断，可接受；如再误伤只回调多字符单元档（单字符档保持 4）。
         */
        const val DEFAULT_MIN_REPEAT = 4

        /** 复读单元最大长度（字符）：覆盖单字符 / 短数字串 / 短句。 */
        const val DEFAULT_MAX_UNIT_LEN = 8

        /** 检测纯函数：判 [text] 尾部是否陷入复读环。 */
        fun isRepeating(text: String, minRepeat: Int, maxUnitLen: Int): Boolean {
            val L = text.length
            for (p in 1..maxUnitLen) {
                val run = p * minRepeat
                if (L < run) break // p 增窗口增 → 提前破
                val base = L - run
                // 周期性检查：text[base, base+run) p 周期 ⇔ 尾部 = 单元×minRepeat
                var periodic = true
                for (i in base until base + run - p) {
                    if (text[i] != text[i + p]) {
                        periodic = false
                        break
                    }
                }
                if (!periodic) continue
                // 单元须含字母/数字（防误报：标点/空白/分隔线环不触发）
                if (text.substring(base, base + p).any { it.isLetterOrDigit() }) return true
            }
            return false
        }
    }
}
