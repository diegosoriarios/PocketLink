plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val ciKeystoreFile = System.getenv("KEYSTORE_FILE")
val ciKeystorePassword = System.getenv("KEYSTORE_PASSWORD")
val ciKeyAlias = System.getenv("KEY_ALIAS")
val ciKeyPassword = System.getenv("KEY_PASSWORD")
val hasCiSigning = listOf(ciKeystoreFile, ciKeystorePassword, ciKeyAlias, ciKeyPassword).all { !it.isNullOrBlank() }

android {
    namespace = "com.diego.pocketlink"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.diego.pocketlink"
        minSdk = 29
        targetSdk = 35
        versionCode = (project.findProperty("appVersionCode") as String?)?.toInt() ?: 1
        versionName = (project.findProperty("appVersionName") as String?) ?: "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (hasCiSigning) {
            create("ci") {
                storeFile = file(ciKeystoreFile!!)
                storePassword = ciKeystorePassword
                keyAlias = ciKeyAlias
                keyPassword = ciKeyPassword
            }
        }
    }

    buildTypes {
        release {
            optimization {
                enable = false
            }
            if (hasCiSigning) {
                signingConfig = signingConfigs.getByName("ci")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.zxing.core)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation("org.json:json:20240303")
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    debugImplementation(libs.androidx.compose.ui.tooling)
}