package com.zzh.goodhub.engine

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.zip.ZipInputStream
import org.json.JSONObject

/**
 * 运行库增配通道核心（2026-11-02 用户拍板：三下载点独立、功能不降级 + v79
 * 合集包）。按「库族 × hexagonArch()」键控的通用下载骨架：双镜像断点续传 +
 * size/sha256 钉版 + 按装载集抽取 + 旧版清理。各运行库族（geniex /
 * litertlm-npu / neuropilot 留位）**共享骨架、各自注册工件 spec**——版本链
 * 自洽配对（禁跨栈混用 QNN 版本，SSOT 修正 2026-11-02，见 todos 多栈节）。
 *
 * v79 合集包 = 通道上的预组合工件槽（GenieX v79 + LiteRT-LM NPU v79 单工件
 * 一次下载双族到位）；当前 v79 双族库已随 APK assets 内置（首发机快捷路径），
 * 合集包 URL 在远端工件就绪时注册，本件只承载通道机制。
 */
object RuntimeChannel {
    private const val TAG = "RuntimeChannel"

    /** 工件清单单源（稳定常量；新增库族/芯片代际 = 改清单不改码）。 */
    const val MANIFEST_URL =
        "https://r2.oklhj.eu.org/runtimes/runtime-manifest.json"

    /** 逐文件钉版（size + SHA-256，真机实测口径沿用 GenieX pins 惯例）。 */
    data class Pin(val size: Long, val sha256: String)

    /** 通道工件 spec：一个「库族 × 架构」的下载单元（由清单解析产出）。 */
    data class Artifact(
        val family: String,
        val arch: Int, // Hexagon 代际（73/75/79/81）
        val fileName: String,
        val urls: List<String>,
        val totalBytes: Long,
        val sha256: String,
    )

    /** 清单工件段（common 或单个 arch 档）：url + 整包钉版 + 逐文件钉版。 */
    data class Part(
        val fileName: String,
        val url: String,
        val totalBytes: Long,
        val sha256: String,
        val pins: Map<String, Pin>,
    )

    /**
     * 库族已解析 spec（清单匹配产出）：**双层依赖**——common（跨芯片通用件，
     * 一次下载跨代际复用）+ arch（本机 Hexagon 代际专属件）。两段都进同一
     * 装载目录，逐 pin 校验（禁半份运行库被装载）。
     */
    data class FamilySpec(
        val family: String,
        val version: String,
        val common: Part,
        val arch: Part,
    )

    /**
     * 拉取并解析工件清单，按 family + arch + SoC 匹配（每次安装前实拉——
     * 清单是分发面唯一真相，无本地缓存；失败返回 null，调用方显式「未注册」，
     * 禁静默失败）。**须在工作线程调用**（网络 IO，MethodChannel 主线程回调
     * 禁直拉——2026-11-02 真机 NetworkOnMainThreadException 实证）。
     */
    fun fetchSpec(family: String, arch: Int, socModel: String): FamilySpec? = try {
        val conn = URL(MANIFEST_URL).openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.instanceFollowRedirects = true
        val body = conn.inputStream.use { it.readBytes().decodeToString() }
        parseSpec(body, family, arch, socModel)
    } catch (e: Throwable) {
        Log.w(TAG, "[DEGRADE] manifest fetch: $e")
        null
    }

    /// 清单解析 + 匹配（纯逻辑，可单测）：schema = families[{ family, version,
    /// common{url,totalBytes,sha256,files[]}, arches[{arch, soc[], ...}] }]。
    /// family 精确命中；arch 档 arch 精确命中；soc 白名单非空时要求本机
    /// SOC_MODEL 在列（大小写不敏感，空 = 仅按 arch 通用）；多条命中取清单序首个。
    fun parseSpec(
        manifestJson: String,
        family: String,
        arch: Int,
        socModel: String,
    ): FamilySpec? {
        val families = try {
            JSONObject(manifestJson).getJSONArray("families")
        } catch (e: Throwable) {
            Log.w(TAG, "[DEGRADE] manifest malformed: $e")
            return null
        }
        for (i in 0 until families.length()) {
            val f = families.optJSONObject(i) ?: continue
            if (f.optString("family") != family) continue
            val common = f.optJSONObject("common")?.let { parsePart(it, "common.zip") }
                ?: return null.also { Log.w(TAG, "[DEGRADE] manifest $family common missing") }
            val arches = f.optJSONArray("arches") ?: continue
            for (j in 0 until arches.length()) {
                val a = arches.optJSONObject(j) ?: continue
                if (a.optInt("arch", -1) != arch) continue
                val socs = a.optJSONArray("soc")?.let { s ->
                    List(s.length()) { s.optString(it).lowercase() }
                } ?: emptyList()
                if (socs.isNotEmpty() && socModel.trim().lowercase() !in socs) continue
                val archPart = parsePart(a, "$family-v$arch.zip")
                    ?: return null.also { Log.w(TAG, "[DEGRADE] manifest $family v$arch malformed") }
                return FamilySpec(
                    family = family,
                    version = f.optString("version"),
                    common = common,
                    arch = archPart,
                )
            }
            return null // 族命中但无本机代际档
        }
        return null
    }

    private fun parsePart(o: JSONObject, defaultFileName: String): Part? {
        val url = o.optString("url")
        if (url.isEmpty()) return null
        val pins = o.optJSONArray("files")?.let { files ->
            buildMap {
                for (j in 0 until files.length()) {
                    val e = files.optJSONObject(j) ?: continue
                    val name = e.optString("name")
                    val size = e.optLong("size", -1L)
                    val sha = e.optString("sha256")
                    if (name.isEmpty() || size <= 0 || sha.isEmpty()) continue
                    put(name, Pin(size, sha))
                }
            }
        } ?: emptyMap()
        if (pins.isEmpty()) return null
        return Part(
            fileName = o.optString("fileName", defaultFileName),
            url = url,
            totalBytes = o.optLong("totalBytes", -1L),
            sha256 = o.optString("sha256"),
            pins = pins,
        )
    }

    fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * 断点续传下载（每源 3 次；size/sha256 双重钉版校验）；整包缓存复用
     * （卸载保留的完整工件直接校验取用，免重下）。成功返回本地工件文件。
     */
    fun download(
        context: Context,
        artifact: Artifact,
        dstDir: String,
        onProgress: (Int) -> Unit,
    ): File? {
        val dst = File(context.filesDir, "$dstDir/${artifact.fileName}")
        dst.parentFile?.mkdirs()
        for (url in artifact.urls) {
            repeat(3) { attempt ->
                try {
                    val partial = File(dst.path + ".part")
                    if (dst.isFile && dst.length() == artifact.totalBytes &&
                        sha256(dst) == artifact.sha256
                    ) {
                        onProgress(100)
                        return dst
                    }
                    if (partial.isFile && partial.length() == artifact.totalBytes) {
                        if (sha256(partial) == artifact.sha256) return finish(partial, dst)
                        partial.delete()
                    }
                    val conn = URL(url).openConnection() as HttpURLConnection
                    conn.connectTimeout = 15_000
                    conn.readTimeout = 30_000
                    conn.instanceFollowRedirects = true
                    if (partial.isFile && partial.length() in 1 until artifact.totalBytes) {
                        conn.setRequestProperty("Range", "bytes=${partial.length()}-")
                    } else {
                        partial.delete()
                    }
                    conn.inputStream.use { input ->
                        FileOutputStream(partial, true).use { out ->
                            val buf = ByteArray(1 shl 16)
                            while (true) {
                                val n = input.read(buf)
                                if (n <= 0) break
                                out.write(buf, 0, n)
                                onProgress(
                                    ((partial.length() * 100) / artifact.totalBytes)
                                        .toInt().coerceIn(0, 100))
                            }
                        }
                    }
                    if (partial.length() != artifact.totalBytes) {
                        Log.w(TAG, "size mismatch ${partial.length()} ≠ " +
                            "${artifact.totalBytes} (${url}#$attempt)")
                        if (partial.length() > artifact.totalBytes) partial.delete()
                        return@repeat
                    }
                    if (sha256(partial) != artifact.sha256) {
                        Log.w(TAG, "sha256 mismatch (${url}#$attempt)")
                        partial.delete()
                        return@repeat
                    }
                    return finish(partial, dst)
                } catch (e: Throwable) {
                    Log.w(TAG, "download failed (${url}#$attempt): $e")
                }
            }
        }
        return null
    }

    private fun finish(partial: File, dst: File): File {
        if (dst.isFile) dst.delete()
        partial.renameTo(dst)
        return dst
    }

    /**
     * 从压缩包按装载集抽取（逐文件 pin 校验，size+sha256，缺件整批失败——
     * 禁半份运行库被装载面取用）。
     */
    fun extractPinned(
        archive: File,
        targetDir: File,
        wanted: Map<String, Pin>,
    ) {
        targetDir.mkdirs()
        var extracted = 0
        ZipInputStream(archive.inputStream().buffered()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val base = entry.name.substringAfterLast('/')
                val pin = wanted[base] ?: continue
                val target = File(targetDir, base)
                FileOutputStream(target).use { zip.copyTo(it, 1 shl 16) }
                if (target.length() != pin.size || sha256(target) != pin.sha256) {
                    throw IllegalStateException("pin mismatch ${target.name}")
                }
                extracted++
                zip.closeEntry()
            }
        }
        if (extracted != wanted.size) {
            throw IllegalStateException(
                "archive missing entries: got $extracted want ${wanted.size}")
        }
    }
}
