import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. Reads android/key.properties (gitignored) so every build —
// local or CI — signs release APKs with the SAME persistent key. Without a
// stable key each build gets a different (debug) signature and Android rejects
// the upgrade with "package appears to be invalid". Absent the file (e.g. an
// outside contributor), we fall back to debug signing so the build still runs.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.xprs.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // No DependencyInfoBlock: AGP otherwise adds a signing block listing the
    // dependencies, encrypted with Google's public key so only Google can read
    // it. F-Droid asks for it to be off, and nothing here needs it.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xprs.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Persistent release key when key.properties is present; otherwise
            // debug so `flutter run --release` still works for contributors.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        // Profile builds carry the Dart VM service (isolate stacks, CPU
        // profiler, heap) with release-grade AOT performance — the only way to
        // profile what users actually run. Sign them with the SAME key as
        // release so a profile build can update an installed release in place,
        // instead of forcing an uninstall that would wipe the device identity.
        getByName("profile") {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

// The versionCode of a per-ABI APK: ABI digit x 1,000,000 + the build number
// (pubspec's +N, the commit count). F-Droid builds exactly these APKs and
// derives the same numbers (VercodeOperation in its recipe, docs/f-droid.md),
// so a phone can move between F-Droid and the in-app updater either way.
// Flutter's own scheme is digit x 1,000 + N, which collides across ABIs once
// N reaches 1,000. The digits are Flutter's, so every code already released
// (1000+N, 2000+N, 4000+N) stays below its successor. This runs after the
// Flutter plugin's override because the plugin registers its hook first.
val abiVersionDigit = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 4)
@Suppress("DEPRECATION")
android.applicationVariants.configureEach {
    val base = versionCode
    outputs.configureEach {
        val output = this as com.android.build.gradle.api.ApkVariantOutput
        val abi = output.getFilter(com.android.build.VariantOutput.FilterType.ABI)
        abiVersionDigit[abi]?.let { output.versionCodeOverride = it * 1_000_000 + base }
    }
}

dependencies {
    // MediaSessionCompat + MediaStyle notification for lock-screen media controls.
    implementation("androidx.media:media:1.7.0")
    // Plain JVM tests for the pure logic that used to hide inside Android
    // classes -- see RotationCursorTest. Run with `./gradlew testDebugUnitTest`
    // (under ~/bin/android-build-locked); assembleRelease does not run it.
    testImplementation("junit:junit:4.13.2")
}
