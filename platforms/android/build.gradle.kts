plugins {
    id("com.android.application") version "9.4.0" apply false
}


val prepareOfficialPlugins by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.resolve("../.."))
    commandLine("python3", "scripts/prepare-official-plugins.py")
}
subprojects {
    tasks.withType<JavaCompile>().configureEach { dependsOn(prepareOfficialPlugins) }
}
