plugins {
    id("com.android.application")
}

android {
    namespace = "com.zzh.goodhub.sample.dummy"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.zzh.goodhub.sample.dummy"
        minSdk = 34
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation(project(":plugin-core"))
}
