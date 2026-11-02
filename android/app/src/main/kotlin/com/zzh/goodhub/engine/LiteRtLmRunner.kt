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
 * **D-1 同栈降级链**：NPU（`Backend.NPU(解压目录)`，NPU 运行库集 = assets 内置
 * Gallery 官方五件套、运行期一次性解压）→ GPU（OpenCL，无外部运行库）→
 * loadError 收口云端。
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

        /// NPU 运行库集变体（HTP 架构，**按芯片键控**——2026-11-02 用户拍板
        /// 解绑 v79 硬编码 + **多机型口径取消 APK 内置**）：复用
        /// GenieXRuntime.hexagonArch() 单源（SM8550→73 / 8650→75 / 8750→79 /
        /// 8850→81；null = 不支持的 SoC）。运行库一律经增配通道按芯片下载
        /// （LiteRtLmNpuInstaller，设置面触发），装载面只查安装目录。

        /// NPU 运行库集（装载集/目录单源 = LiteRtLmNpuInstaller.libFiles，
        /// 多机型口径：按芯片经增配通道下载，禁止内置/解压旁路）。
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

    /// NPU 运行库集解压（assets → filesDir，一次性、幂等）：APK 打包 excludes
    /// 的同名通配（`**/libQnn*.so`，为 GenieX AAR 51 库全量移出 APK 而立）无法
    /// 按来源区分同名的不同版本库——QNN 集入 jniLibs 必被连带排除，故走 assets
    /// 内置 + 解压路线（GenieX 增配 AAR 解压先例同款机制）。解压目录独立于
    /// GenieX 增配目录（两栈 QNN 集版本不同，不共享）。返回 null = 本机无 NPU
    /// 运行库（调用方降级直走 GPU，**显式 [DEGRADE] 留痕**——2026-11-02 拍板
    /// 禁无感知回落）。
    private fun npuLibDir(): File? {
        val arch = GenieXRuntime.hexagonArch() ?: run {
            Log.w(TAG, "[DEGRADE] npu runtime: hexagonArch unknown SoC → GPU fallback")
            return null
        }
        // 2026-11-02 拍板（多机型口径）：**取消 APK assets 内置**——装载面只查
        // 增配通道安装目录（LiteRtLmNpuInstaller，设置面按芯片下载）；不在场 =
        // 显式 [DEGRADE] 后 GPU 档（不静默、不冒充 NPU 档——票据 runtime 字段
        // 由 activeRuntime 如实回填），绝不从 assets 回退解压。
        if (LiteRtLmNpuInstaller.installed(context, arch)) {
            return LiteRtLmNpuInstaller.artifactDir(context, arch)
        }
        Log.w(TAG, "[DEGRADE] npu runtime lib not installed for v$arch " +
            "(multi-device: install via settings channel) → GPU fallback")
        return null
    }

    override fun doLoad(modelDir: String, backendHint: String?) {
        try {
            if (ready) return
            loadError = null
            // backendHint（AIDL 2026-11-02 #8：准入探针专用后端选择权注入）：
            // 'gpu' = 强制 GPU 档装载（跳过 NPU 库探测——「NPU 败再探 GPU」的
            // 第二段）；其余/null = Runner 自裁（NPU 库在位则 NPU 优先）。
            val forceGpu = backendHint == "gpu"
            // ① 布局识别：.litertlm 单文件（D-1 资产族；Dart 导入面同判据
            // 识别入册，:engine 侧装载前复核防旁路）。
            val bundle = File(modelDir).listFiles()
                ?.firstOrNull { it.isFile && it.name.lowercase().endsWith(".litertlm") }
            if (bundle == null) {
                loadError = "asset layout: no .litertlm bundle in $modelDir"
                Log.e(TAG, "[DEGRADE] $loadError")
                return
            }
            // ② NPU 运行库集（ADR 修订 2026-11-02，真机实证）：assets 内置
            // Gallery 官方五件套 + 一次性运行期解压（jniLibs 路被打包 excludes
            // 同名通配封死——无法与 GenieX AAR 同名异版本库区分来源）。旧
            // 「QAIRT 单源共享」假设被真机证伪（Backend.NPU 指 GenieX 增配
            // 目录：warmup RET_CHECK 失败——两栈 QNN 集版本不同不共享；目录
            // 隔离 + 单进程单装载纪律保证任一时刻仅一栈 QNN 集在内存，无
            // 符号冲突——见 decisions.md ADR 修订）。
            // NPU 档恒尝试：解压失败 → 降级直走 GPU；bundle-SoC 不匹配
            // （如 sm8750 bundle 跑他芯）= warmup 失败自动降级，此为
            // bundle 自身语义，非配置错误。
            // backendHint='gpu'（探针第二段）→ 跳过 NPU 库探测，GPU-only。
            val npuDir = if (forceGpu) null else npuLibDir()
            val backends: List<Backend> = if (npuDir != null) {
                listOf(Backend.NPU(npuDir.absolutePath), Backend.GPU())
            } else {
                if (forceGpu) {
                    Log.i(TAG, "backend hint gpu → GPU-only load (probe pass 2)")
                } else {
                    Log.w(TAG, "[DEGRADE] NPU 运行库集不可用（assets 解压失败）→ 直走 GPU")
                }
                listOf(Backend.GPU())
            }
            // ③ D-1 同栈降级链：NPU → GPU → loadError 收口云端；CPU 全程出局。
            // U2 已实证（2026-11-02）：NPU 失败 = 抛 LiteRtLmJniException，
            // 无静默 CPU 回落（红线守住）。
            // U3 已实证：NPU 编译 bundle 不可在 GPU 后端装载（Input tensor
            // not found）——GPU 档仅服务 GPU bundle（联发科 APU 族）；NPU
            // bundle 的降级终点 = 云端收口。
            // U1 已实证：modelPath 绝对路径可用（推进到 engine init 阶段）。
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
        // 历史轮可裁剪（var）：LiteRT-LM 上下文窗有限（Gemma3-1B bundle =
        // 1280 token），超限时 SDK 报 INVALID_ARGUMENT "Input token ids are
        // too long" 且零产出收流（2026-11-02 真机实证：第二轮 1291>=1280 →
        // 秒 EOS 空回答）——此处丢最老历史轮有界重试，system 与末轮 user
        // 恒保留；无历史可裁剪仍超限则按原错误上抛（诚实失败）。
        var history = turns.filter { it.role != "system" && it !== turns.last() }
        while (true) {
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
            // 上下文超限重试判定：丢最老历史轮重试（旧 conv 已在 finally 关闭）。
            // 无部分产出重复风险——超限在生成开始前的输入校验段报错（零 token
            // 产出，2026-11-02 真机日志实证 chunks=0）。
            if (status == -1 &&
                streamError?.message?.contains("too long", ignoreCase = true) == true &&
                history.isNotEmpty()
            ) {
                Log.w(TAG, "[DEGRADE] context overflow -> drop oldest history turn " +
                    "(${history.size} left) and retry")
                history = history.drop(1)
                continue
            }
            return status
        }
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
