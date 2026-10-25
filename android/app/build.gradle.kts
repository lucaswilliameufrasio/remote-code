plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.lucaswilliameufrasio.remotecode"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lucaswilliameufrasio.remotecode"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
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
            // Release signing is configured below; never use the debug key.
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

// BEGIN CODERELAY RELEASE SIGNING
val releaseSigningNames = listOf(
    "CODERELAY_ANDROID_KEYSTORE_PATH",
    "CODERELAY_ANDROID_STORE_PASSWORD",
    "CODERELAY_ANDROID_KEY_ALIAS",
    "CODERELAY_ANDROID_KEY_PASSWORD",
)
val releaseSigningValues = releaseSigningNames.map { System.getenv(it) }
val hasReleaseSigning = releaseSigningValues.all { !it.isNullOrBlank() }
check(releaseSigningValues.all { it.isNullOrBlank() } || hasReleaseSigning) {
    "Incomplete CodeRelay signing configuration. Supply all four signing environment variables."
}
android {
    if (hasReleaseSigning) {
        signingConfigs.create("coderelayRelease") {
            storeFile = file(releaseSigningValues[0]!!)
            storePassword = releaseSigningValues[1]
            keyAlias = releaseSigningValues[2]
            keyPassword = releaseSigningValues[3]
        }
    }
    buildTypes.getByName("release") {
        signingConfig = if (hasReleaseSigning) signingConfigs.getByName("coderelayRelease") else null
    }
}
// END CODERELAY RELEASE SIGNING
