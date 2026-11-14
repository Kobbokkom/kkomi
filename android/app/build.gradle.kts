import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val previewSuffix = providers.gradleProperty("androidPreviewSuffix").orElse(".preview").get()
require(previewSuffix in setOf(".preview", ".preview.migration"))

val uploadSigning = Properties()
val signingFile = rootProject.file("key.properties")
if (signingFile.isFile) {
    signingFile.inputStream().use { uploadSigning.load(it) }
}

android {
    namespace = "com.kobbokkom.kkomi"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.kobbokkom.kkomi"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["admobAppId"] = providers.gradleProperty("androidAdMobAppId")
            .orElse("ca-app-pub-6737616702687889~7960117509").get()
        manifestPlaceholders["appLabel"] = "꼬미"
    }

    signingConfigs {
        if (signingFile.isFile) {
            create("upload") {
                storeFile = rootProject.file(requireNotNull(uploadSigning.getProperty("storeFile")))
                storePassword = uploadSigning.getProperty("storePassword")
                keyAlias = uploadSigning.getProperty("keyAlias")
                keyPassword = uploadSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        for (name in listOf("debug", "profile")) {
            maybeCreate(name).apply {
                applicationIdSuffix = previewSuffix
                manifestPlaceholders["appLabel"] = "꼬미 미리보기"
                manifestPlaceholders["admobAppId"] = "ca-app-pub-3940256099942544~3347511713"
            }
        }

        release {
            signingConfig = signingConfigs.findByName("upload")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.webkit:webkit:1.15.0")
}
