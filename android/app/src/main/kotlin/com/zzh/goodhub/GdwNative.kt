package com.zzh.goodhub

/// 端侧引擎数据面消费 worker 的 JNI 入口（NPU 稿 §6.4 v3.1，S3-6 UDS 化）。
///
/// native 实现 = cpp/engine_data_worker.cpp（libgdw.so，主进程）：
/// epoll 等待数据面 socket 读端（可读事件唤醒）+ 长度前缀成帧重组
/// `[4B 大端 len][payload]` + `Dart_PostCObject_DL` 逐帧投递 Dart Isolate。
///
/// 驱动权在 Kotlin（本类）：Dart 无法持有原始 fd，也无法调 Dart 引擎 C API
/// 之外的任何东西——Kotlin 拿 AIDL 返回的数据面读端 fd 后经 JNI
/// 移交 native；Dart 只负责经 MethodChannel 传 NativePort 与
/// `NativeApi.initializeApiDLData` 指针。
///
/// 单 worker 假设：:engine 数据面单实例（dataPlane 随 loadModel 创建/
/// release 释放），handle 由 [EngineServiceBridge] 维护（start 返回、
/// stop 清零）。
object GdwNative {
    init {
        // 主进程 so：externalNativeBuild（app build.gradle.kts S3-6）。
        System.loadLibrary("gdw")
    }

    /// Dart 侧 DL API 指针注册（`NativeApi.initializeApiDLData` 地址）。
    /// 幂等；start 前必须调用，否则 start 返回错误。
    external fun initApi(apiPtr: Long)

    /// 启动消费线程。返回 handle：**成功 ≠ 0，失败 = 0**（失败时 sockFd 所有权
    /// 已由 native 回收）。
    ///
    /// **宿主侧恒判 `!= 0L`，禁判正负**：成功值是 `Worker*` 转 jlong，Android
    /// 64 位下因 heap pointer tagging（顶字节 0xB4）**恒为负**。历史上「正数=成功」与
    ///「负数=错误码」两种编码各留过反向缺口（回归钉 gdw-handle-sign 实证）：
    /// 前者把成功误判失败（worker 已在跑却无人接管、重试线程累积 30→31）；
    /// 后者把失败误判成功（负错误码被当句柄存下 → 后续任一 stop 路径
    /// `reinterpret_cast<Worker*>(-6)` 解引用 = **主进程确定性 SEGV**）。
    /// 故 native 侧统一「0 = 唯一失败码」，错误分类经 [lastError]/[lastErrno] 取。
    external fun start(port: Long, sockFd: Int): Long

    /// 停止并释放（幂等：handle=0 no-op）。阻塞至线程退出、fd 清收。
    external fun stop(handle: Long)

    /// 消费线程存活判据（宿主侧幂等短路用）：线程可能已退出（socket EOF =
    /// :engine 数据面死亡 / 协议腐化 / epoll 错误）而句柄仍在——宿主据此
    /// 判活并自愈重建。
    ///
    /// handle=0 → false（未启动）。句柄在 [stop] 之前始终有效（stop 会释放
    /// Worker 并由宿主同步清零句柄）。
    external fun isAlive(handle: Long): Boolean

    /// 上次 [start] 失败的分类码（0 = 无失败）。与返回值正交的诊断通道。
    external fun lastError(): Int

    /// 上次 [start] 失败对应的 errno（分类码不携带 errno 时为 0）。
    external fun lastErrno(): Int

    /// 消费端累计可读唤醒次数（诊断）：宿主侧在 IPC 死锁上报时取此值对账——
    /// 计数不动 = 消费端没在读（线程死 / fd 错）。
    external fun lastDrainCount(): Int

    /// 消费端累计投递字节（诊断）：与 [lastDrainCount] 同面取用——有唤醒但
    /// 字节不动 = 投不出去（端口关闭 / Dart 侧未接）。
    external fun lastPostedBytes(): Int

    /// 归还文件页缓存（`posix_fadvise` + `POSIX_FADV_DONTNEED`）：模型分片
    /// 读入并解析完成后丢弃其 clean page cache，加速整机 MemAvailable 回到
    /// 健康水位。返回 0 = 成功，<0 = 失败（errno 绝对值）。
    ///
    /// 边界：仅削**装载后的稳态恢复**，削不平装载瞬态尖峰；外置存储（FUSE）
    /// 文件的缓存由 FUSE 自管，效果可能有限。
    external fun dropFileCache(path: String): Int
}
