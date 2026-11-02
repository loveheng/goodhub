package com.zzh.goodhub.engine

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import com.zzh.goodhub.GenieXNative

/**
 * GenieX 增配运行库装载面（npu-geniex-runtime 设计稿 §5/§6，P2 拆分）：
 * :engine 进程侧——只做「已装校验 + System.load 依赖序 + setQairtRuntimePath
 * 直调」，**不做下载**（安装面 = [GenieXInstaller]，主进程设置页触发）。
 *
 * marker 含驱动指纹（Build.FINGERPRINT，§4.8 对齐）：系统 OTA 更新 DSP 驱动
 * → 指纹漂移 → installed()=false（脏），待主进程重装后写新指纹。
 *
 * 机型映射（P1 加固 2026-11-02）：sm8550/7675/7550→v73 / sm8650→v75 /
 * sm8750→v79 / sm8850→v81（补骁龙 7 系；代号 kailua/pineapple/sun 兜底魔改
 * ROM）；QAIRT 全速集仅 v79/v81（Spike-2 定稿 4 件套）。
 */
object GenieXRuntime {
    private const val TAG = "GenieXRuntime"
    const val VERSION = "0.10.0"

    // —— P1（2026-11-02）：SoC 识别健壮性加固 ——
    // 高通参考平台代号 → Hexagon 代际。魔改 ROM 常把 ro.soc.model 改写为市场名
    // 或代号，但 ro.board.platform / ro.hardware 多保留此代号（kailua/pineapple/sun），
    // 故作为 sm/qcs 编号匹配失败后的兜底映射。仅收广泛公认代号，未知不臆造。
    private val CODENAME_TO_ARCH = mapOf(
        "kailua" to 73,    // SM8550 (8 Gen 2)
        "pineapple" to 75, // SM8650 (8 Gen 3)
        "sun" to 79,       // SM8750 (8 Elite)
    )
    private const val ARCH_UNSET = -2
    private const val ARCH_NULL = -1
    @Volatile private var archCache: Int = ARCH_UNSET

    private fun readSystemProperty(key: String): String = try {
        val p = Runtime.getRuntime().exec(arrayOf("getprop", key))
        p.inputStream.bufferedReader().use { it.readLine().orEmpty().trim() }
    } catch (_: Throwable) { "" }

    /**
     * 三级属性探测 SoC 标识：Build.SOC_MODEL → getprop ro.soc.model →
     * ro.board.platform → ro.hardware；返回首个非空非 unknown 值（小写）。
     */
    fun resolveSocModel(): String {
        val candidates = sequenceOf(
            Build.SOC_MODEL.orEmpty(),
            readSystemProperty("ro.soc.model"),
            readSystemProperty("ro.board.platform"),
            readSystemProperty("ro.hardware"),
        )
        for (raw in candidates) {
            val t = raw.trim().lowercase()
            if (t.isNotEmpty() && !t.equals("unknown", true)) return t
        }
        return ""
    }

    /** System.load 依赖序（被依赖者先装；npu_jni 最后——其 JNI_OnLoad 跑 geniex_init）。 */
    private val LOAD_ORDER = listOf(
        "libomp.so", "libggml-base.so", "libggml-cpu.so", "libggml-opencl.so", "libggml-hexagon.so",
        "libggml.so", "libllama.so", "libllama-common.so", "libmtmd.so",
        "libgeniex.so", "libgeniex-proc.so", "libgeniex-proc-vision.so", "libgeniex_core.so", "libgeniex_vlm.so",
        "libnpu_jni.so",
    )

    /** 装载集 = 核心 15 + QNN 4 件套（Spike-2 定稿），按 arch 替换 V79 段。 */
    val installSet: Set<String> by lazy {
        val arch = hexagonArch()
        val qnn = when (arch) {
            79 -> listOf("libQnnHtp.so", "libQnnSystem.so", "libQnnHtpV79Stub.so", "libQnnHtpV79Skel.so",
                "libQnnHtpV79.so", "libQnnHtpV79CalculatorStub.so", "libQnnHtpNetRunExtensions.so")
            81 -> listOf("libQnnHtp.so", "libQnnSystem.so", "libQnnHtpV81Stub.so", "libQnnHtpV81Skel.so",
                "libQnnHtpV81.so", "libQnnHtpV81CalculatorStub.so", "libQnnHtpNetRunExtensions.so")
            else -> emptyList() // v73/v75：仅 llama.cpp 档
        }
        (LOAD_ORDER.toSet() - "libnpu_jni.so" + "libnpu_jni.so" + qnn)
    }

    /**
     * SoC → Hexagon 代际；null = 本库不支持（fallback 内置基线）。进程内恒定缓存
     * （芯片不变），避免 doLoad 高频路径反复 exec getprop。
     */
    fun hexagonArch(): Int? {
        if (archCache != ARCH_UNSET) return if (archCache == ARCH_NULL) null else archCache
        val result = computeArch()
        archCache = result ?: ARCH_NULL
        return result
    }

    private fun computeArch(): Int? {
        val mfr = Build.SOC_MANUFACTURER.orEmpty().lowercase()
        val isQti = mfr.contains("qti") || mfr.contains("qualcomm")
        // 厂商白名单校验；SOC_MANUFACTURER 被清空/魔改时，借 ro.hardware 是否含
        // qcom 兜底（仍可识别为高通平台）。
        val hw = readSystemProperty("ro.hardware").lowercase()
        if (!isQti && !hw.contains("qcom")) return null

        val soc = resolveSocModel()
        if (soc.isEmpty()) return null
        // 1. 直接 sm/qcs 四位编号（放宽开头锚定，兼容 "qualcomm,sm8750" 等前缀噪声）。
        val num = Regex("(sm|qcs)(\\d{4})").find(soc)?.groupValues?.get(2)
        if (num != null) return mapArch(num)
        // 2. 代号兜底（魔改 ROM 把 SOC_MODEL 改写时，ro.board.platform 常保留代号）。
        CODENAME_TO_ARCH[soc]?.let { return it }
        return null
    }

    private fun mapArch(num: String): Int? = when (num) {
        // v73：8 Gen 2 / 7+ Gen 3 / 7 Gen 3（同 HTP 架构）
        "8550", "7675", "7550" -> 73
        // v75：8 Gen 3
        "8650" -> 75
        // v79：8 Elite
        "8750" -> 79
        // v81：8 Elite Gen 5
        "8850" -> 81
        else -> null
    }

    fun runtimeDir(context: Context): File = File(context.filesDir, "geniex-runtime/$VERSION")
    fun markerFile(context: Context): File = File(context.filesDir, "geniex-runtime/marker-$VERSION.txt")

    /**
     * QAIRT 运行库单源判据（多栈构型 ADR 2026-11-01）：QNN 运行库目录两栈
     * 共用——GenieX `ensureLoaded`（setQairtRuntimePath）与 LiteRtLmRunner
     * `Backend.NPU(nativeLibraryDir)` 均消费本解析器，**禁第二判据源**
     *（双份捆绑 = 符号冲突 + 判据漂移）。
     *
     * 语义 = 「增配已装且完整」（marker 版本/驱动指纹 + 装载集逐文件在盘）；
     * 未装/指纹漂移（OTA 更新 DSP 驱动）= null → NPU 档不可用：GenieX 系
     * loadError 收口云端、LiteRT-LM 系自动 GPU 档——产品语义（增配选装）
     * 与工程判据同构。
     */
    fun qnnRuntimeDirOrNull(context: Context): File? =
        if (installed(context)) runtimeDir(context) else null

    /**
     * 已装且完整：marker（版本+arch+驱动指纹）在场 + 装载集逐文件在场且大小吻合。
     * 指纹漂移（OTA 更新 DSP 驱动）→ 视为未装（脏），重装写新指纹（§4.8 对齐）。
     */
    fun installed(context: Context): Boolean {
        val arch = hexagonArch() ?: return false
        val marker = markerFile(context)
        if (!marker.isFile) return false
        val head = marker.readLines().firstOrNull().orEmpty()
        if (head != "geniex=$VERSION arch=v$arch fp=${Build.FINGERPRINT}") return false
        val rt = runtimeDir(context)
        val pins = GenieXInstaller.PINS
        return installSet.all { name ->
            val pin = pins[name] ?: return@all false
            val f = File(rt, name)
            f.isFile && f.length() == pin.size
        }
    }

    /**
     * 卸载（设置页）：删运行目录 + marker；**保留 geniex-aar 下载缓存**——
     * 重装时 AAR 整包校验/断点续传可直接复用，避免 89MB 全量重下（P3 弱网
     * 演练实证：连缓存一起删会让续传跨触发失效）。
     */
    fun uninstall(context: Context, deleteCache: Boolean = false): Boolean {
        val rt = runtimeDir(context)
        val existed = rt.exists()
        rt.deleteRecursively()
        markerFile(context).delete()
        if (deleteCache) File(context.filesDir, "geniex-aar").deleteRecursively()
        Log.i(TAG, "uninstalled (existed=$existed, cacheDeleted=$deleteCache)")
        return existed
    }

    /**
     * 装载链（:engine，只装不下载）：setQairtRuntimePath **最前**（按 app storage
     * 绝对路径 dlopen libgeniex 直调——System.load 核心库先于它会触发 init 链致
     * rc=-100008，P1 验收实证）→ System.load 依赖序（npu_jni 最后，JNI_OnLoad→
     * geniex_init 消费已设运行路径）。未装/指纹漂移 → false（loadError 收口云端）。
     */
    fun ensureLoaded(context: Context): Boolean {
        if (!installed(context)) {
            Log.w(TAG, "[DEGRADE] not installed or driver-fingerprint drifted — 云端收口")
            return false
        }
        val rt = runtimeDir(context)
        return try {
            val rc = GenieXNative.setQairtRuntimePath(File(rt, "libgeniex.so").absolutePath, rt.absolutePath)
            for (name in LOAD_ORDER) {
                val f = File(rt, name)
                if (!f.isFile) throw IllegalStateException("missing $name in ${rt.absolutePath}")
                System.load(f.absolutePath)
            }
            Log.i(TAG, "loaded v${hexagonArch()}: ${LOAD_ORDER.size} libs, setQairtRuntimePath $rc")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "[DEGRADE] ensureLoaded: $e")
            false
        }
    }
}
