plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zzh.goodhub"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zzh.goodhub"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 兼容拍板沿用 goodshare：Android 14+，不做低版本兼容
        minSdk = 34
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    // 端侧 LLM 运行时（M2 自 goodshare 随迁）：LiteRT-LM 纯 Kotlin 引擎（Maven Central，
    // 无 NDK/CMake），跑 .litertlm 模型包。坐标经 AndroLLM 实际工程核实（2026-09-29）：
    // artifact 为 litertlm-android，非 litert-lm（后者在 Maven Central 不存在，构建期即解析失败）。
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.16.0")

    // 插件接入契约（AIDL + 发现约定常量）的唯一物理副本在独立仓 goodhub-mcp-sdk
    // 的 :contract 模块。宿主此前自带的 AIDL 副本已删除（2026-10-20）——
    // 改由本坐标提供，保证宿主与插件侧字节级同一份契约。
    // 解析路径：复合构建（android/settings.gradle.kts 的 includeBuild，优先）
    // → mavenLocal()（toolbox run sdk-dep 发布）→ 远端 Maven（坐标发布后）。
    // 版本与 contract_version 绑定，见 SDK 仓 VERSION 文件。
    implementation("com.zzh.goodhub.mcp:goodhub-mcp-contract:0.1.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
