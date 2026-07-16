import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives outside version control: android/key.properties
// points at the keystore. Without it, release builds fail (see the guard on
// the package/bundle tasks below) instead of silently signing with the
// debug key; fresh clones can still run debug builds.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "io.github.invertium.bmsdash"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.invertium.bmsdash"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Fail closed: without the keystore this stays null and the task
            // guard below aborts, so a "release" artifact can never quietly
            // carry the debug signature.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                null
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// Abort release packaging when the real keystore is absent. doFirst keeps
// the check out of debug builds' way: it only runs when a release artifact
// task actually executes.
tasks.configureEach {
    if (name.contains("Release") &&
        (name.startsWith("package") || name.startsWith("bundle") ||
            name.startsWith("assemble"))
    ) {
        doFirst {
            if (!keystorePropertiesFile.exists()) {
                throw GradleException(
                    "Release signing is not configured (android/key.properties " +
                        "is missing); refusing to produce a release artifact " +
                        "with the debug key. Use a debug build instead.",
                )
            }
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
