package com.zzh.goodhub.engine

import com.zzh.goodhub.GenieChunkSink

/**
 * 统一推理画像（Runner 中立归因面）。
 *
 * 各 Runner 自治填充：GenieX = SDK ProfilingData 映射（官方单源）；LiteRT-LM =
 * 宿主秒表口径（SDK 回调面无 token 计数，generatedTokens=-1 诚实归因，禁猜测）。
 * EngineService 收尾打点消费本类型（不再耦合 GenieX ProfilingData）。
 */
data class EngineProfile(
    val ttftMs: Double = 0.0,
    val decodeTimeMs: Double = 0.0,
    val generatedTokens: Int = -1,
    val decodingSpeed: Double = 0.0,
    val stopReason: String = "",
)

/**
 * 推理 Runner（多栈构型 ADR 2026-11-01）：`:engine` 推理后端能力槽。
 *
 * **资产族定栈**（D-1 双段路由）：`loadModel` 入口单点分派（EngineService 注册表），
 * 调用链无双路分支——进程级外围防护（单执行槽 / epoch 闸 / 数据面 / 墓碑 / FGS /
 * TTL / 两级熔断）全部在 EngineService 层，Runner 无关、零改动（与 2026-10-29
 * GenieX 换线同层：「仅换 :engine 推理后端实现，外围 100% 保留」）。
 *
 * 实现：GenieSession（GenieX 系：QAIRT+NPU 主路 / llama_cpp+GPU 档）/
 * LiteRtLmRunner（LiteRT-LM 系：NPU → GPU → 云端收口，CPU 全程出局）。
 * 注册表扩展位：NeuroPilot（多栈 ADR「接口留位」，不实现不排期；重评触发 =
 * .litertlm NPU 资产目录扩展或天玑真机到位）。
 */
interface OnDeviceRunner {
    val ready: Boolean
    val creating: Boolean
    val abortRequested: Boolean
    /** 装载失败原因（诊断：装载受理后未 ready 时读取；doLoad 可写回）。 */
    var loadError: String?

    /** 当前生效运行时（诊断归因 / 票据 runtime 字段）：
     *  qairt / llama_cpp（GenieX 系）/ litertlm-npu / litertlm-gpu（LiteRT-LM 系）。 */
    val activeRuntime: String

    /** 上轮 query 推理画像（null=不可用，诚实归因）。 */
    val lastProfile: EngineProfile?

    /** 装载单飞闸（synchronized 置位，doLoad finally 清除）；false=已有装载在途。 */
    fun beginLoad(): Boolean

    /** 装载（engine-model-load 后台线程执行）；成功 ready=true，失败置 loadError。 */
    fun doLoad(modelDir: String, backendHint: String? = null)

    /** 同步生成（阻塞至完成/abort，engine-genie-generate 线程执行）。
     *  返回 0=SUCCESS / 1=ABORTED / 负=ERROR——通用负码：-2=会话未就绪 /
     *  -3=prompt 形态非法；各 Runner 可扩展负码但必须显式归因（禁静默）。 */
    fun query(
        prompt: String,
        maxTokens: Int,
        sink: GenieChunkSink,
        temperature: Float,
        topP: Float,
        stopSequences: List<String>,
    ): Int

    /** 取消信号（§6.3）；无在途请求时调用须安全（幂等无害）。 */
    fun abort()

    /** 析构（权重释放）；执行后 ready=false。 */
    fun close()
}
