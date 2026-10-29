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

    /** 上轮 query 的真实生成 token 数（Completed profile；-1=不可用）。 */
    @Volatile private var lastGeneratedTokens: Int = -1

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
            if (!configPath.isFile || !tokenizerPath.isFile) {
                loadError = "asset layout: genie_config.json/tokenizer.json missing in $modelDir"
                Log.e(TAG, "[DEGRADE] $loadError")
                return
            }
            Log.i(TAG, "diag modelDir exists=${dir.exists()} " +
                "canRead=${dir.canRead()} list=${dir.list()?.joinToString(",")}")
            // qairt 路径约束（官方 GenieX Chat 实证）：n_ctx/n_gpu_layers 编译
            // 期固定，非零值被拒绝——显式置 0；thinking 关闭（单发提取语义）。
            val config = ModelConfig(nCtx = 0, nGpuLayers = 0, enable_thinking = false)
            val input = LlmCreateInput(
                model_name = dir.name,
                model_path = configPath.absolutePath,
                tokenizer_path = tokenizerPath.absolutePath,
                config = config,
                runtime_id = GenieXSdk.PLUGIN_ID_QAIRT,
                compute_unit = ComputeUnitValue.NPU.value,
            )
            val result = runBlocking {
                LlmWrapper.builder()
                    .llmCreateInput(input)
                    .dispatcher(Dispatchers.Default)
                    .build()
            }
            result.fold(
                onSuccess = { w ->
                    wrapper = w
                    ready = true
                    Log.i(TAG, "session created (geniex-android pipeline ready)")
                },
                onFailure = { e ->
                    loadError = "geniex build failed: ${e.message}"
                    Log.e(TAG, "[DEGRADE] $loadError")
                },
            )
        } catch (e: Throwable) {
            loadError = "doLoad: $e"
            Log.e(TAG, "[DEGRADE] session load failed: $e")
        } finally {
            creating = false
        }
    }

    /**
     * 同步生成（阻塞至完成/abort）；文本块经 [sink] 投递。返回
     * 0=SUCCESS / 1=ABORTED / 负=ERROR（§6.3 口径与旧实现一致）。
     *
     * 每请求 [LlmWrapper.reset] 单发隔离（KV 清空，与旧 dialogReset 语义
     * 对齐）；流式回调在插件线程，Token 回调返回 false 即停（abort 路径）。
     */
    fun query(prompt: String, maxTokens: Int, sink: GenieChunkSink): Int {
        val w = wrapper ?: throw IllegalStateException("genie session not created")
        abortRequested = false
        lastStreamError = null
        lastGeneratedTokens = -1
        val resetStatus = runBlocking { w.reset() }
        if (resetStatus != 0) {
            Log.w(TAG, "[DEGRADE] reset before query: status=$resetStatus")
        }
        var status = 0
        val flow = w.generateStreamFlow(
            prompt,
            GenerationConfig(maxTokens = maxTokens),
        )
        runBlocking {
            flow.collect { result ->
                when (result) {
                    is LlmStreamResult.Token -> {
                        if (abortRequested) return@collect
                        sink.onChunk(result.text)
                    }
                    is LlmStreamResult.Completed -> {
                        val p = result.profile
                        lastGeneratedTokens = p.generatedTokens.toInt()
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

    /// 上次 query 的**真实生成 token 数**（Completed profiling；
    /// geniex-android 管线原生提供，替代旧 GenieDialog_getValue 探针）。
    /// 返回 -1 = 不可用。
    fun numGenerated(): Int = lastGeneratedTokens

    /// cancel 信号（§6.3）：置位 + 流回调停（Token 返回 false），query 以
    /// cancelled 收尾；清空在途由插件侧停止承载。
    fun abort() {
        abortRequested = true
        val w = wrapper ?: return
        try {
            runBlocking { w.stopStream() }
        } catch (e: Throwable) {
            Log.w(TAG, "[DEGRADE] stopStream: $e")
        }
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
}

/// 生成块下沉（geniex-android 流回调 → EngineService bench/投递层）。
/// 载荷已由插件侧 detokenize 为文本块（UTF-8 完整边界由运行时保证）。
fun interface GenieChunkSink {
    fun onChunk(text: String)
}
