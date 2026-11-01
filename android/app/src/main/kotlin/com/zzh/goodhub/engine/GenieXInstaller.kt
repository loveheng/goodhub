package com.zzh.goodhub.engine

import android.content.Context
import android.os.Build
import android.util.Log
import com.zzh.goodhub.engine.GenieXRuntime.hexagonArch
import com.zzh.goodhub.engine.GenieXRuntime.markerFile
import com.zzh.goodhub.engine.GenieXRuntime.runtimeDir
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * GenieX 增配安装面（npu-geniex-runtime 设计稿 §5，P2 拆分）：主进程设置页
 * 触发——下载（镜像列表可配 + 断点续传 + 进度回调）→ AAR 整包校验 → 按
 * 机型解压装载集（逐文件 PINS）→ 写 marker（含驱动指纹，§4.8 对齐）。
 * :engine 装载面 = GenieXRuntime.ensureLoaded（只装不下载）。
 */
object GenieXInstaller {
    private const val TAG = "GenieXInstaller"
    const val VERSION = GenieXRuntime.VERSION
    const val AAR_BYTES = 89_045_966L
    const val AAR_SHA256 = "3a40def4890fe4991d3547acf8bcfa9f1be491ad7790a1cb5d26bbecb2dde69b"

    /** 默认双源（D3 裁决）；镜像列表可配置化后由 Dart 传入覆盖。 */
    val DEFAULT_URLS = listOf(
        "https://repo1.maven.org/maven2/com/qualcomm/qti/geniex-android/$VERSION/geniex-android-$VERSION.aar",
        "https://maven.aliyun.com/repository/central/com/qualcomm/qti/geniex-android/$VERSION/geniex-android-$VERSION.aar",
    )

    /** size + SHA-256 钉版（context/epics/on-device/geniex-0.10.0-pins.txt 实测）。 */
    data class Pin(val size: Long, val sha256: String)
    val PINS: Map<String, Pin> = mapOf(
        "libgeniex.so" to Pin(5245112L, "deca3df413ac5c4c1f1db8e9e4beaa9060af8fb48448d3649096f7158bd3c569"),
        "libgeniex-proc.so" to Pin(7174112L, "5fe2bcc8aeefa6c0e0250a77987f4b945b7101c5a382aa4d6d4b739e9c9f5430"),
        "libgeniex-proc-vision.so" to Pin(523480L, "aa70853282e983cd25b1ce2753724ebcb9353c0d89ec3b7dda506b38d089f664"),
        "libgeniex_core.so" to Pin(1189392L, "c576ffdf6264a06e5da4bd74664e8ff14b26a485621716daf946a06f5bea0038"),
        "libgeniex_vlm.so" to Pin(361824L, "6c5f03d54b7ce80232e21c5add830ace241c9932637e0ce59847f2c19e994980"),
        "libggml-base.so" to Pin(1002072L, "60745471b0af9dc254c56144a1d4a6258f4533c4eed2fb16c57121b4a40d6fe3"),
        "libggml-cpu.so" to Pin(858552L, "a2e15c579e45c2a26b3aec683aea86f94064163a313835f12e44e033ba7d6e0e"),
        "libggml-hexagon.so" to Pin(936160L, "bbbbc30f44312f7784ecdb7a1af1ce36b4cbc3e5b79bb7cb7b805707cff47a01"),
        "libggml-opencl.so" to Pin(3815776L, "a7c2809b3bee77b0d2b923a079220db2cee505a180b255b042938fa79d51fcf9"),
        "libggml.so" to Pin(30432L, "a877f80455f936be2a64d595adf8e0a602ac11c1740315941634a951a49205c4"),
        "libllama.so" to Pin(4037800L, "adda8c9e4f5acb29a6dd32274732543bc5ad524c69fa291ccb23b29341b58bfe"),
        "libllama-common.so" to Pin(3991144L, "8d311ce6fdc6b8b64bbe9f80a20c0ad3ad0b802cc8a7cfc230e3aff36d8d42c2"),
        "libmtmd.so" to Pin(1380056L, "5853aff1bca65a92c19f521ee33a573b55910dd45021dfee4e8e9f71e4a89f62"),
        "libnpu_jni.so" to Pin(479248L, "13dc28ea6e2254444904346d20c767edf5330c94fdd8370d8d2cbd50ac76bc36"),
        "libomp.so" to Pin(973944L, "cb47b6557429b3c10861cdf2c9819d8ac89a5388e71ed929afca7c533ba312aa"),
        "libQnnHtp.so" to Pin(3979248L, "d299323d79868adbb18997c8e99ae18f961005589ab137f56a51d27e67d6bf0f"),
        "libQnnSystem.so" to Pin(4068024L, "b30bd9880dc48f6c5349185a7d45b326f8a064b10072e60094354fa23d9a2027"),
        "libQnnHtpV79.so" to Pin(12969720L, "71c77c2ab9d750950b0b754a7a7caaab6181d017e14890e87935fc00ab19e5aa"),
        "libQnnHtpV79Stub.so" to Pin(791424L, "166a3bb724c448e9425aa8f98f16b25aa1465eae6334553e408da7256d76fc99"),
        "libQnnHtpV79Skel.so" to Pin(12563756L, "408c1f6a3c6b853bbe34a9862a4054c171e76808a3b3004eac1d3c0fb309fd29"),
        "libQnnHtpV79CalculatorStub.so" to Pin(250872L, "b32f6fa802b1b197083513dd5e9e0d6172cc39cc4704892e76a98aa48205b73c"),
        "libQnnHtpNetRunExtensions.so" to Pin(1105096L, "2923a52c9c3d4039ee181fc3978aff7546aa34ea970de939b0793954ae9c2345"),
        // v81 变体（8850 机型换名装载）
        "libQnnHtpV81.so" to Pin(13944024L, "47c10492c6717ad30e0e9585e61bf91bb475d2f3a81de16a00fd04f4d3a23e70"),
        "libQnnHtpV81Stub.so" to Pin(816184L, "8cfb232be5f3f09d732805a8cfe222515460625a00267ed6648667e140be8a31"),
        "libQnnHtpV81Skel.so" to Pin(13542412L, "35a3d4392c8dc15ebe724b57353975614e6eeba59cde2cc3af71b3f4b5d5db0f"),
        "libQnnHtpV81CalculatorStub.so" to Pin(250872L, "7729c3d166b5116fc6c1a9007170c1d60d928826917c5e3e181e56525fecf5c8"),
    )

    /** 下载进度回调（0..100）。 */
    fun install(context: Context, mirrors: List<String>, onProgress: (Int) -> Unit): Boolean {
        if (GenieXRuntime.installed(context)) return true
        val arch = hexagonArch() ?: run {
            Log.i(TAG, "unsupported SoC — install rejected")
            return false
        }
        val urls = mirrors.ifEmpty { DEFAULT_URLS }
        return try {
            val aar = download(context, urls, onProgress) ?: return false
            extract(context, aar, arch)
            markerFile(context).writeText("geniex=$VERSION arch=v$arch fp=${Build.FINGERPRINT}\n")
            cleanupOldVersions(context)
            Log.i(TAG, "installed: arch=v$arch dir=${runtimeDir(context).absolutePath}")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "[DEGRADE] install: $e")
            false
        }
    }

    /** 双源断点续传下载（每源 3 次），成功返回 AAR 本地文件。 */
    private fun download(context: Context, urls: List<String>, onProgress: (Int) -> Unit): File? {
        val dst = File(context.filesDir, "geniex-aar/geniex-android-$VERSION.aar")
        dst.parentFile?.mkdirs()
        for (url in urls) {
            repeat(3) { attempt ->
                try {
                    val partial = File(dst.path + ".part")
                    // 整包缓存复用：卸载保留的完整 AAR 直接校验取用（免重下）。
                    if (dst.isFile && dst.length() == AAR_BYTES && sha256(dst) == AAR_SHA256) {
                        onProgress(100)
                        return finish(dst, dst)
                    }
                    if (partial.isFile && partial.length() == AAR_BYTES) {
                        if (sha256(partial) == AAR_SHA256) return finish(partial, dst)
                        partial.delete()
                    }
                    val conn = URL(url).openConnection() as HttpURLConnection
                    conn.connectTimeout = 15_000
                    conn.readTimeout = 30_000
                    conn.instanceFollowRedirects = true
                    if (partial.isFile && partial.length() in 1 until AAR_BYTES) {
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
                                onProgress(((partial.length() * 100) / AAR_BYTES).toInt().coerceIn(0, 100))
                            }
                        }
                    }
                    if (partial.length() != AAR_BYTES) {
                        Log.w(TAG, "size mismatch ${partial.length()} ≠ $AAR_BYTES (${url}#$attempt)")
                        if (partial.length() > AAR_BYTES) partial.delete()
                        return@repeat
                    }
                    if (sha256(partial) != AAR_SHA256) {
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

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) { val n = input.read(buf); if (n <= 0) break; md.update(buf, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * 换版清理（P3）：VERSION 升级重装成功后，删除旧版本运行目录与旧 marker
     * ——目录按版本天然隔离（geniex-runtime/<ver>/），升级即换目录，此处只做
     * 旧盘回收。约 70MB/版。
     */
    fun cleanupOldVersions(context: Context) {
        val root = File(context.filesDir, "geniex-runtime")
        root.listFiles()?.forEach { dir ->
            if (dir.isDirectory && dir.name != VERSION) {
                dir.deleteRecursively()
                Log.i(TAG, "cleanup old runtime dir: ${dir.name}")
            }
        }
        root.listFiles()?.forEach { f ->
            if (f.isFile && f.name.startsWith("marker-") && f.name != "marker-$VERSION.txt") {
                f.delete()
            }
        }
    }

    /** 按机型从 AAR 解出装载集（逐文件钉版校验）。 */
    private fun extract(context: Context, aar: File, arch: Int) {
        val rt = runtimeDir(context)
        rt.mkdirs()
        val wanted = GenieXRuntime.installSet
        var extracted = 0
        ZipInputStream(aar.inputStream().buffered()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val base = entry.name.substringAfterLast('/')
                if (!wanted.contains(base)) continue
                val target = File(rt, base)
                val pin = PINS.getValue(base)
                FileOutputStream(target).use { zip.copyTo(it, 1 shl 16) }
                if (target.length() != pin.size || sha256(target) != pin.sha256) {
                    throw IllegalStateException("pin mismatch ${target.name}")
                }
                extracted++
                zip.closeEntry()
            }
        }
        if (extracted != wanted.size) throw IllegalStateException("AAR missing entries: got $extracted want ${wanted.size}")
    }
}
