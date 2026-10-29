package com.zzh.goodhub

import java.nio.ByteBuffer

/// 端侧引擎数据面消费 worker 的 JNI 入口（NPU 稿 §6.4，S3-6）。
///
/// native 实现 = cpp/engine_data_worker.cpp（libgdw.so，主进程）：
/// epoll 等待唤醒 fd + 只读映射 :engine RingBuffer + drain 后经
/// Dart_PostCObject_DL 微批投递 Dart Isolate。
///
/// 驱动权在 Kotlin（本类）：Dart 无法持有原始 fd，也无法调 Dart 引擎 C API
/// 之外的任何东西——Kotlin 拿 AIDL 返回的 SharedMemory/唤醒 fd 后经 JNI
/// 移交 native；Dart 只负责经 MethodChannel 传 NativePort 与
/// `NativeApi.initializeApiDLData` 指针。
///
/// 单 worker 假设：:engine 数据面单实例（dataPlane 随 loadModel 创建/
/// release 释放），handle 由 [EngineServiceBridge] 维护（start 返回、
/// stop 清零），重复 start 返回负值错误码。
object GdwNative {
    init {
        // 主进程 so：externalNativeBuild（app build.gradle.kts S3-6）。
        System.loadLibrary("gdw")
    }

    /// Dart 侧 DL API 指针注册（`NativeApi.initializeApiDLData` 地址）。
    /// 幂等；start 前必须调用，否则 start 返回错误。
    external fun initApi(apiPtr: Long)

    /// 启动消费线程。返回 handle（>0 成功；0 = 已在运行；<0 = 失败，已回收
    /// wakeFd 所有权）。buffer 须为 SharedMemory.mapReadOnly() 直接
    /// ByteBuffer（JNI GetDirectBufferAddress，绕开 getFd @hide 面）。
    external fun start(
        port: Long,
        buffer: ByteBuffer,
        wakeFd: Int,
        capacity: Int,
    ): Long

    /// 停止并释放（幂等：0 no-op）。阻塞至线程退出、fd/映射清收。
    external fun stop(handle: Long)
}
