package com.daozhang.py

import android.os.Handler
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Pure (Android-free) description of the interactive shell opened in the Debian guest.
 *
 * The shell runs over plain pipes (no PTY), exactly like the local shell, so the Dart
 * side provides echo and line editing. Prompt and rc files are therefore fixed here:
 * `--norc` keeps the prompt deterministic and skips slow or colourful rc files.
 */
internal object LinuxLikeShellSpec {
    const val DEFAULT_WORKING_DIR = "/root"
    const val PROMPT = "\\w # "

    /** `/bin/bash` when the rootfs has bash (merged-usr aware), else `/bin/sh`. */
    fun pickShell(rootfsDir: File): String {
        val hasBash = File(rootfsDir, "bin/bash").exists() || File(rootfsDir, "usr/bin/bash").exists()
        return if (hasBash) "/bin/bash" else "/bin/sh"
    }

    fun shellArguments(shell: String): List<String> =
        if (shell.endsWith("bash")) listOf(shell, "--norc", "--noediting", "-i") else listOf(shell, "-i")

    /** Variables the caller adds to the guest allow-list; host-only keys are dropped later anyway. */
    fun guestEnvironment(): Map<String, String> = mapOf("PS1" to PROMPT)

    fun resolveWorkingDir(requested: String?): String =
        requested?.trim()?.takeIf { it.isNotEmpty() } ?: DEFAULT_WORKING_DIR
}

/**
 * Builds everything Dart needs to start an interactive shell inside the Debian guest:
 * the full proot command line and the complete host-side environment. The guest itself is
 * cleaned by `env -i` inside the command; LD_LIBRARY_PATH and PROOT_* only reach proot.
 */
internal class LinuxLikeShellLauncher(private val runtime: LinuxLikeRuntimeManager) {
    fun prepare(workingDir: String?): Map<String, Any> {
        val info = runtime.getInfo()
        if (info["available"] != "true") {
            throw IllegalStateException(info["message"] ?: "Debian runtime unavailable")
        }
        val shell = LinuxLikeShellSpec.pickShell(runtime.rootfsDir)
        val command = runtime.buildGuestExecCommand(
            LinuxLikeShellSpec.shellArguments(shell),
            workingDir = LinuxLikeShellSpec.resolveWorkingDir(workingDir),
            environment = LinuxLikeShellSpec.guestEnvironment()
        )
        val environment = HashMap<String, String>(System.getenv())
        runtime.applyHostEnvironment(environment)
        return mapOf(
            "command" to command,
            "environment" to environment,
            "tempDir" to environment["PROOT_TMP_DIR"].orEmpty(),
            "shell" to shell,
            "compatMode" to runtime.prootCompatMode.toString()
        )
    }

    fun prepareAsync(workingDir: String?, mainHandler: Handler, result: MethodChannel.Result) {
        Thread {
            try {
                val launch = prepare(workingDir)
                mainHandler.post { result.success(launch) }
            } catch (e: Exception) {
                mainHandler.post { result.error("1048", "Debian shell: ${e.message}", null) }
            }
        }.also { it.name = "linux-like-shell-prepare"; it.start() }
    }

    fun release(tempDir: String?) {
        runtime.cleanupExecutionTempDir(tempDir?.takeIf { it.isNotBlank() })
    }
}
