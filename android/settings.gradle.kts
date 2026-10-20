pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// ---------------------------------------------------------------------------
// 插件接入契约（AIDL）的唯一物理副本在独立仓 goodhub-mcp-sdk 的 :contract 模块。
// 用复合构建（composite build）直接消费其源码：宿主与插件侧共用同一份 AIDL 契约，
// 从根上消灭「跨仓手抄副本」这一漂移源（历史上 AIDL 曾有 3 份拷贝）。
//
// 仓路径：local.properties 的 mcpSdkRepo.path（相对**仓根**，默认 ../goodhub-mcp-sdk，
// 即 goodhub 的同级兄弟仓）；目录不存在时跳过复合构建，改由 mavenLocal() / 远端 Maven
// 坐标解析（此时须先跑 toolbox run sdk-dep 把 SDK 发布到本地 Maven）。
// ---------------------------------------------------------------------------
val mcpSdkRepoPath = run {
    val properties = java.util.Properties()
    val localProps = file("local.properties")
    if (localProps.exists()) localProps.inputStream().use { properties.load(it) }
    properties.getProperty("mcpSdkRepo.path") ?: "../goodhub-mcp-sdk"
}
// 基准 = 仓根（settings 目录 android/ 的上一级），不是 android/ 本身。
val mcpSdkRepoDir = java.io.File(rootDir.parentFile, mcpSdkRepoPath).canonicalFile
if (mcpSdkRepoDir.isDirectory) {
    includeBuild(mcpSdkRepoDir) {
        dependencySubstitution {
            substitute(module("com.zzh.goodhub.mcp:goodhub-mcp-contract"))
                .using(project(":contract"))
        }
    }
}
