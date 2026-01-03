import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.arjun.pantrychef"
    compileSdk = flutter.compileSdkVersion.toInt()
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.arjun.pantrychef"
        minSdk = flutter.minSdkVersion 
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true 
    }

    // --- KEY LOADING (Fixed with Imports) ---
    val keystoreProperties = Properties()
    val keyPropsFile = rootProject.file("key.properties")
    
    if (keyPropsFile.exists()) {
        keystoreProperties.load(FileInputStream(keyPropsFile))
    }

    signingConfigs {
        create("release") {
            if (keyPropsFile.exists() && keystoreProperties.containsKey("keyAlias")) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (keyPropsFile.exists() && keystoreProperties.containsKey("keyAlias")) {
                signingConfig = signingConfigs.getByName("release")
            }
            
            // --- SETTINGS FIXED TO PREVENT CRASH ---
            isMinifyEnabled = false
            isShrinkResources = false
            // ---------------------------------------

            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.multidex:multidex:2.0.1")
}
