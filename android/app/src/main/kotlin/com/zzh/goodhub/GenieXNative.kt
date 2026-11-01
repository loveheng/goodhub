package com.zzh.goodhub

/**
 * GenieX 运行路径 native 直调桥（npu-geniex-runtime 设计稿 §6 结论 2）：
 * `geniex_set_qairt_runtime_path` 必须在 libnpu_jni 的 JNI_OnLoad→geniex_init
 * 之前调用，而 Kotlin 侧经 GenieXSdk 类触碰任何 native 都会先触发加载链——
 * 故由 :engine 最早加载的 engine_tombstone.so 承载：按 [libgeniexPath]
 * （app storage 绝对路径，libgeniex.so 已 excludes 出 APK）dlopen 后直调。
 * 返回诊断串 "rc=<n>" / "rc=<n> err=<dlerror>"。
 */
object GenieXNative {
    init {
        runCatching { System.loadLibrary("engine_tombstone") }
    }

    external fun setQairtRuntimePath(libgeniexPath: String, rtPath: String): String
}
