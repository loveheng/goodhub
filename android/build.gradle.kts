allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 修复 AAR metadata 校验失败：部分旧插件（file_picker 8.x、flutter_secure_storage、
// jni、jni_flutter 等）在各自 android/build.gradle 中硬编码 compileSdk 34/35，
// 而 flutter_plugin_android_lifecycle(2.0.35) 的 AAR 要求 compileSdk >= 36，
// 导致 checkDebugAarMetadata 直接中断 assembleDebug。
//
// 真 SSOT：目标值派生自 :app 实际采用的 compileSdk（即 flutter.compileSdkVersion），
// 而非另设 gradle.properties 属性。app 与插件同源，构造上不会出现 app < plugin 的
// 分裂；Flutter/SDK 升级时自动跟随，无需手改任何数字。
//
// 三个实测要点：
// 1) 库模块的 android 扩展是 legacy com.android.build.gradle.LibraryExtension
//    （不是 com.android.build.api.dsl.LibraryExtension —— 后者 findByType 全为 null，静默失效）。
// 2) 读取 :app 必须推迟到子项目评估之后（根脚本已声明 evaluationDependsOn(":app")）；
//    在根配置期同步读会拿到 null，导致整块被静默跳过。
// 3) 只取 getCompileSdk()（返回 Int）。getCompileSdkVersion() 返回 "android-36" 形式
//    字符串，toIntOrNull() 会得到 null；且 getMethods() 顺序无规范，firstOrNull 结果不确定。

fun Project.appCompileSdk(): Int? {
    val appAndroid = project(":app").extensions.findByName("android") ?: return null
    return runCatching { appAndroid.javaClass.getMethod("getCompileSdk").invoke(appAndroid) }
        .getOrNull() as? Int
}

subprojects {
    val applyOverride: Project.() -> Unit = {
        val target = appCompileSdk()
        val lib = extensions.findByName("android") as? com.android.build.gradle.LibraryExtension
        if (target != null && lib != null && (lib.compileSdk ?: 0) < target) {
            lib.compileSdk = target
        }
    }
    if (state.executed) applyOverride() else afterEvaluate { applyOverride() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
