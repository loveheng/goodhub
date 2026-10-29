# LiteRT-LM 端侧 LLM（goodshare 2026-10-10 真机排障教训，M2 随迁）：JNI 层
# liblitertlm_jni.so 在 createConversation 时按类名 FindMethod——R8 混淆改掉
# com.google.ai.edge.* 类名后 methodID 拿到 null，直接 native abort
# （"JNI DETECTED ERROR: mid == null"，表现为摘要任务永久 processing / app 静默重启）。
# 上游 issue #2406 同型。迁移时必须随代码带过去。
-keep class com.google.ai.edge.** { *; }
-dontwarn com.google.ai.edge.**

# 保留注解 / 签名 / 内部类，避免 R8 移除被反射或 JNI 访问的成员
-keepattributes *Annotation*, Exceptions, Signature, InnerClasses, EnclosingMethod, RuntimeVisible*Annotations

# 端侧 Genie 引擎（S2，:engine 进程）：libgoodhub_engine.so（JNI）经
# GetMethodID 反射回调 GenieChunkSink.onChunk（release 实证：R8 混淆改名后
# NoSuchMethodError → :engine 生成线程 FATAL→SIGKILL，表现同外部处决）。
# GenieSession 的 native 方法与成员同受 JNI 按名访问，一并保留。
-keep class com.zzh.goodhub.GenieChunkSink { *; }
-keep class com.zzh.goodhub.GenieSession { *; }

# geniex-android 0.3.5（S3 换线）：AAR 无 consumer proguard 规则，而
# libgeniex*.so/libnpu_jni.so 经 JNI 按名访问 com.geniex.sdk.**（bean 字段/
# LLMTokenCallback 回调/枚举 valueOf）——R8 改名即运行时断裂（同上型事故）。
-keep class com.geniex.sdk.** { *; }
-dontwarn com.geniex.sdk.**

# S3-6 数据面 worker：JNI 按名解析 native 方法（libgdw engine_data_worker.cpp
# Java_com_zzh_goodhub_GdwNative_*），R8 重命名会断链。
-keepclasseswithmembernames class com.zzh.goodhub.GdwNative { native <methods>; }
