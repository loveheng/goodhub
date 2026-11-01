package com.zzh.goodhub.engine

import android.content.Context
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
import com.zzh.goodhub.GenieChunkSink
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * LiteRT-LM Runner（多栈构型 ADR 2026-11-01）：`.litertlm` 系推理后端。
 *
 * **实现 = litertlm-android 0.16.0**（Maven `com.google.ai.edge.litertlm`，
 * AAR 内置 liblitertlm_jni.so 随 APK 打包——D1 终裁「LiteRT-LM 内置底座」）。
 *
 * **D-1 同栈降级链**：NPU（`Backend.NPU(nativeLibraryDir)`，QAIRT 运行库单源
 * = GenieX 增配已装时）→ GPU（OpenCL，无外部运行库）→ loadError 收口云端。
 * **CPU 全程出局**（不用 `Backend.CPU`，「禁 CPU 分流」红线）。
 *
 * **契约**：prompt = messages JSON（`[{"role":..,"content":..}]`，与 GenieX 系
 * 同一 AIDL promptJson 契约）；**末轮必为 user**（端侧单发数据面保证——聊天
 * 路径末轮恒为当前用户提问、原语固定 [system,user]），违例 = 显式失败
 * （-4）非静默处理。模板渲染归本 Runner 自治（SDK 原生 bundle 模板经
 * Conversation 角色映射，禁外部预模板化喂入——与 2026-10-31 复读环修复
 * 同原则：角色表达归模板层）。
 *
 * **采样真实生效**（P1-8 采样面在本栈的增量兑现）：temperature/topP 经
 * SamplerConfig 直通（GenieX 侧因 SDK 拒收面仍失效，本栈不受限）。
 *
 * **停用词** = [StopSequenceMatcher] 文本流跨帧匹配（D-3 契约：字符串下发、
 * Runner 自治；与 GenieX 系同型——SDK 回调为已 detokenize 文本）。
 */
class LiteRtLmRunner(private val context: Context) : OnDeviceRunner {

    companion object {
        private const val TAG = "LiteRtLmRunner"

        /// 回调有界等待上限：SDK 回调丢失（U4 验证点）不得挂死
        /// engine-genie-generate 专用线程（挂死 = 进程生成能力永久占用）。
        private const val CALLBACK_WAIT_S = 120L

        /// 负状态码契约（OnDeviceRunner 通用负码之上）：
        private const val ERR_INVALID_PROMPT = -3
        private const val ERR_LAST_TURN_NOT_USER = -4
    }

    @Volatile override var ready: Boolean = false
        private set

    @Volatile override var creating: Boolean = false
        private set

    @Volatile override var abortRequested: Boolean = false
        private set

    @Volatile override var loadError: String? = null

    /// 当前生效后端（诊断归因 / 票据 runtime 字段）：litertlm-npu /
    /// litertlm-gpu；装载成功后回填，close 后保留末态（与 GenieSession
    /// activeRuntime 同语义口径）。
    @Volatile override var activeRuntime: String = "litertlm-gpu"
        private set

    @Volatile override var lastProfile: EngineProfile? = null
        private set

    private var engine: Engine? = null

    /// 在途会话（abort 目标）；单执行槽保证至多一个在途。
    @Volatile private var activeConversation: Conversation? = null

    override fun beginLoad(): Boolean {
        synchronized(this) {
            if (creating || ready) return false
            creating = true
            return true
        }
    }

    override fun doLoad(modelDir: String) {
        try {
            if (ready) return
            loadError = null
            // ① 布局识别：.litertlm 单文件（D-1 资产族；Dart 导入面同判据
            // 识别入册，:engine 侧装载前复核防旁路）。
            val bundle = File(modelDir).listFiles()
                ?.firstOrNull { it.isFile && it.name.lowercase().endsWith(".litertlm") }
            if (bundle == null) {
                loadError = "asset layout: no .litertlm bundle in $modelDir"
                Log.e(TAG, "[DEGRADE] $loadError")
                return
            }
            // ② QAIRT 运行库单源（多栈 ADR）：NPU 需外部 QNN 运行库
            // （Backend.NPU(nativeLibraryDir)）——与 GenieX 增配共用同一
            // 「已装」判据（GenieXRuntime.qnnRuntimeDirOrNull，禁第二判据源）。
            // 增配未装 = NPU 档不可用 → 直走 GPU（OpenCL 无外部运行库需求）。
            // 产品语义（增配选装）与工程判据（单源）同构。
            val qnnDir = GenieXRuntime.qnnRuntimeDirOrNull(context.applicationContext)
            val backends: List<Backend> = if (qnnDir != null) {
                listOf(Backend.NPU(qnnDir.absolutePath), Backend.GPU())
            } else {
                Log.i(TAG, "geniex 增配未装 → NPU 档不可用，直走 GPU")
                listOf(Backend.GPU())
            }
            // ③ D-1 同栈降级链：NPU → GPU → loadError 收口云端；CPU 全程出局。
            // UNCERTAIN(U2): SDK NPU 失败 = 抛异常 or 静默回落 CPU（红线验证点）。
            // UNCERTAIN(U3): NPU 编译 bundle 可否在 GPU 后端装载（降级链可行性）。
            // UNCERTAIN(U1): modelPath 绝对路径语义（官方样例传 assets 名）。
            for (backend in backends) {
                val e = Engine(
                    EngineConfig(
                        modelPath = bundle.absolutePath,
                        backend = backend,
                        cacheDir = context.cacheDir.absolutePath,
                    )
                )
                try {
                    // 阻塞装载（doLoad 已在 engine-model-load 后台线程执行）。
                    e.initialize()
                    engine = e
                    activeRuntime =
                        if (backend is Backend.NPU) "litertlm-npu" else "litertlm-gpu"
                    ready = true
                    Log.i(TAG, "engine initialized: backend=${backend.name} " +
                        "model=${bundle.name}")
                    return
                } catch (e2: Throwable) {
                    Log.w(TAG, "[DEGRADE] init failed (backend=${backend.name}): $e2")
                    runCatching { e.close() }
                    if (backend is Backend.NPU) {
                        Log.i(TAG, "NPU init failed → degrade to GPU tier")
                    }
                }
            }
            loadError = "litertlm all backends failed " +
                "(tried: ${backends.joinToString { it.name }})"
            Log.e(TAG, "[DEGRADE] $loadError")
        } catch (e: Throwable) {
            loadError = "doLoad: $e"
            Log.e(TAG, "[DEGRADE] litertlm load failed: $e")
        } finally {
            creating = false
        }
    }

    override fun query(
        prompt: String,
        maxTokens: Int,
        sink: GenieChunkSink,
        temperature: Float,
        topP: Float,
        stopSequences: List<String>,
    ): Int {
        val e = engine
        if (e == null || !ready) {
            Log.w(TAG, "[DEGRADE] query before ready (loadError=$loadError)")
            return -2
        }
        // messages JSON → 中立轮次（单源 = ChatMLComposer.parseNeutral，
        // 解析不随 Runner 复制——多栈 ADR 否决信号 #2 收口）。
        val turns = ChatMLComposer.parseNeutral(prompt)
            ?: run {
                Log.e(TAG, "[DEGRADE] invalid prompt shape (not a messages JSON array)")
                return ERR_INVALID_PROMPT
            }
        // 契约：末轮必为 user（端侧单发数据面保证——聊天路径末轮恒为当前
        // 用户提问、原语固定 [system,user]）；违例 = 显式失败，禁静默。
        if (turns.last().role != "user") {
            Log.e(TAG, "[DEGRADE] contract violation: last turn role=" +
                "${turns.last().role} (expected user)")
            return ERR_LAST_TURN_NOT_USER
        }
        abortRequested = false
        lastProfile = null

        // 采样真实生效（P1-8 采样面在本栈的增量兑现）：temperature/topP
        // 直通，非 SDK 默认（topK=40 与 SDK 默认口径一致）。
        val sampler = SamplerConfig(
            topK = 40,
            topP = topP.toDouble(),
            temperature = temperature.toDouble(),
        )
        // 角色映射进 Conversation（SDK 应用 bundle 原生 chat 模板）：
        // system → systemInstruction；历史（除 system 与末轮）→ initialMessages
        // （user→USER / assistant→MODEL）；末轮 → sendMessage 触发生成。
        val systemTurn = turns.firstOrNull { it.role == "system" }
        val history = turns.filter { it.role != "system" && it !== turns.last() }
        val config = ConversationConfig(
            systemInstruction = systemTurn?.let { Contents.of(it.content) },
            initialMessages = history.map { turnMessage(it.role, it.content) },
            samplerConfig = sampler,
            maxOutputToken = maxTokens,
        )
        val conv: Conversation = try {
            e.createConversation(config)
        } catch (e2: Throwable) {
            Log.e(TAG, "[DEGRADE] createConversation failed: $e2")
            lastProfile = EngineProfile(stopReason = "conversation-create-failed")
            return -1
        }
        activeConversation = conv
        // D-3：停用词 Runner 自治（跨帧文本流匹配，命中=用户可见边界截断）。
        // 本系无默认表（Gemma 模型原生 EOS 自然终止，无 im_end 概念——
        // GenieX 系默认表 im_end 是 Qwen 模板语义，强加于此系属模板串栈）；
        // 空表直通 = 正常终止路径。
        val stopMatcher = StopSequenceMatcher(stopSequences)
        val latch = CountDownLatch(1)
        var status = 0
        var streamError: Throwable? = null
        var stoppedByStopSequence = false
        val queryStart = System.currentTimeMillis()
        var firstAt = 0L
        var lastAt = 0L
        var chunkCount = 0
        try {
            conv.sendMessageAsync(
                Message.user(turns.last().content),
                object : MessageCallback {
                    override fun onMessage(message: Message) {
                        if (abortRequested) return
                        val text = message.text()
                        if (text.isEmpty()) return
                        if (firstAt == 0L) {
                            firstAt = System.currentTimeMillis()
                            Log.i(TAG, "first token after ${firstAt - queryStart}ms")
                        }
                        lastAt = System.currentTimeMillis()
                        chunkCount++
                        val m = stopMatcher.feed(text)
                        if (m.release.isNotEmpty()) sink.onChunk(m.release)
                        if (m.stopped) {
                            stoppedByStopSequence = true
                            Log.i(TAG, "stop sequence observed -> stop " +
                                "(headChars=${m.release.length})")
                            runCatching { conv.cancelProcess() }
                        }
                    }

                    override fun onDone() {
                        if (!abortRequested) {
                            val rest = stopMatcher.flush()
                            if (rest.isNotEmpty()) sink.onChunk(rest)
                        }
                        latch.countDown()
                    }

                    override fun onError(throwable: Throwable) {
                        streamError = throwable
                        Log.w(TAG, "[DEGRADE] stream error: $throwable")
                        latch.countDown()
                    }
                },
            )
            // 有界等待（防 SDK 回调丢失挂死生成线程）；onDone/onError 是最后
            // 回调且先于 countDown 完成滞留冲刷——等待返回后 native 回调侧
            // 无并发写入，EngineService 收尾 flush 安全。
            if (!latch.await(CALLBACK_WAIT_S, TimeUnit.SECONDS)) {
                Log.e(TAG, "[DEGRADE] callback wait timeout ${CALLBACK_WAIT_S}s -> abort")
                abortRequested = true // cancelled 语义：EngineService 不再收尾 flush
                runCatching { conv.cancelProcess() }
                status = -1
            }
            if (status == 0) {
                status = when {
                    abortRequested -> 1
                    streamError != null -> -1
                    stoppedByStopSequence -> 1
                    else -> 0
                }
            }
        } catch (e2: Throwable) {
            Log.w(TAG, "[DEGRADE] sendMessageAsync threw: $e2")
            status = -1
        } finally {
            runCatching { conv.close() }
            activeConversation = null
            // 诚实归因：SDK 回调面无 token 计数（generatedTokens=-1），速度
            // 不伪造（0.0）——TTFT/decodeSpan 为宿主秒表口径（chunk 粒度近似）。
            val ttft = if (firstAt > 0L) (firstAt - queryStart).toDouble() else 0.0
            val decodeSpan =
                if (firstAt > 0L && lastAt >= firstAt) (lastAt - firstAt).toDouble() else 0.0
            lastProfile = EngineProfile(
                ttftMs = ttft,
                decodeTimeMs = decodeSpan,
                generatedTokens = -1,
                decodingSpeed = 0.0,
                stopReason = when {
                    streamError != null -> "error"
                    abortRequested -> "cancelled"
                    stoppedByStopSequence -> "stop-sequence"
                    else -> "completed"
                },
            )
            Log.i(TAG, "query done: status=$status chunks=$chunkCount " +
                "stopReason=${lastProfile?.stopReason} ttftMs=${lastProfile?.ttftMs?.toInt()}")
        }
        return status
    }

    override fun abort() {
        abortRequested = true
        runCatching { activeConversation?.cancelProcess() }
    }

    override fun close() {
        activeConversation = null
        engine?.let {
            try {
                it.close()
            } catch (e: Throwable) {
                Log.w(TAG, "[DEGRADE] close: $e")
            }
        }
        engine = null
        ready = false
    }
}

/// 角色映射（中立 role → SDK Message 工厂）：assistant→model；user→user；
/// system 不进 initialMessages（已归 systemInstruction），此处置防御性归 user。
private fun turnMessage(role: String, content: String): Message = when (role) {
    "assistant" -> Message.model(content)
    else -> Message.user(content)
}

/// 流式 chunk 文本提取（Message → 其 Text 内容拼接）；非文本内容（多模态）
/// 一期不进端侧路径（资源中心一期拒收二进制），此处只取文本。
private fun Message.text(): String =
    contents.contents
        .filterIsInstance<com.google.ai.edge.litertlm.Content.Text>()
        .joinToString("") { it.text }
