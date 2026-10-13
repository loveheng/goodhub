plugins {
    id("com.android.library")
}

android {
    namespace = "com.zzh.goodhub.mcp.plugin"
    compileSdk = 35

    buildFeatures {
        aidl = true
    }

    defaultConfig {
        minSdk = 34
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
