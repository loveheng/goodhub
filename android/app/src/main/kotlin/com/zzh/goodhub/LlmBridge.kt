package com.zzh.goodhub

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.ResponseFormat
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ThinkingConfig
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * 端侧 LLM MethodChannel 桥（M2 自 goodshare 随迁，2026-10-10）。
 *
 * 跑 LiteRT-LM Kotlin 运行时（com.google.ai.edge.litertlm:litertlm-android）：
 * - [Engine] 按「单模型常驻」懒加载（mmap 大文件，首次 generate 时初始化一次）；
 * - 每次生成新建 [Conversation]（一次性任务，不跨条目复用 KV，防上下文串味），用完即关；
 * - 全部推理跑在单线程 executor 上——createConversation / sendMessage 均为**阻塞调用**，
 *   绝不能上主线程；单线程同时天然串行化，与 Dart 队列的逐任务消费对齐；
 * - 错误统一 PlatformException(code=llm_error) 回传，Dart 侧降级为 null（不卡队列）。
 *
 * 协议（channel: goodhub/llm，八方法）：
 * - isAvailable        → Boolean（模型文件存在 = 可用）
 * - unavailableReason  → String?（人类可读原因）
 * - generate(prompt, system?, max_tokens, response_format?) → String?（空产出回 null；
 *   response_format = {type: json|regex, value}，LiteRT-LM ResponseFormat 约束解码，
 *   已真机实证：regex/JSON Schema 严格合规，2026-10-11）
 * - cancel             → Boolean（取消在途生成，§10 Abort 级联①步；无在途 = false）
 * - warmup             → Boolean（后台初始化引擎至就绪才返回；模型缺失 = false）
 * - release            → void（关引擎释放内存，排队在途生成之后执行）
 * - isWarmed           → Boolean（引擎是否已初始化驻留）
 * - socModel           → String?（Build.SOC_MODEL，API 31+；低版本 null）
 */
@OptIn(ExperimentalApi::class)
object LlmBridge {
    private const val TAG = "LlmBridge"

    /** Flutter shared_preferences 在原生侧的实际落点：文件名与 key 前缀都带 flutter. 前缀。 */
    private const val PREF_SELECTED = "flutter.llm_selected_model"
    private const val DEFAULT_MODEL_ID = "qwen25-1.5b-q8"

    private val executor = Executors.newSingleThreadExecutor()
    private var engine: Engine? = null
    private var loadedPath: String? = null
    private var modelFilePath: String? = null // Dart 显式 publish 的模型绝对路径（优先于拼路径）

    /** 在途会话（executor 线程写、主线程读取消）：单飞行语义下恒指唯一在途生成。 */
    @Volatile
    private var currentConversation: Conversation? = null

    /** 容器上下文上限（goodshare on-device-llm.md §3.1）：Qwen q8 包 4096，Gemma NPU 包 1280。 */
    private fun maxCtxFor(modelId: String) = if (modelId.startsWith("qwen")) 4096 else 1280

    private fun selectedModelId(activity: Context): String {
        val prefs = activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        return prefs.getString(PREF_SELECTED, null) ?: DEFAULT_MODEL_ID
    }

    /// 选中模型的本地文件；路径与 Dart 侧 LlmModelManager（path_provider documents 目录）
    /// 严格对齐——Flutter 的 documents 在原生侧是 getDir("app_flutter")，另有 filesDir 兜底。
    ///
    /// 回退策略：精确 id 找不到时，**扫描 llm_models/ 下任意已下载模型**（优先 qwen 系），
    /// 兜住「Dart 选中 id 与已下载文件错位」的静默失败——只要设备上有已下好的模型，引擎即可用。
    private fun selectedModelFile(activity: Context): Pair<String, File>? {
        val id = selectedModelId(activity)
        // 优先 Dart 显式 publish 的绝对路径（消除 path_provider 与原生 getDir 的路径差异）
        val explicit = modelFilePath
        if (explicit != null) {
            val f = File(explicit)
            if (f.exists() && f.length() > 0) return id to f
        }
        val docs = activity.getDir("app_flutter", Context.MODE_PRIVATE)
        val candidates = listOf(
            File(File(File(docs, "llm_models"), id), "model.litertlm"),
            File(File(File(activity.filesDir, "llm_models"), id), "model.litertlm"),
        )
        for (f in candidates) {
            if (f.exists() && f.length() > 0) return id to f
        }
        // 精确 id 落空：回退到任意已下载模型（优先 qwen 系，与 DEFAULT_MODEL_ID 同族）
        return scanAnyModel(docs) ?: scanAnyModel(activity.filesDir)
    }

    /// 扫描 [root]/llm_models/<id>/model.litertlm，返回第一个已下载（size>0）的模型。
    private fun scanAnyModel(root: File): Pair<String, File>? {
        val dir = File(root, "llm_models")
        if (!dir.isDirectory) return null
        val found = dir.listFiles { d -> d.isDirectory }?.mapNotNull { d ->
            val f = File(d, "model.litertlm")
            if (f.exists() && f.length() > 0) d.name to f else null
        } ?: return null
        return found.firstOrNull { it.first.startsWith("qwen") } ?: found.firstOrNull()
    }

    fun register(channel: MethodChannel, activity: Context) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setModelPath" -> {
                    modelFilePath = call.arguments as? String
                    Log.d(TAG, "setModelPath=$modelFilePath")
                    result.success(null)
                }
                "cancel" -> {
                    val conv = currentConversation
                    if (conv == null) {
                        result.success(false)
                    } else {
                        // 取消是尽力而为：对已完结会话调 cancelProcess 的异常不留尾巴，
                        // 返回值只表「有无在途生成被命中」；被取消的 generate 以其自然
                        // 结果（部分产出/异常）回传，取消方早已弃单，不产生语义。
                        val hit = runCatching { conv.cancelProcess() }
                            .onFailure { Log.w(TAG, "cancelProcess failed: ${it.message}") }
                            .isSuccess
                        Log.d(TAG, "cancel requested, hit=$hit")
                        result.success(hit)
                    }
                }
                "warmup" -> {
                    // 预热（§2 前台驻留策略的挂载点）：后台单线程初始化引擎，完成后才回——
                    // Dart 侧 await 期间即「离线引擎唤醒中」反馈窗口；已热时立即返回。
                    val picked = selectedModelFile(activity)
                    if (picked == null) {
                        result.success(false)
                    } else {
                        val (modelId, file) = picked
                        executor.execute {
                            try {
                                ensureLoaded(activity, modelId, file)
                                Log.d(TAG, "warmup done: $modelId")
                                result.success(true)
                            } catch (t: Throwable) {
                                result.error("llm_error", t.message ?: "预热失败", null)
                            }
                        }
                    }
                }
                "release" -> {
                    // 释放（§2 Doze/后台期策略）：排队到 executor 尾部——在途生成自然跑完
                    // 再关引擎，杜绝 close 与 sendMessage 并发的未定义行为。
                    executor.execute {
                        runCatching { engine?.close() }
                            .onFailure { Log.w(TAG, "engine close failed: ${it.message}") }
                        engine = null
                        loadedPath = null
                        Log.d(TAG, "engine released")
                        result.success(null)
                    }
                }
                "isWarmed" -> result.success(engine != null)
                "deviceProbe" -> result.success(deviceProbe(activity))
                "socModel" -> result.success(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null
                )
                "isAvailable" -> {
                    val picked = selectedModelFile(activity)
                    // spike 诊断：App 进程视角的落盘取证（run-as 可读≠app 可读，逐层对照）
                    val diagId = selectedModelId(activity)
                    val diagDocs = activity.getDir("app_flutter", Context.MODE_PRIVATE)
                    val diagCands = listOf(
                        File(File(File(diagDocs, "llm_models"), diagId), "model.litertlm"),
                        File(File(File(activity.filesDir, "llm_models"), diagId), "model.litertlm"),
                    )
                    for (c in diagCands) {
                        Log.d(
                            TAG,
                            "probe: ${c.absolutePath} exists=${c.exists()} canRead=${c.canRead()} len=${c.length()}"
                        )
                    }
                    Log.d(TAG, "probe: docs=$diagDocs llm_models=${File(diagDocs, "llm_models").listFiles()?.map { it.name }} filesDir_llm_models=${File(activity.filesDir, "llm_models").listFiles()?.map { it.name }}")
                    Log.d(
                        TAG,
                        "isAvailable=${picked != null} selectedId=${selectedModelId(activity)} " +
                            "path=${picked?.second?.absolutePath}"
                    )
                    result.success(picked != null)
                }
                "unavailableReason" -> result.success(
                    if (selectedModelFile(activity) == null)
                        "未下载模型包（设置 → 端侧大模型 中下载）"
                    else null
                )
                "generate" -> {
                    val picked = selectedModelFile(activity)
                    if (picked == null) {
                        result.error("llm_unavailable", "模型未下载", null)
                        return@setMethodCallHandler
                    }
                    val (modelId, file) = picked
                    val prompt = call.argument<String>("prompt") ?: ""
                    val system = call.argument<String>("system")
                    val maxTokens = call.argument<Int>("max_tokens") ?: 512
                    val format = parseResponseFormat(call.argument<Map<String, String>>("response_format"))
                    // 推理在后台单线程执行；MethodChannel 的 result 允许跨线程回传
                    executor.execute {
                        try {
                            result.success(
                                generateBlocking(activity, modelId, file, prompt, system, maxTokens, format)
                            )
                        } catch (t: Throwable) {
                            result.error("llm_error", t.message ?: "LLM 推理失败", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Dart 侧约束解码规格（M2-T3 spike 已实证）：`{type: json|regex, value: <schema|pattern>}`，
    /// 缺失 = 无约束普通生成。type 未知时按无约束处理（不猜映射，让 spike 结果可判读）。
    /// 2026-10-11 真机实证（CPH2767 + qwen25-1.5b-q8）：regex/JSON Schema 均严格合规，
    /// 热跑延迟 regex 1861ms / json 2911ms vs 基线 2094ms，约束开销可忽略——architecture §2 UNCERTAIN 裁决为支持。
    private fun parseResponseFormat(args: Map<String, String>?): ResponseFormat? {
        val value = args?.get("value") ?: return null
        return when (args["type"]) {
            "json" -> ResponseFormat.json(value)
            "regex" -> ResponseFormat.regex(value)
            else -> null
        }
    }

    /** 阻塞推理：只在 executor 线程内执行。 */
    private fun generateBlocking(
        activity: Context,
        modelId: String,
        file: File,
        prompt: String,
        system: String?,
        maxOutputTokens: Int,
        format: ResponseFormat? = null,
    ): String? {
        ensureLoaded(activity, modelId, file)
        val eng = engine ?: throw IllegalStateException("Engine 初始化失败")
        val text = if (system != null) "$system\n\n$prompt" else prompt
        // 一次性任务：每次新建会话（不跨条目复用 KV），用完即关。
        // enableResponseFormat 仅在有约束时打开（SDK 契约：传 ResponseFormat 前必须先开此开关），
        // 保证无约束路径与随迁基线行为完全一致。
        val conv = eng.createConversation(
            ConversationConfig(
                samplerConfig = SamplerConfig(topK = 40, topP = 0.95, temperature = 0.7, seed = 0),
                enableResponseFormat = format != null,
            )
        )
        currentConversation = conv
        try {
            val reply = conv.sendMessage(
                Message.user(text),
                maxOutputToken = maxOutputTokens,
                thinkingConfig = ThinkingConfig(enableThinking = false),
                responseFormat = format,
            ).toString()
            val cleaned = reply.trim()
            return cleaned.ifEmpty { null }
        } finally {
            currentConversation = null
            runCatching { conv.close() }
        }
    }

    /// 设备环境探针（§16 门禁数据源）：RAM/电量/充电/省电/温控一次取齐。
    /// 未知语义（Dart 侧 DeviceTierGate 消费）：batteryPct=-1 未知；
    /// thermalStatus=-1 = API < 29 无公开温控 API，按放行处理（RAM 硬门槛兜底）。
    private fun deviceProbe(activity: Context): Map<String, Any> {
        val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val bm = activity.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val rawCapacity = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val batteryPct = if (rawCapacity <= 0) -1 else rawCapacity
        // 粘性广播查询（receiver=null）：系统保护广播，无需注册监听器
        val intent = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL || plugged > 0
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "totalRamBytes" to mem.totalMem,
            "availRamBytes" to mem.availMem,
            "lowMemory" to mem.lowMemory,
            "batteryPct" to batteryPct,
            "isCharging" to isCharging,
            "isPowerSave" to pm.isPowerSaveMode,
            "thermalStatus" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                pm.currentThermalStatus else -1,
        )
    }

    /** 引擎懒加载：路径或上下文配置变化时重建（mmap 大文件，只此一次开销）。 */
    private fun ensureLoaded(activity: Context, modelId: String, file: File) {        val maxCtx = maxCtxFor(modelId)
        if (engine != null && loadedPath == file.absolutePath) return
        runCatching { engine?.close() }
        val cacheDir = File(activity.cacheDir, "litert_lm").apply { mkdirs() }
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 6)
        val eng = Engine(
            EngineConfig(
                modelPath = file.absolutePath,
                backend = Backend.CPU(threadCount = threads),
                cacheDir = cacheDir.absolutePath,
                maxNumTokens = maxCtx,
            )
        )
        eng.initialize()
        engine = eng
        loadedPath = file.absolutePath
    }
}
