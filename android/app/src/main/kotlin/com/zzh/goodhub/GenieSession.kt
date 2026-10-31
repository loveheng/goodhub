package com.zzh.goodhub

import android.content.Context
import android.util.Log
import com.geniex.sdk.GenieXSdk
import com.geniex.sdk.LlmWrapper
import com.geniex.sdk.bean.ComputeUnitValue
import com.geniex.sdk.bean.GenerationConfig
import com.geniex.sdk.bean.LlmCreateInput
import com.geniex.sdk.bean.LlmStreamResult
import com.geniex.sdk.bean.ModelConfig
import com.geniex.sdk.bean.SamplerConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/// Genie 会话封装（on-device S3 换线）：`:engine` 的正式生成后端。
///
/// **实现 = 官方 geniex-android 0.3.5 AAR 管线**（Maven
/// `com.qualcomm.qti:geniex-android`，官方 GenieX Chat 同款），替换 S2 时期
/// 手写 JNI 捆裸 libGenie C API 的实现——4B 同资产同参数三方法对照钉死
/// 2.5× 代差在运行时管线层（官方 App 22.96 tok/s vs 裸 Genie 参考件与我方
/// 111.7ms 逐位一致），配置调参已榨干（+5% 量级）。
///
/// 对外公开面**与旧实现逐签名一致**（EngineService 零改动迁移）：
/// ready/busy/creating/abortRequested/loadError 状态位 + beginLoad/doLoad/
/// query/numGenerated/setPerfPolicy/abort/close；query 返回值口径
/// 0=SUCCESS / 1=ABORTED / 负=ERROR（§6.3 中断路径语义不变）。
///
/// 架构边界（solution-admission 2026-10-29）：仅换 `:engine` 推理后端实现，
/// 进程隔离/AIDL 控制面/两级熔断/资产 OTA 通道外围 100% 保留；旧的
/// cpp/genie_session.cpp + GenieSmoke 同轮退役（单实现，无双路分支）。
class GenieSession(private val context: Context) {

    companion object {
        private const val TAG = "GenieSession"

        private const val SDK_INIT_TIMEOUT_S = 15L

        /// abort() 有界等待 stopStream 返回的上限（毫秒）：中断信号尽快送达，
        /// 但 SDK 卡死不得占死调用线程（调用方含 Binder 线程池 → 卡死即全部
        /// AIDL 分派停摆 = 全局无响应，P2-13）。
        private const val ABORT_WAIT_MS = 300L
    }

    @Volatile private var wrapper: LlmWrapper? = null

    @Volatile var ready: Boolean = false
        private set

    // S3-3 起「生成在途」判据单源化至 engine/EngineSlot（策略 B + 抢占语义），
    // 本类不再承载 busy 位（双源易漂移）。

    /// loadModel 单飞闸（[beginLoad] synchronized 置位，[doLoad] finally 清除）。
    @Volatile var creating: Boolean = false
        private set

    /// cancel 信号（§6.3）：abort() 置位 → 流回调返回 false 停止；
    /// 下一次 query 起始清除（单执行槽，无跨请求污染）。
    @Volatile var abortRequested: Boolean = false
        private set

    /** 装载失败原因（诊断：loadModel 受理后未 ready 时读取）。 */
    @Volatile var loadError: String? = null

    /// 当前生效运行时（PLUGIN_ID_*）：qairt=NPU 主路 / llama_cpp=CPU 兜底。
    /// 供 :engine 日志可观测与后续 AIDL 回报（UI「端侧（CPU 兜底）」指示）；
    /// [close] 时复位为 qairt 默认。
    @Volatile var activeRuntime: String = GenieXSdk.PLUGIN_ID_QAIRT
        private set

    /** 上轮 query 的真实生成 token 数（Completed profile；-1=不可用）。 */
    @Volatile private var lastGeneratedTokens: Int = -1

    /** 上轮 query 的 SDK 性能画像（Completed profile；null=不可用）——TTFT/
     *  decodeSpan/numGenerated 的官方单源（2026-10-31 替代宿主手写秒表）。 */
    @Volatile var lastProfile: com.geniex.sdk.bean.ProfilingData? = null
        private set

    /** query 期间收集到的运行时错误（负状态码归因）。 */
    @Volatile private var lastStreamError: Throwable? = null

    // ---- SDK 初始化（进程级一次）----

    private val sdkInitLock = Any()
    private var sdkInitLatch: CountDownLatch? = null
    private var sdkInitFailed: String? = null

    /** GenieXSdk 环境初始化（幂等；阻塞至回调或超时，失败返回 false）。 */
    private fun ensureSdkInit(): Boolean {
        synchronized(sdkInitLock) {
            sdkInitLatch?.let { latch ->
                return latch.await(SDK_INIT_TIMEOUT_S, TimeUnit.SECONDS) && sdkInitFailed == null
            }
            val latch = CountDownLatch(1)
            sdkInitLatch = latch
            sdkInitFailed = null
            GenieXSdk.getInstance().init(
                context.applicationContext,
                object : GenieXSdk.InitCallback {
                    override fun onSuccess() {
                        Log.i(TAG, "GenieXSdk init ok")
                        latch.countDown()
                    }

                    override fun onFailure(reason: String) {
                        Log.e(TAG, "[DEGRADE] GenieXSdk init failed: $reason")
                        sdkInitFailed = reason
                        latch.countDown()
                    }
                },
            )
            val ok = latch.await(SDK_INIT_TIMEOUT_S, TimeUnit.SECONDS) && sdkInitFailed == null
            if (!ok && sdkInitFailed == null) {
                sdkInitFailed = "init callback timeout (${SDK_INIT_TIMEOUT_S}s)"
            }
            return ok
        }
    }

    /** 单飞闸：已 ready/creating 返回 false（不重建）。 */
    @Synchronized
    fun beginLoad(): Boolean {
        if (ready || creating) return false
        creating = true
        return true
    }

    /**
     * 会话创建（**阻塞数秒**——调用方必须置于后台线程）。前置：已获
     * [beginLoad]；finally 统一清除 creating 闸（异常不卡死后续装载）。
     */
    fun doLoad(modelDir: String) {
        try {
            if (ready) return
            loadError = null
            if (!ensureSdkInit()) {
                loadError = "GenieXSdk init failed: ${sdkInitFailed ?: "unknown"}"
                Log.e(TAG, "[DEGRADE] $loadError")
                return
            }
            val dir = File(modelDir)
            val configPath = File(dir, "genie_config.json")
            val tokenizerPath = File(dir, "tokenizer.json")
            // 运行时条件化资产门（2026-10-31 多模型导入制，decisions.md ADR④）：
            // qairt bundle 需 genie_config+tokenizer；纯 GGUF（llama.cpp 运行时）
            // 无此二件——旧门把 GGUF-only 资产挡在 llama_cpp 兜底之前，此处置条件。
            val ggufFiles = (dir.listFiles()
                ?.filter { it.isFile && it.name.lowercase().endsWith(".gguf") }
                ?: emptyList()).sortedBy { it.name }
            val hasGenie = configPath.isFile && tokenizerPath.isFile
            if (!hasGenie && ggufFiles.isEmpty()) {
                loadError = "asset layout: neither genie_config.json+tokenizer.json nor *.gguf in $modelDir"
                Log.e(TAG, "[DEGRADE] $loadError")
                return
            }
            Log.i(TAG, "diag modelDir exists=${dir.exists()} " +
                "canRead=${dir.canRead()} hasGenie=$hasGenie gguf=${ggufFiles.map { it.name }} " +
                "list=${dir.list()?.joinToString(",")}")
            // 资产真实性对账（S2-5 闪退换向）：目录名自拟不可信，逐文件尺寸进日志
            // ——4B@W4A16 全 bundle 预期 ~2.3GB，若合计 ~4.5GB+ 即导入误标大模型。
            Log.i(TAG, "diag sizes=" + (dir.listFiles()?.sortedBy { it.name }
                ?.joinToString(",") { "${it.name}=${it.length()}" }))
            // qairt 路径约束（官方 GenieX Chat 实证）：n_ctx/n_gpu_layers 编译
            // 期固定，非零值被拒绝——显式置 0。thinking 关闭移至 applyChatTemplate
            // 的 enableThinking 参数（0.10 起模板层承载，ModelConfig 不再有该字段）。
            val config = ModelConfig(nCtx = 0, nGpuLayers = 0)
            val buildInput = { runtimeId: String, unit: ComputeUnitValue ->
                LlmCreateInput(
                    model_path = configPath.absolutePath,
                    tokenizer_path = tokenizerPath.absolutePath,
                    config = config,
                    runtime_id = runtimeId,
                    compute_unit = unit.value,
                )
            }
            // 纯 GGUF 资产的 llama_cpp 输入。
            //   // UNCERTAIN: llama_cpp 的 model_path/tokenizer_path 契约未真机实证
            //   （spike #1 待冻结）：此处假设 model_path 指向 .gguf 文件、tokenizer
            //   在场则用独立 tokenizer.json、否则回指 .gguf（llama.cpp 读 GGUF 内嵌
            //   词表）。spike 实证后按实修正。
            val buildGguf = { unit: ComputeUnitValue ->
                LlmCreateInput(
                    model_path = ggufFiles.first().absolutePath,
                    tokenizer_path = if (tokenizerPath.isFile) tokenizerPath.absolutePath
                                    else ggufFiles.first().absolutePath,
                    config = config,
                    runtime_id = GenieXSdk.PLUGIN_ID_LLAMA_CPP,
                    compute_unit = unit.value,
                )
            }
            // 运行时选择（2026-10-31 NPU 兜底 + 多模型导入制，见 ADR）：
            // - qairt bundle → QAIRT+NPU 主路；NPU build 失败（驱动/HTP 不可用）
            //   → 回落 llama_cpp+CPU 完成本会话（同份资产，两插件 AAR 均捆绑）。
            // - 纯 GGUF → 直走 llama_cpp+CPU（qairt dispatch 强制 genie_config/
            //   metadata，此类资产走 qairt 必败，跳过必败尝试）。
            // **热/OOM 不触发兜底**——热→既有「禁 CPU 分流」决策，OOM→CPU 权重
            // 全驻 DRAM 反向，两者仍经既有决策收口云端。
            var active: String
            var result: Result<LlmWrapper>
            if (hasGenie) {
                active = GenieXSdk.PLUGIN_ID_QAIRT
                result = buildSession(buildInput(GenieXSdk.PLUGIN_ID_QAIRT, ComputeUnitValue.NPU))
                if (result.isFailure) {
                    Log.w(TAG, "[DEGRADE] QAIRT(NPU) build failed → fallback llama_cpp(CPU): " +
                        "${result.exceptionOrNull()?.message}")
                    result = buildSession(buildInput(GenieXSdk.PLUGIN_ID_LLAMA_CPP, ComputeUnitValue.CPU))
                    active = GenieXSdk.PLUGIN_ID_LLAMA_CPP
                }
            } else {
                // 纯 GGUF → llama_cpp 插件，**NPU 主路 + CPU 兜底**（2026-10-31
                // 用户拍板「使用 GenieX llama.cpp」；AI Hub 实证同款运行时在
                // 8 Elite NPU 上 22.6 tok/s decode → GenieX llama.cpp 插件
                // 可能接受 NPU）。NPU build 失败回落 CPU 完成本会话。
                //   // UNCERTAIN: llama_cpp 插件 compute_unit=NPU 契约未真机实证
                //   （spike 归因日志裁定）；model_path/tokenizer 同前述 UNCERTAIN。
                Log.i(TAG, "pure GGUF asset → llama_cpp direct (no genie_config), NPU primary")
                active = GenieXSdk.PLUGIN_ID_LLAMA_CPP
                result = buildSession(buildGguf(ComputeUnitValue.NPU))
                if (result.isFailure) {
                    Log.w(TAG, "[DEGRADE] llama_cpp(NPU) build failed → fallback llama_cpp(CPU): " +
                        "${result.exceptionOrNull()?.message}")
                    result = buildSession(buildGguf(ComputeUnitValue.CPU))
                }
            }
            activeRuntime = active
            result.fold(
                onSuccess = { w ->
                    wrapper = w
                    ready = true
                    Log.i(TAG, "session created (runtime=$active, geniex-android pipeline ready)")
                },
                onFailure = { e ->
                    loadError = "geniex build failed (runtime=$active): ${e.message}"
                    Log.e(TAG, "[DEGRADE] $loadError")
                },
            )
        } catch (e: Throwable) {
            loadError = "doLoad: $e"
            Log.e(TAG, "[DEGRADE] session load failed: $e")
        } finally {
            creating = false
            // 装载收尾：分片已读完并解析完成 → 页缓存可归还（posix_fadvise
            // DONTNEED）。执行面在**主进程** native 通道（libgdw 仅主进程加载；
            // 页缓存按 inode 记账，主进程丢弃等价有效）——:engine 侧仅交接留痕。
            // 边界：仅削「装载后的稳态恢复」，削不平装载瞬态尖峰。
            Log.i(TAG, "shards parsed: page-cache reclaim handed to host ($modelDir)")
        }
    }

    /**
     * 建一个 LlmWrapper 会话（**阻塞数秒**——调用方须置于后台线程；[beginLoad]
     * 单飞闸由调用方负责）。统一返回 [Result]：SDK build() 的 Failure 与
     * builder 链异常一并折成 Failure，供调用方做主/兜底判定。
     */
    private fun buildSession(input: LlmCreateInput): Result<LlmWrapper> = runCatching {
        runBlocking {
            LlmWrapper.builder()
                .llmCreateInput(input)
                .dispatcher(Dispatchers.Default)
                .build()
                .getOrThrow()
        }
    }

    /**
     * 标记装载失败原因（供外部中止路径使用，如装载期热降级 abort）——
     * [loadError] 会被 startGenerate 的「会话未就绪」异常带给主进程，
     * 从而以**明确原因**上抛（而非静默 assetMissing）。
     */
    fun markLoadError(reason: String) {
        loadError = reason
    }

    /**
     * 同步生成（阻塞至完成/abort）；文本块经 [sink] 投递。返回
     * 0=SUCCESS / 1=ABORTED / 负=ERROR（§6.3 口径与旧实现一致）。
     *
     * 每请求 [LlmWrapper.reset] 单发隔离（KV 清空，与旧 dialogReset 语义
     * 对齐）；流式回调在插件线程，Token 回调返回 false 即停（abort 路径）。
     */
    fun query(
        prompt: String,
        maxTokens: Int,
        sink: GenieChunkSink,
        temperature: Float = 0.7f,
        topP: Float = 0.8f,
    ): Int {
        val w = wrapper ?: throw IllegalStateException("genie session not created")
        abortRequested = false
        lastStreamError = null
        lastGeneratedTokens = -1
        lastProfile = null
        Log.i(TAG, "query start: promptChars=${prompt.length} maxTokens=$maxTokens")
        // 单发隔离的会话重置（每请求清 KV）：重置失败后**带病生成 = 零产出且
        // 无归因**（真机实证「同一对话第二次提问没有输出」的候选面之一——
        // 首轮会话刚建好时 reset 正常，第二次 reset 失败即整轮空转）——故
        // 重试一次；仍失败则**显式失败**（负状态码 → 主进程切云），禁静默
        // 生成空结果冒充「模型没话说」。
        var resetStatus = runBlocking { w.reset() }
        if (resetStatus != 0) {
            Log.w(TAG, "[DEGRADE] reset before query: status=$resetStatus — retry once")
            resetStatus = runBlocking { w.reset() }
            if (resetStatus != 0) {
                Log.e(TAG, "[DEGRADE] reset failed twice: status=$resetStatus — abort query")
                return -2
            }
        }
        // ChatML 模板包装（2026-10-31 设计修正·第二刀，对齐官方 demo）：
        // **SDK applyChatTemplate 优先**——消息序列 JSON 经 parseMessages 转
        // ChatMessage[]，按模型资产内嵌 tokenizer 模板渲染（官方明示 native
        // 管线把 prompt 当已模板化文本，raw/自绘近似模板喂入 = 退化输出，
        // 复读环真根因）。失败逐级 fallback：ChatMLComposer 手写多轮 → 旧
        // 单轮包装。enableThinking=false（Instruct 行为）+ addGenerationPrompt=true。
        // UNCERTAIN: 资产家族假设 = Qwen/ChatML（目录当前仅 Qwen 资产）。
        val chatPrompt = run {
            val msgs = com.zzh.goodhub.engine.ChatMLComposer.parseMessages(prompt)
            if (msgs != null) {
                runCatching {
                    runBlocking { w.applyChatTemplate(msgs, null, false, true) }
                        .getOrThrow().formattedText
                }.onFailure {
                    Log.w(TAG, "[DEGRADE] applyChatTemplate failed → fallback: $it")
                }.getOrNull()
            } else null
        } ?: com.zzh.goodhub.engine.ChatMLComposer.compose(prompt)
            ?: run {
                val safePrompt = sanitizeChatMLControlTokens(prompt)
                "<|im_start|>user\n$safePrompt<|im_end|>\n<|im_start|>assistant\n"
            }
        var status = 0
        val queryStart = System.currentTimeMillis()
        var firstTokenAt = 0L
        val sanitizer = StreamTextSanitizer()
        val flow = w.generateStreamFlow(
            chatPrompt,
            // 0.10 起签名 = (prompt?, inputIds?, inputEmbd?, inputEmbdDim, config)
            // ——config 走命名参数（inputIds/inputEmbd 默认 null 不用）。
            // 采样接线：此前只有 maxTokens（temperature/topP 随 AIDL 送达却被
            // 丢弃），SDK 默认采样无复读惩罚 → 复读环无自愈手段。
            // stopWords 勿传（2026-10-30 真机实证）：qairt 插件拒收 --stop /
            // --stop-file 参数（geniex ErrorCode -100016 直接拒绝整个
            // generate → 零 token = Dart 侧「空产出」）。EOS 停止为管线内置，
            // 不依赖 stop 序列；im_end 残留由下方 sink 截断兜底。
            config = GenerationConfig(
                maxTokens = maxTokens,
                samplerConfig = SamplerConfig(
                    temperature = temperature,
                    topP = topP,
                    repetitionPenalty = 1.05f,
                ),
            ),
        )
        runBlocking {
            flow.collect { result ->
                when (result) {
                    is LlmStreamResult.Token -> {
                        if (abortRequested) return@collect
                        // stopWords 已随 qairt 兼容性移除（见 GenerationConfig
                        // 注），EOS 停止由管线内置；im_end 若仍漏进文本则截断。
                        val text = result.text
                        if (firstTokenAt == 0L) {
                            firstTokenAt = System.currentTimeMillis()
                            Log.i(TAG, "first token after ${firstTokenAt - queryStart}ms")
                        }
                        val cut = text.indexOf("<|im_end|>")
                        if (cut >= 0) {
                            val head = sanitizer.feed(text.substring(0, cut))
                            if (head.isNotEmpty()) sink.onChunk(head)
                            // 零内容早停 = 模型在首个 token 就闭合模板（本轮零产出
                            // 的直接证据；与「复读到 maxTokens」是两种不同病灶）。
                            Log.i(TAG, "im_end observed in stream -> stop (headChars=${head.length})")
                            abortRequested = true
                        } else {
                            // 乱码还原 + think 剥离（StreamTextSanitizer doc）
                            val clean = sanitizer.feed(text)
                            if (clean.isNotEmpty()) sink.onChunk(clean)
                        }
                    }
                    is LlmStreamResult.Completed -> {
                        val p = result.profile
                        if (!abortRequested) {
                            val rest = sanitizer.flush()
                            if (rest.isNotEmpty()) sink.onChunk(rest)
                        }
                        lastGeneratedTokens = p.generatedTokens.toInt()
                        lastProfile = p
                        Log.i(TAG, "bench: ttft=${p.ttftMs.toInt()}ms " +
                            "decodeSpan=${p.decodeTimeMs.toInt()}ms " +
                            "chunks=${p.generatedTokens} numGenerated=${p.generatedTokens} " +
                            "tpot=${if (p.generatedTokens > 0) p.decodeTimeMs / p.generatedTokens else 0.0}ms/token " +
                            "speed=${p.decodingSpeed}tok/s")
                    }
                    is LlmStreamResult.Error -> {
                        lastStreamError = result.throwable
                        Log.w(TAG, "[DEGRADE] genie stream error: ${result.throwable}")
                    }
                }
            }
        }
        if (abortRequested) {
            status = 1
        } else if (lastStreamError != null) {
            status = -1
        }
        return status
    }

    /// 上次 query 的 SDK 性能画像单源 = [lastProfile]（Completed profile：
    /// ttft/decodeSpan/generatedTokens/decodingSpeed/stopReason）——宿主手写
    /// 秒表与 numGenerated 查询面已退役（2026-10-31 替代）。

    /// cancel 信号（§6.3）：置位 + 流回调停（Token 返回 false），query 以
    /// cancelled 收尾；清空在途由插件侧停止承载。
    /**
     * 中断在途生成（§6.3）。
     *
     * **非阻塞 + 有界**：stopStream 走 `runBlocking` 会在调用线程同步等待 SDK
     * 返回——调用方含 Binder 线程池（cancelGenerate）与抢占路径（startGenerate
     * 同线程）→ SDK 一旦卡住即 Binder 线程池停摆（全部 AIDL 分派阻塞 = 全局
     * 「无响应」，P2-13 登记面）。故：中断信号在后台线程发出，调用方**有界**
     * 等待（≤[waitMs]）——既保证信号尽快送达（抢占让槽的前提），又不占死
     * 调用线程。
     */
    fun abort(waitMs: Long = ABORT_WAIT_MS) {
        abortRequested = true
        val w = wrapper ?: return
        val done = java.util.concurrent.CountDownLatch(1)
        Thread({
            try {
                runBlocking { w.stopStream() }
            } catch (e: Throwable) {
                Log.w(TAG, "[DEGRADE] stopStream: $e")
            } finally {
                done.countDown()
            }
        }, "engine-abort").start()
        runCatching { done.await(waitMs, TimeUnit.MILLISECONDS) }
    }

    fun close() {
        val w = wrapper ?: return
        wrapper = null
        ready = false
        try {
            w.destroy()
        } catch (e: Throwable) {
            Log.w(TAG, "[DEGRADE] destroy: $e")
        }
    }

    /// ChatML 控制 token（Qwen 系）——出现在正文里会破坏模板边界
    /// （`<|im_end|>` 提前闭合 user 轮 → 模型直接收尾 → **零产出**）。
    private val chatMlControlToken =
        Regex("<\\|(?:im_start|im_end|im_sep|endoftext)\\|>")

    /// 清洗 ChatML 控制 token（模板级兜底；见 [query] 注释）。
    private fun sanitizeChatMLControlTokens(text: String): String =
        chatMlControlToken.replace(text, "")
}

/// 生成块下沉（geniex-android 流回调 → EngineService bench/投递层）。
/// 载荷已由插件侧 detokenize 为文本块（UTF-8 完整边界由运行时保证）。
fun interface GenieChunkSink {
    fun onChunk(text: String)
}

/**
 * 流式投递前的文本修复管线（2026-10-30 真机实证两缺陷）：
 *
 * 1. **跨 token 多字节 UTF-8 拆裂还原**：geniex-android SDK 流式增量
 *    detokenize 把跨 token 边界的 UTF-8 序列按单字节（ISO-8859-1 语义）
 *    解码 →「中」(E4 B8 AD) 变 "ä¸­" 型乱码（SDK 回调面只有
 *    `Token(String)`，无字节/token-id 出口，上游不可修，native full_text
 *    同样带乱码可证病在 SDK 内部）。还原：连续 latin1 区（U+0080..U+00FF）
 *    字符视为疑似被拆裂字节（charCode 即原字节值），成段重组按 UTF-8
 *    严格解码，成功且含非 ASCII 即替换；段尾可能是未收全的跨块序列 →
 *    留待下一块再判（flush 时原样放行）。
 * 2. **think 块剥离**：Qwen3 思考模式输出 `ilden...` 原文直达 UI；
 *    SDK 无 think 开关，此处跨块状态机剥除（未闭合则整段按思考吞掉）。
 */
internal class StreamTextSanitizer {
    private enum class ThinkMode { OUTSIDE, INSIDE }
    private var thinkMode = ThinkMode.OUTSIDE
    private var pending = StringBuilder()

    /** 喂入一块原始 token 文本，返回可投递部分（可能为空）。 */
    fun feed(text: String): String {
        if (text.isEmpty()) return ""
        val s = pending.toString() + text
        pending = StringBuilder()
        val repaired = StringBuilder()
        var i = 0
        val n = s.length
        while (i < n) {
            val c = s[i]
            if (c.code in 0x80..0xFF) {
                var j = i
                while (j < n && s[j].code in 0x80..0xFF) j++
                val run = s.substring(i, j)
                val decoded = tryDecodeUtf8(run)
                when {
                    decoded != null -> {
                        repaired.append(decoded)
                        i = j
                    }
                    j == n -> {
                        // 尾段可能是未收全的跨块多字节序列 → 留待下一块
                        pending.append(run)
                        i = j
                    }
                    else -> {
                        repaired.append(run) // 中段解不出 → 原样放行
                        i = j
                    }
                }
            } else {
                repaired.append(c)
                i++
            }
        }
        return stripThink(repaired.toString())
    }

    /** 流收尾：未决 latin1 尾段原样放行（think 未闭合则吞掉）。 */
    fun flush(): String {
        val rest = pending.toString()
        pending = StringBuilder()
        if (thinkMode == ThinkMode.INSIDE) return ""
        return stripThink(rest)
    }

    /** latin1 段重组按 UTF-8 严格解码；解出须含非 ASCII（防误吞真 latin1）。 */
    private fun tryDecodeUtf8(s: String): String? {
        if (s.isEmpty()) return null
        val bytes = ByteArray(s.length) { s[it].code.toByte() }
        return try {
            val dec = Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            val r = dec.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            if (r.any { it.code > 0x7F }) r else null
        } catch (e: java.nio.charset.CharacterCodingException) {
            null
        }
    }

    /**
     * think 块跨块剥离状态机（标签可能被拆在两块边界）。两态：
     * OUTSIDE 剔除 open（转 INSIDE）**与游离 close**（2026-10-30 真机实证：
     * enable_thinking=false 下模型偶发直出无配对的闭合标签，须同步剔除）；
     * INSIDE 吞到 close 为止（未闭合整段按思考吞掉）。
     */
    private fun stripThink(text: String): String {
        if (text.isEmpty()) return text
        val out = StringBuilder()
        var i = 0
        while (i < text.length) {
            if (thinkMode == ThinkMode.INSIDE) {
                val c = text.indexOf(THINK_CLOSE, i)
                if (c >= 0) {
                    thinkMode = ThinkMode.OUTSIDE
                    i = c + THINK_CLOSE.length
                } else {
                    val hold = partialTagTail(text.substring(i), THINK_CLOSE)
                    pending.insert(0, text.substring(text.length - hold))
                    i = text.length // 思考内容整段吞掉
                }
            } else {
                val o = text.indexOf(THINK_OPEN, i)
                val c = text.indexOf(THINK_CLOSE, i)
                when {
                    o >= 0 && (c < 0 || o < c) -> {
                        out.append(text, i, o)
                        thinkMode = ThinkMode.INSIDE
                        i = o + THINK_OPEN.length
                    }
                    c >= 0 -> {
                        out.append(text, i, c) // 游离闭合标签：剔除不投递
                        i = c + THINK_CLOSE.length
                    }
                    else -> {
                        val hold = maxOf(
                            partialTagTail(text.substring(i), THINK_OPEN),
                            partialTagTail(text.substring(i), THINK_CLOSE),
                        )
                        out.append(text, i, text.length - hold)
                        pending.insert(0, text.substring(text.length - hold))
                        i = text.length
                    }
                }
            }
        }
        return out.toString()
    }

    /** s 的最长后缀同时是 tag 的真前缀（防标签跨块拆裂漏识别）。 */
    private fun partialTagTail(s: String, tag: String): Int {
        val max = minOf(tag.length - 1, s.length)
        for (l in max downTo 1) {
            if (s.regionMatches(s.length - l, tag, 0, l)) return l
        }
        return 0
    }

    private companion object {
        // "<think>" / "</think>" 以转义写死（裸标签过通道会被转写损坏）。
        const val THINK_OPEN = "\u003c\u0074\u0068\u0069\u006e\u006b\u003e"
        const val THINK_CLOSE = "\u003c\u002f\u0074\u0068\u0069\u006e\u006b\u003e"
    }
}
