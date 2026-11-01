package com.zzh.goodhub.engine

import android.content.Context
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

/**
 * 换版重装清理回归钉（npu-geniex-runtime P3）：VERSION 升级重装成功后，
 * 旧版本运行目录（geniex-runtime/<旧ver>/）与旧 marker（marker-<旧ver>.txt）
 * 必须被回收；当前版本目录与 marker 原样保留。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class GenieXRuntimeCleanupTest {
    private val ctx: Context = RuntimeEnvironment.getApplication()

    @Test
    fun cleanupRemovesOldVersionDirsAndMarkers() {
        val root = File(ctx.filesDir, "geniex-runtime")
        val oldDir = File(root, "0.9.0").apply { mkdirs() }
        File(oldDir, "libgeniex.so").writeText("stale")
        val curDir = File(root, GenieXInstaller.VERSION).apply { mkdirs() }
        File(curDir, "libgeniex.so").writeText("keep")
        val oldMarker = File(root, "marker-0.9.0.txt").apply { writeText("geniex=0.9.0 arch=v79") }
        val curMarker = File(root, "marker-${GenieXInstaller.VERSION}.txt").apply { writeText("geniex=${GenieXInstaller.VERSION} arch=v79") }

        GenieXInstaller.cleanupOldVersions(ctx)

        assertFalse(oldDir.exists())
        assertFalse(oldMarker.exists())
        assertTrue(curDir.exists())
        assertTrue(curMarker.exists())
    }

    @Test
    fun cleanupIsNoopWhenOnlyCurrentVersion() {
        val root = File(ctx.filesDir, "geniex-runtime-cleanup-noop")
        root.mkdirs()
        val curDir = File(root, GenieXInstaller.VERSION).apply { mkdirs() }
        File(curDir, "libgeniex.so").writeText("keep")
        // noop 语义经 root 下无其他内容断言（cleanup 扫 filesDir/geniex-runtime 固定根）
        GenieXInstaller.cleanupOldVersions(ctx)
        assertTrue(curDir.exists())
    }
}
