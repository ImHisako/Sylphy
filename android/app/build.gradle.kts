import java.util.Properties
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningProperties = Properties()
val releaseSigningFile = rootProject.file("key.properties")
if (releaseSigningFile.exists()) {
    releaseSigningFile.inputStream().use(releaseSigningProperties::load)
}
val hasReleaseSigning = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !releaseSigningProperties.getProperty(it).isNullOrBlank() }

fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

fun sha256(value: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
    return digest.joinToString("") { "%02x".format(it) }
}

val verifySylphyNativeCore by tasks.registering {
    group = "verification"
    description = "Rejects stale or mismatched Rust libraries before Android packaging."
    doLast {
        val root = file("src/main/jniLibs")
        val metadataFile = root.resolve("sylphy-core.properties")
        check(metadataFile.isFile) {
            "Native metadata missing. Run native/build-android.ps1 before building Android."
        }
        val metadata = Properties().apply {
            metadataFile.inputStream().use(::load)
        }
        check(metadata.getProperty("abi") == "10") { "Stale Sylphy native ABI." }
        check(metadata.getProperty("libsignal") == "signalapp/libsignal@v0.100.0") {
            "Android native core was not built with libsignal v0.100.0."
        }
        val nativeCore = file("../../native/core")
        val sourceFiles = (
            fileTree(nativeCore.resolve("src")) { include("**/*.rs") }.files +
                listOf(nativeCore.resolve("Cargo.toml"), nativeCore.resolve("Cargo.lock"))
            ).sortedBy { it.absolutePath }
        val sourceFingerprint = sha256(sourceFiles.joinToString("") { sha256(it) })
        check(metadata.getProperty("source.sha256") == sourceFingerprint) {
            "Sylphy Rust sources changed after the Android libraries were built."
        }
        listOf("armeabi-v7a", "arm64-v8a", "x86_64").forEach { abi ->
            val library = root.resolve("$abi/libsylphy_core.so")
            check(library.isFile) { "Missing Sylphy native library for $abi." }
            check(metadata.getProperty("$abi.sha256") == sha256(library)) {
                "Sylphy native library for $abi does not match its build metadata."
            }
        }
    }
}

tasks.configureEach {
    if (name == "preBuild") dependsOn(verifySylphyNativeCore)
}

android {
    namespace = "com.example.sylphy"
    compileSdk = flutter.compileSdkVersion
    // Veilid 0.5.x requires NDK r28c and its Android bridge targets Java 17.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Never change this value: Android identifies upgrades by applicationId.
        applicationId = "com.example.sylphy"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = rootProject.file(releaseSigningProperties.getProperty("storeFile"))
                storePassword = releaseSigningProperties.getProperty("storePassword")
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Local development remains installable without secrets. Published
            // builds must keep key.properties (and its keystore) for every
            // future version so Android can update in place.
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "release" else "debug")
            // Veilid's Android protected store reaches AndroidX Security through
            // JNI/reflection, so R8 cannot discover those references itself.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    // Veilid's protected store loads these classes through JNI at runtime.
    implementation("androidx.security:security-crypto:1.1.0")
    testImplementation("junit:junit:4.13.2")
}
