package com.zzh.goodhub

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.zzh.goodhub.engine.GenieXInstaller
import com.zzh.goodhub.engine.GenieXRuntime
import com.zzh.goodhub.engine.LiteRtLmNpuInstaller
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * GenieX 增配安装面通道（npu-geniex-runtime 设计稿 §7，P2）：主进程侧
 * `goodhub/geniex_runtime`——status / install（进度经 channel 反投）/
 * uninstall / mirrors 读写由 Dart 持久化后传参。安装跑独立线程（分钟级）。
 */
object GenieXBridge {
    private const val CHANNEL = "goodhub/geniex_runtime"
    private const val TAG = "GenieXBridge"
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: android.content.Context? = null
    @Volatile private var installing = false

    /// LiteRT-LM NPU 增配安装单飞闸（与 GenieX installing 分立——两族互不阻塞）。
    @Volatile private var litertlmInstalling = false

    fun register(context: android.content.Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            val ctx = appContext ?: return@setMethodCallHandler
            when (call.method) {
                "status" -> result.success(statusMap(ctx))
                "install" -> {
                    val mirrors = (call.argument<List<*>>("mirrors"))?.filterIsInstance<String>().orEmpty()
                    if (installing) { result.success(false); return@setMethodCallHandler }
                    installing = true
                    thread(name = "geniex-install") {
                        val ok = try {
                            // 进度/完成反投必须走主线程（MethodChannel @UiThread 约束，
                            // P2 演练 16:24 实证：工作线程直投把下载链炸掉）。
                            GenieXInstaller.install(ctx, mirrors) { pct ->
                                mainHandler.post { channel?.invokeMethod("onProgress", mapOf("pct" to pct)) }
                            }
                        } catch (e: Throwable) {
                            Log.e(TAG, "[DEGRADE] install: $e")
                            false
                        }
                        installing = false
                        mainHandler.post { channel?.invokeMethod("onDone", mapOf("ok" to ok)) }
                    }
                    result.success(true) // 受理
                }
                "uninstall" -> result.success(
                    GenieXRuntime.uninstall(ctx, call.argument<Boolean>("deleteCache") == true))
                // LiteRT-LM NPU 增配（2026-11-02 多机型拍板：按芯片下载，取消
                // APK 内置）：status / install 与 GenieX 同通道共存（事件前缀
                // litertlm 区分），安装面 = LiteRtLmNpuInstaller。status 含
                // **清单网络实拉**——MethodChannel 回调在主线程，必须后台线程
                // 取数、主线程回包（2026-11-02 真机实证 NetworkOnMainThread-
                // Exception → registered 恒 false →「工件未注册」误报）。
                "litertlmStatus" -> thread(name = "litertlm-npu-status") {
                    val map = LiteRtLmNpuInstaller.statusMap(ctx)
                    mainHandler.post { result.success(map) }
                }
                "litertlmInstall" -> {
                    val mirrors = (call.argument<List<*>>("mirrors"))?.filterIsInstance<String>().orEmpty()
                    if (litertlmInstalling) { result.success(false); return@setMethodCallHandler }
                    litertlmInstalling = true
                    thread(name = "litertlm-npu-install") {
                        val ok = try {
                            LiteRtLmNpuInstaller.install(ctx, mirrors) { pct ->
                                mainHandler.post {
                                    channel?.invokeMethod("litertlmOnProgress", mapOf("pct" to pct))
                                }
                            }
                        } catch (e: Throwable) {
                            Log.e(TAG, "[DEGRADE] litertlm install: $e")
                            false
                        }
                        litertlmInstalling = false
                        mainHandler.post { channel?.invokeMethod("litertlmOnDone", mapOf("ok" to ok)) }
                    }
                    result.success(true) // 受理
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun statusMap(ctx: android.content.Context): Map<String, Any?> {
        // 运行目录递归求和（P4 体积精确显示）：仅已装时有意义。
        val rt = GenieXRuntime.runtimeDir(ctx)
        val sizeBytes = if (GenieXRuntime.installed(ctx)) {
            rt.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
        } else 0L
        return mapOf(
            "supported" to (GenieXRuntime.hexagonArch() != null),
            "arch" to GenieXRuntime.hexagonArch(),
            "installed" to GenieXRuntime.installed(ctx),
            "installing" to installing,
            "version" to GenieXRuntime.VERSION,
            "sizeBytes" to sizeBytes,
        )
    }
}
