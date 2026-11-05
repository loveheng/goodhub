package com.zzh.goodhub.engine

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * GGUF × llama.cpp NPU(hexagon) **按模型负记忆**（2026-11-05 用户裁决）：
 *
 * hexagon 后端只在高通完整框架（增配运行库）在场时可用；某模型在该后端上
 * 失败时区分两类原因——
 * - **模型自身原因**（运行库在场、DSP skel 装载成功，create 仍失败 / 生成
 *   零产出 / TTFT 级 stall）→ 落盘留痕，后续装载**跳过 NPU 直 GPU**，
 *   避免每次装载白付一次 NPU 尝试（装载 + 首查 stall 代价数十秒）；
 * - **手机系统/环境原因**（运行库未装、DSP skel 缺席 = 增配清单缺文件、
 *   LMK/低内存/热）→ **不留痕**，只回退 GPU——这类随环境修复自愈，
 *   留痕会错误地永久封禁本可用的 NPU 通路。
 *
 * 留痕键 = geniex SdkVersion：**升版即失效**（自动重评，对齐上游修复节奏），
 * 旧版本痕迹视为过期不读不删。
 *
 * 落点 = App 私有 `files/npu-unfit/<模型目录绝对路径 MD5>.json`——**不写
 * 模型目录**：模型可能落在 shell 属主的外部路径（/data/local/tmp 等，
 * App uid 无写权，真机实证 EACCES），私有目录对两类模型都可靠可写；
 * 模型卸载后残留一条孤儿痕迹无害（键 = 路径，重导入同路径即复用）。
 */
object NpuFitStore {

    private const val TAG = "NpuFitStore"
    private const val DIR_NAME = "npu-unfit"

    /// TTFT stall 判据（2026-11-05 真机 [Fact]）：GPU 档 TTFT 亚秒级，hexagon
    /// 档同模型实测 20s（0.10.0 后端不成熟）——15s = 两档间 15× 分位，误伤面
    /// 仅「真慢的 NPU 后端」，而那正是要留痕的对象。
    private const val TTFT_STALL_MS = 15_000L

    private fun markerFile(context: Context, modelDir: File): File {
        val key = java.security.MessageDigest.getInstance("MD5")
            .digest(modelDir.absolutePath.toByteArray())
            .joinToString("") { "%02x".format(it) }
        val dir = File(context.filesDir, DIR_NAME)
        if (!dir.isDirectory) dir.mkdirs()
        return File(dir, "$key.json")
    }

    fun isUnfit(context: Context, modelDir: File, sdkVersion: String?): Boolean {
        if (sdkVersion.isNullOrEmpty()) return false
        val f = markerFile(context, modelDir)
        if (!f.isFile) return false
        return runCatching {
            val o = JSONObject(f.readText())
            o.optString("sdkVersion") == sdkVersion
        }.getOrDefault(false)
    }

    /** 模型自身原因留痕（幂等：已有同版本留痕则不重写）。 */
    fun mark(context: Context, modelDir: File, sdkVersion: String?, arch: Int?, reason: String) {
        if (sdkVersion.isNullOrEmpty()) return
        val f = markerFile(context, modelDir)
        runCatching {
            if (f.isFile) {
                val old = JSONObject(f.readText())
                if (old.optString("sdkVersion") == sdkVersion) return
            }
            f.writeText(
                JSONObject()
                    .put("sdkVersion", sdkVersion)
                    .put("hexagonArch", arch ?: "")
                    .put("reason", reason)
                    .put("ts", System.currentTimeMillis())
                    .toString()
            )
            Log.w(TAG, "[DEGRADE] npu-unfit marked ($reason, sdk=$sdkVersion) " +
                "→ 后续装载跳过 NPU 直 GPU")
        }.onFailure { Log.e(TAG, "[DEGRADE] mark failed: $it") }
    }

    /**
     * DSP skel（libggml-htp-v\<arch\>.so）在场检查——**分类判据核心**：
     * skel 缺席 = 增配清单缺文件（系统原因，不留痕）；在场而失败 = 模型自身
     * 原因（留痕）。扫描 geniex-runtime 安装目录（filesDir 下，多版本共存）。
     */
    fun htpSkelPresent(context: Context, arch: Int?): Boolean {
        if (arch == null) return false
        val target = "libggml-htp-v$arch.so"
        val root = File(context.filesDir, "geniex-runtime")
        if (!root.isDirectory) return false
        return root.walkTopDown().any { it.isFile && it.name == target }
    }

    fun ttftStall(ttftMs: Long): Boolean = ttftMs >= TTFT_STALL_MS

    /** 留痕读取（诊断透出面）：同版本留痕在场返回 reason，否则 null。 */
    fun reason(context: Context, modelDir: File, sdkVersion: String?): String? {
        if (sdkVersion.isNullOrEmpty()) return null
        val f = markerFile(context, modelDir)
        if (!f.isFile) return null
        return runCatching {
            val o = JSONObject(f.readText())
            if (o.optString("sdkVersion") == sdkVersion) o.optString("reason") else null
        }.getOrNull()
    }
}
