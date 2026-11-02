plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zzh.goodhub"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        // 端侧引擎控制面 AIDL（on-device S1-2）：IOnDeviceEngineService
        aidl = true
    }

    // S3 换线（2026-10-29）：cpp/ 探针三件（engine_probe/genie_smoke/
    // genie_session）随裸 Genie C API 链整体退役——推理后端 = geniex-android
    // AAR（Maven，自带 QNN 2.45 运行时全家桶）。
    // S3-6（2026-10-29）：数据面消费 worker 回归——engine_data_worker.cpp 仅做
    // RingBuffer 消费 + Dart 端口投递（§6.4 管道件），推理闭环仍在 :engine。
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            // QNN HTP DSP Skel（libQnnHtpV79Skel.so）必须以真实文件存在于
            // /data/app/.../lib/ 供 QNN 运行时读取（无法从 APK 内 mmap 直读），
            // 故强制解压打包（extractNativeLibs=true）——否则 dlopen 绝对路径
            // 全空、探针四项全 FAIL（2026-10-28 真机实证）。
            useLegacyPackaging = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        // 纯 JVM 单测：android.util.Log 等框架桩返回默认值（不抛 not mocked）——
        // NpuCircuitBreaker 等被测类含 Log 留痕调用（2026-11-02 盲区批）。
        unitTests.isReturnDefaultValues = true
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

    packaging {
        // npu-geniex-runtime 拆分（设计稿 §4，2026-11-01）：geniex-android
        // 0.10.0 全家桶 native 库全部移出 APK（classes-only），运行时按机型
        // 下载 AAR 后经 GenieXRuntime 解压装载（app storage + ADSP_LIBRARY_PATH
        // 通道，Spike-1 实证）。excludes 按库族通配（AAR 51 库全覆盖），
        // 不得使用宽泛 lib*.so（防误伤自有 libgdw/libengine_tombstone 与
        // 内置基线 liblitertlm_jni）。
        // 例外：libgeniex_plugin_{llama_cpp,qairt}.so（合计 614KB）留守 APK——
        // GenieXSdk.init() 从 nativeLibraryDir 注册插件，缺失即回调 onFailure
        // （P1 验收 12:27 实证）；其 NEEDED 核心库由 GenieXRuntime 预载解决。
        jniLibs.excludes += setOf(
            "**/libgeniex.so",
            "**/libgeniex-proc.so",
            "**/libgeniex-proc-vision.so",
            "**/libgeniex_core.so",
            "**/libgeniex_vlm.so",
            "**/libggml*.so",
            "**/libllama*.so",
            "**/libmtmd.so",
            "**/libnpu_jni.so",
            "**/libQnn*.so",
            "**/libhta_hexagon*.so",
            "**/libomp.so",
            "**/libPlatformValidatorShared.so",
            "**/libcalculator.so",
            "**/libCalculator_skel.so",
        )
    }
}

dependencies {
    // :engine 数据面 TokenRingBuffer JVM 单测（on-device S1-3）。
    testImplementation("junit:junit:4.13.2")

    // Bundle 缝回归钉（2026-10-31 用户裁决）：android.os.Bundle 在纯 JUnit 不可
    // 实例化，SessionTicketWire/GenerationParams 往返单测需 Robolectric 模拟。
    testImplementation("org.robolectric:robolectric:4.14.1")

    // 端侧 LLM 运行时（M2 自 goodshare 随迁）：LiteRT-LM 纯 Kotlin 引擎（Maven Central，
    // 无 NDK/CMake），跑 .litertlm 模型包。坐标经 AndroLLM 实际工程核实（2026-09-29）：
    // artifact 为 litertlm-android，非 litert-lm（后者在 Maven Central 不存在，构建期即解析失败）。
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.1")

    // :engine 端侧推理后端（S3 换线，2026-10-29）：官方 GenieX Android 绑定
    // （官方 GenieX Chat 同款管线）。4B 同资产同参数对照钉死裸 libGenie C API
    // 存在 2.5× 运行时代差（详见 on-device epic devlog），此为达标唯一路径。
    // AAR 自带 QNN 2.45 全家桶（jni/）——jniLibs 的同名 2.51 库已移除让位；
    // libQnnHtpPrepare.so（87MB，离线编译用）经 packaging excludes 排除。
    // 0.3.5 → 0.10.0（2026-10-31 升级评估）：对齐官方当前版，复查三手写补丁
    // （stopWords qairt 通道 / enableThinking / Token 乱码回调面）在新版的存废。
    implementation("com.qualcomm.qti:geniex-android:0.10.0")

    // geniex-android 绑定 API 面为 Kotlin 协程（Flow/runBlocking）；AAR pom
    // 未带传递依赖，显式钉住（官方 App 同样显式引 kotlinx-serialization 族）。
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // 插件接入契约（AIDL + 发现约定常量）的唯一物理副本在独立仓 goodhub-mcp-sdk
    // 的 :contract 模块。宿主此前自带的 AIDL 副本已删除（2026-10-20）——
    // 改由本坐标提供，保证宿主与插件侧字节级同一份契约。
    // 解析路径：复合构建（android/settings.gradle.kts 的 includeBuild，优先）
    // → mavenLocal()（toolbox run sdk-dep 发布）→ 远端 Maven（坐标发布后）。
    // 版本与 contract_version 绑定，见 SDK 仓 VERSION 文件。
    implementation("com.zzh.goodhub.mcp:goodhub-mcp-contract:0.2.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
