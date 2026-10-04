plugins { id("com.android.application") }

val rimesVersion = rootProject.file("VERSION").readText().trim()
require(Regex("(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)").matches(rimesVersion)) {
    "VERSION must contain MAJOR.MINOR.PATCH"
}
val signingNames = listOf("RIMES_ANDROID_KEYSTORE", "RIMES_ANDROID_STORE_PASSWORD",
    "RIMES_ANDROID_KEY_ALIAS", "RIMES_ANDROID_KEY_PASSWORD")
val releaseCredentials = signingNames.associateWith { providers.environmentVariable(it).orNull }
val hasReleaseSigning = releaseCredentials.values.all { !it.isNullOrBlank() }
require(releaseCredentials.values.all { it.isNullOrBlank() } || hasReleaseSigning) {
    "Supply all four RIMES_ANDROID signing environment variables, or none for an unsigned build"
}
android {
    namespace = "org.scholay.rimes.android"
    compileSdk { version = release(37) { minorApiLevel = 2 } }
    defaultConfig {
        applicationId = "org.scholay.rimes.android"
        minSdk = 26
        targetSdk = 37
        testInstrumentationRunner = "org.scholay.rimes.android.EngineInstrumentation"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        versionCode = 10
        versionName = rimesVersion
    }
    ndkVersion = "29.0.14206865"
    sourceSets.getByName("main") {
        assets.srcDir("build/generated/rime/assets")
        jniLibs.srcDir("build/generated/rime/jniLibs")
    }
    signingConfigs {
        if (hasReleaseSigning) {
            create("rimesRelease") {
                storeFile = file(releaseCredentials.getValue("RIMES_ANDROID_KEYSTORE")!!)
                require(storeFile!!.isFile) { "Release keystore does not exist" }
                storePassword = releaseCredentials.getValue("RIMES_ANDROID_STORE_PASSWORD")
                keyAlias = releaseCredentials.getValue("RIMES_ANDROID_KEY_ALIAS")
                keyPassword = releaseCredentials.getValue("RIMES_ANDROID_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        getByName("debug") { applicationIdSuffix = ".debug" }
        getByName("release") {
            isMinifyEnabled = false
            isDebuggable = false
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("rimesRelease")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies { implementation(project(":core")) }

tasks.named("preBuild") { dependsOn(rootProject.tasks.named("prepareOfficialPlugins")) }

// Generate with scripts/build-engine.py before Gradle; missing resources must fail closed.
tasks.register("verifyEngineResources", Exec::class) {
    commandLine("python3", "../scripts/verify-engine.py")
}
tasks.register("verifyOfflineDictionary", Exec::class) {
    commandLine("python3", "../resources/dictionary/verify-dictionary.py", "--check")
}
tasks.named("preBuild") { dependsOn("verifyEngineResources", "verifyOfflineDictionary") }
