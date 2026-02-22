// C:\Users\zidan\AndroidStudioProjects\aelmamclinic\android\app\build.gradle.kts

import java.io.File
import kotlin.io.walkTopDown
import org.gradle.api.DefaultTask

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.aelmamclinic"
    compileSdk = 36
    ndkVersion = "28.0.13004108"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }
    kotlinOptions { jvmTarget = "17" }

    defaultConfig {
        applicationId = "com.example.aelmamclinic"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    androidResources {
        noCompress.addAll(
            listOf(
                "mp3","wav","ogg","m4a","aac",
                "mp4","zip","pdf","tflite","onnx",
                "db","sqlite","bin"
            )
        )
    }

    splits {
        abi {
            isEnable = false
            isUniversalApk = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug { }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    implementation("com.google.android.play:core:1.10.3")
}

flutter { source = "../.." }

/* ─── Copy latest Debug APK for Flutter ─── */
abstract class CopyLatestDebugApk : DefaultTask() {
    @TaskAction
    fun run() {
        val appBuildDir = project.layout.buildDirectory.asFile.get()
        val searchDirs = listOf(
            File(appBuildDir, "outputs/apk/debug"),
            File(appBuildDir, "outputs/universal_apk/debug"),
            File(appBuildDir, "outputs/apk"),
            File(appBuildDir, "intermediates/apk/debug"),
            File(appBuildDir, "intermediates/apk")
        )

        val candidates = mutableListOf<File>()
        for (dir in searchDirs) {
            if (dir.isDirectory) {
                dir.walkTopDown().forEach { f: File ->
                    if (f.isFile && f.name.endsWith(".apk", true) && f.name.contains("debug", true)) {
                        candidates.add(f)
                    }
                }
            }
        }

        if (candidates.isEmpty()) {
            logger.warn("لم يتم العثور على أي Debug APK داخل: $appBuildDir")
            return
        }

        val latest = candidates.maxByOrNull { it.lastModified() }!!
        val flutterRoot = project.rootProject.projectDir.parentFile!!
        val destDir = File(flutterRoot, "build/app/outputs/flutter-apk")
        if (!destDir.exists()) destDir.mkdirs()
        val destFile = File(destDir, "app-debug.apk")

        latest.copyTo(destFile, overwrite = true)
        logger.lifecycle("Copied Debug APK: ${latest.absolutePath} ➜ ${destFile.absolutePath}")
    }
}

val copyDebugApkForFlutter by tasks.registering(CopyLatestDebugApk::class)

/* ─── Copy latest Release APK for Flutter ─── */
abstract class CopyLatestReleaseApk : DefaultTask() {
    @TaskAction
    fun run() {
        val appBuildDir = project.layout.buildDirectory.asFile.get()
        val searchDirs = listOf(
            File(appBuildDir, "outputs/apk/release"),
            File(appBuildDir, "outputs/universal_apk/release"),
            File(appBuildDir, "outputs/apk"),
            File(appBuildDir, "intermediates/apk/release"),
            File(appBuildDir, "intermediates/apk")
        )

        val candidates = mutableListOf<File>()
        for (dir in searchDirs) {
            if (dir.isDirectory) {
                dir.walkTopDown().forEach { f: File ->
                    if (f.isFile && f.name.endsWith(".apk", true) && f.name.contains("release", true)) {
                        candidates.add(f)
                    }
                }
            }
        }

        if (candidates.isEmpty()) {
            logger.warn("لم يتم العثور على أي Release APK داخل: $appBuildDir")
            return
        }

        val latest = candidates.maxByOrNull { it.lastModified() }!!
        val flutterRoot = project.rootProject.projectDir.parentFile!!
        val destDir = File(flutterRoot, "build/app/outputs/flutter-apk")
        if (!destDir.exists()) destDir.mkdirs()
        val destFile = File(destDir, "app-release.apk")

        latest.copyTo(destFile, overwrite = true)
        logger.lifecycle("Copied Release APK: ${latest.absolutePath} ➜ ${destFile.absolutePath}")
    }
}

val copyReleaseApkForFlutter by tasks.registering(CopyLatestReleaseApk::class)

tasks.configureEach {
    val n = name.lowercase()
    if ((n.startsWith("package") || n.startsWith("assemble") || n.startsWith("bundle")) && n.endsWith("debug")) {
        finalizedBy(copyDebugApkForFlutter)
    }
    if ((n.startsWith("package") || n.startsWith("assemble") || n.startsWith("bundle")) && n.endsWith("release")) {
        finalizedBy(copyReleaseApkForFlutter)
    }
}
