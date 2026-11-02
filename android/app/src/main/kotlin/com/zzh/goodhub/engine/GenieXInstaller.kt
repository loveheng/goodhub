package com.zzh.goodhub.engine

import android.content.Context
import android.os.Build
import android.util.Log
import com.zzh.goodhub.engine.GenieXRuntime.hexagonArch
import com.zzh.goodhub.engine.GenieXRuntime.markerFile
import com.zzh.goodhub.engine.GenieXRuntime.runtimeDir
import com.zzh.goodhub.engine.RuntimeChannel.Pin
import java.io.File

/**
 * GenieX 增配安装面（npu-geniex-runtime 设计稿 §5，P2 拆分）：主进程设置页
 * 触发——下载（镜像列表可配 + 断点续传 + 进度回调）→ AAR 整包校验 → 按
 * 机型解压装载集（逐文件 PINS）→ 写 marker（含驱动指纹，§4.8 对齐）。
 * :engine 装载面 = GenieXRuntime.ensureLoaded（只装不下载）。
 *
 * 2026-11-02 泛化：下载/校验/抽取骨架上收 [RuntimeChannel]（库族 × arch 键控，
 * 三下载点独立共享骨架）；**工件清单化**——版本/URL/逐文件 pins 全部来自
 * `RuntimeChannel.MANIFEST_URL` 清单 `family = "geniex"` 条目（与 litertlm-npu
 * 同一清单、同一真相），代码只保留装载集选择（[GenieXRuntime.installSet]）
 * 与清单-代码钉版一致性校验。
 */
object GenieXInstaller {
    private const val TAG = "GenieXInstaller"
    const val VERSION = GenieXRuntime.VERSION

    /** size + SHA-256 钉版（context/epics/on-device/geniex-0.10.0-pins.txt 实测）。 */
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
        // 工件清单化 + **双层依赖**（2026-11-02 用户拍板）：common（跨芯片
        // 通用件，一次下载跨代际复用）+ 本机代际专属件，两段单源 = RuntimeChannel
        // 清单（family=geniex）。清单与代码钉版不一致（VERSION 漂移）→ 显式
        // 拒绝（装载面按 GenieXRuntime.VERSION 校验 marker，错版装上也是死）。
        val spec = RuntimeChannel.fetchSpec(
            "geniex", arch, Build.SOC_MODEL.orEmpty(),
        ) ?: run {
            Log.i(TAG, "manifest unavailable / no geniex artifact for v$arch — install rejected")
            return false
        }
        if (spec.version != VERSION) {
            Log.e(TAG, "[DEGRADE] manifest geniex version ${spec.version} ≠ " +
                "code-pinned $VERSION — install rejected (钉版一致性)")
            return false
        }
        return try {
            val rt = runtimeDir(context)
            // 段① common（跨芯片通用件）：dst 缓存复用（整包 sha256 命中免重下）。
            val commonZip = RuntimeChannel.download(
                context,
                RuntimeChannel.Artifact("geniex", arch, spec.common.fileName,
                    listOf(spec.common.url), spec.common.totalBytes, spec.common.sha256),
                dstDir = "geniex-aar", onProgress = onProgress,
            ) ?: return false
            RuntimeChannel.extractPinned(commonZip, rt, spec.common.pins)
            // 段② 本机代际专属件（QNN v 系 + ggml-hexagon）。
            val archZip = RuntimeChannel.download(
                context,
                RuntimeChannel.Artifact("geniex", arch, spec.arch.fileName,
                    listOf(spec.arch.url), spec.arch.totalBytes, spec.arch.sha256),
                dstDir = "geniex-aar", onProgress = onProgress,
            ) ?: return false
            RuntimeChannel.extractPinned(archZip, rt, spec.arch.pins)
            markerFile(context).writeText("geniex=$VERSION arch=v$arch fp=${Build.FINGERPRINT}\n")
            cleanupOldVersions(context)
            Log.i(TAG, "installed: arch=v$arch dir=${rt.absolutePath}")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "[DEGRADE] install: $e")
            false
        }
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

}
