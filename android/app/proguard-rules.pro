# LiteRT-LM 端侧 LLM（goodshare 2026-10-10 真机排障教训，M2 随迁）：JNI 层
# liblitertlm_jni.so 在 createConversation 时按类名 FindMethod——R8 混淆改掉
# com.google.ai.edge.* 类名后 methodID 拿到 null，直接 native abort
# （"JNI DETECTED ERROR: mid == null"，表现为摘要任务永久 processing / app 静默重启）。
# 上游 issue #2406 同型。迁移时必须随代码带过去。
-keep class com.google.ai.edge.** { *; }
-dontwarn com.google.ai.edge.**

# 保留注解 / 签名 / 内部类，避免 R8 移除被反射或 JNI 访问的成员
-keepattributes *Annotation*, Exceptions, Signature, InnerClasses, EnclosingMethod, RuntimeVisible*Annotations
