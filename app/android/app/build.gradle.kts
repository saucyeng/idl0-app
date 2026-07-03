plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.idl0"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Published application identity (Play + OAuth Android client bind to
        // this). The internal `namespace` above stays on the generated value;
        // they are allowed to differ.
        applicationId = "com.saucyeng.idl0"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion  // BLE requires API 21+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Single signing config shared by debug AND release so every APK from
    // this repo carries the same certificate. Same cert = `adb install -r`
    // (no uninstall) every time `flutter install` runs — and the user's
    // session library survives reinstalls.
    //
    // The keystore lives at ~/.android/idl0-dev.jks (per-machine, not
    // committed). Recreate with:
    //   keytool -genkeypair -v -keystore ~/.android/idl0-dev.jks \
    //     -keyalg RSA -keysize 2048 -validity 36500 -alias idl0 \
    //     -storepass idl0dev -keypass idl0dev \
    //     -dname "CN=IDL0 Dev, OU=Dev, O=Saucy, L=Local, S=Local, C=US"
    //
    // TODO(idl0): production keystore for Play Store — see TASKS.md.
    signingConfigs {
        create("idl0") {
            storeFile = file("${System.getProperty("user.home")}/.android/idl0-dev.jks")
            storePassword = "idl0dev"
            keyAlias = "idl0"
            keyPassword = "idl0dev"
        }
    }

    buildTypes {
        getByName("debug") {
            signingConfig = signingConfigs.getByName("idl0")
        }
        release {
            signingConfig = signingConfigs.getByName("idl0")
        }
    }

    // The Rust engine .so is built and packaged for Android by the
    // rust_lib_idl0 cargokit plugin (app/rust_builder); no manual jniLibs wiring.
}

// The Rust engine is cross-compiled and packaged for Android by the
// rust_lib_idl0 cargokit plugin (app/rust_builder) — no manual cargo-ndk task.

flutter {
    source = "../.."
}
