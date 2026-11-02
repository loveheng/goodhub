package com.zzh.goodhub.engine

import android.content.Context
import android.os.Build
import android.util.Log
import com.zzh.goodhub.engine.GenieXRuntime.hexagonArch
import com.zzh.goodhub.engine.RuntimeChannel.Artifact
import java.io.File

/**
 * LiteRT-LM NPU 增配安装面（2026-11-02 用户拍板：**取消 APK 内置**，按多机型
 * 开发——三栈全走「库族 × hexagonArch()」按芯片下载）。骨架 = [RuntimeChannel]
 * （清单实拉匹配 + 双镜像断点续传 + size/sha256 钉版 + 逐 pin 抽取）。
 *
 * **工件清单化**：注册表不住代码——`RuntimeChannel.MANIFEST_URL` 清单内
 * `family = "litertlm-npu"` 条目（arch + soc 白名单键）；新增芯片代际 = 上传
 * 工件 + 改清单，App 零发版。装载目录 filesDir/litertlm-npu-v{arch}，与
 * GenieX 增配目录隔离（两栈 QNN 集版本不同不共享，见 LiteRtLmRunner.doLoad 注）。
 *
 * v79 工件源自 Google AI Edge Gallery split_qualcomm_npu_runtime_v79（与
 * sm8750 官方模型版本自洽）。
 */
object LiteRtLmNpuInstaller {
    private const val TAG = "LiteRtLmNpuInstaller"
    private const val FAMILY = "litertlm-npu"

    /** 每代际装载集（库族私有，文件名随 arch 派生——解绑 v79 硬编码）。 */
    fun libFiles(arch: Int): List<String> = listOf(
        "libLiteRtDispatch_Qualcomm.so",
        "libQnnHtp.so",
        "libQnnHtpV${arch}Skel.so",
        "libQnnHtpV${arch}Stub.so",
        "libQnnSystem.so",
    )

    /** 装载目录（:engine 装载面与安装面共用，单一来源）。 */
    fun artifactDir(context: Context, arch: Int): File =
        File(context.filesDir, "litertlm-npu-v$arch")

    /** 在位检查（装载面闸）：装载集五件全在场非空。 */
    fun installed(context: Context, arch: Int): Boolean =
        libFiles(arch).all { File(artifactDir(context, arch), it).length() > 0 }

    /** statusMap（设置面状态胶囊投影）：registered = 清单可拉取且含本机代际工件。 */
    fun statusMap(context: Context): Map<String, Any?> {
        val arch = hexagonArch()
        val spec = arch?.let {
            RuntimeChannel.fetchSpec(FAMILY, it, Build.SOC_MODEL.orEmpty())
        }
        return mapOf(
            "supported" to (arch != null),
            "arch" to arch,
            "installed" to (arch != null && installed(context, arch)),
            "installing" to installing,
            "registered" to (spec != null),
            "version" to "litertlm-npu",
            "sizeBytes" to (arch?.let { a ->
                libFiles(a).sumOf { File(artifactDir(context, a), it).length() }
            } ?: 0L),
        )
    }

    @Volatile
    private var installing = false

    /**
     * 安装（设置面触发，分钟级下载跑独立线程——调用方自管线程）：清单拉取 →
     * **双段下载**（common 跨芯片通用件 + 本机代际专属件，两段 zip 均按
     * 整包 sha256 缓存复用）→ 逐 pin 抽取进装载目录。逐文件校验失败整批
     * 失败（禁半份运行库被装载）。清单拉不到 = 显式失败（工件未注册口径），
     * 禁静默降级。
     */
    fun install(context: Context, mirrors: List<String>, onProgress: (Int) -> Unit): Boolean {
        if (installing) return false
        val arch = hexagonArch() ?: run {
            Log.i(TAG, "unsupported SoC — install rejected")
            return false
        }
        if (installed(context, arch)) return true
        val spec = RuntimeChannel.fetchSpec(FAMILY, arch, Build.SOC_MODEL.orEmpty()) ?: run {
            Log.i(TAG, "manifest unavailable / no artifact for v$arch — install rejected")
            return false
        }
        installing = true
        try {
            val dir = artifactDir(context, arch)
            // 段① common（跨芯片通用件）：dst 缓存复用（整包 sha256 命中免重下）。
            val commonZip = RuntimeChannel.download(
                context,
                Artifact(FAMILY, arch, spec.common.fileName, listOf(spec.common.url),
                    spec.common.totalBytes, spec.common.sha256),
                dstDir = "litertlm-npu-aar", onProgress = onProgress,
            ) ?: return false
            RuntimeChannel.extractPinned(commonZip, dir, spec.common.pins)
            // 段② 本机代际专属件。
            val archZip = RuntimeChannel.download(
                context,
                Artifact(FAMILY, arch, spec.arch.fileName, listOf(spec.arch.url),
                    spec.arch.totalBytes, spec.arch.sha256),
                dstDir = "litertlm-npu-aar", onProgress = onProgress,
            ) ?: return false
            RuntimeChannel.extractPinned(archZip, dir, spec.arch.pins)
            Log.i(TAG, "installed: arch=v$arch dir=${dir.absolutePath}")
            return true
        } catch (e: Throwable) {
            Log.e(TAG, "[DEGRADE] install: $e")
            return false
        } finally {
            installing = false
        }
    }
}
