import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}
// Values come only from an ignored local file or injected environment variables.
val releaseProperties = Properties()
val releaseFile = rootProject.file("key.properties")
if (releaseFile.exists()) releaseFile.inputStream().use { releaseProperties.load(it) }
fun signingValue(property: String, variable: String): String? =
    System.getenv(variable)?.takeIf { it.isNotBlank() }
        ?: releaseProperties.getProperty(property)?.takeIf { it.isNotBlank() }
val releaseStore = signingValue("storeFile", "FUTSAL_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "FUTSAL_KEYSTORE_PASSWORD")
val releaseAlias = signingValue("keyAlias", "FUTSAL_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "FUTSAL_KEY_PASSWORD")
val releaseSigningReady = listOf(releaseStore, releaseStorePassword, releaseAlias, releaseKeyPassword).all { it != null }
android {
    namespace = "com.saturdayfutsal.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }
    defaultConfig {
        applicationId = "com.saturdayfutsal.app"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    signingConfigs {
        if (releaseSigningReady) {
            create("privateRelease") {
                storeFile = rootProject.file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        getByName("release") {
            isDebuggable = false
            if (releaseSigningReady) signingConfig = signingConfigs.getByName("privateRelease")
        }
    }
}
// Never silently sign a release with the development key or produce an ambiguous
// unsigned artifact. Debug builds remain available for personal testing.
tasks.configureEach {
    if (name == "packageRelease" || name.startsWith("package") && name.endsWith("Release")) {
        doFirst {
            check(releaseSigningReady && rootProject.file(releaseStore!!).isFile) {
                "Release signing is not configured. Supply private android/key.properties or FUTSAL_KEYSTORE_* / FUTSAL_KEY_ALIAS / FUTSAL_KEY_PASSWORD. Use a debug build for personal testing."
            }
        }
    }
}
flutter { source = "../.." }
dependencies { implementation("androidx.core:core:1.15.0") }
