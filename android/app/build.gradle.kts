plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.qiuqianzzz.fluxwave"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.qiuqianzzz.fluxwave"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            // 包名后缀：调试包 install 到 com.qiuqianzzz.fluxwave.debug，与正式版
            // com.qiuqianzzz.fluxwave 并存、数据隔离（SharedPreferences/缓存目录
            // 以 applicationId 为键）。类引用按 namespace 解析不随后缀变，故
            // MainActivity / activity-alias（绝对名 com.qiuqianzzz.fluxwave.*）不受影响。
            applicationIdSuffix = ".debug"
        }
        // 应用名 label 不在此用 resValue（AGP9 kts 下解析不稳定），改由
        // variant 资源目录 src/{main,debug,profile}/res/values/strings.xml 覆盖。
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
