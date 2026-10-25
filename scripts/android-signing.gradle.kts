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
