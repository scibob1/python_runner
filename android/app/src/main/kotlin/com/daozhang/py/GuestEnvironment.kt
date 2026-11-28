package com.daozhang.py

/**
 * Pure (Android-free) helpers that decide which environment variables the Debian
 * guest process may see.
 *
 * Background: the guest used to inherit the host app process environment through
 * proot. That environment carries Chaquopy's PYTHONPATH (Python 3.10 `.imy`
 * archives), so Debian's Python 3.11 read 3.10 bytecode and died with
 * "bad magic number in 'encodings'". The guest command is now wrapped in
 * `/usr/bin/env -i` plus an explicit allow-list; LD_LIBRARY_PATH and PROOT_*
 * stay on the host side and are only seen by the proot process itself.
 */
internal object GuestEnvironment {
    const val ENV_BINARY = "/usr/bin/env"
    const val DEFAULT_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    const val GUEST_TMPDIR = "/tmp"

    private val validKey = Regex("^[A-Za-z_][A-Za-z0-9_]*$")

    /** Substrings that mark a path as belonging to the host (Chaquopy) interpreter. */
    private val hostPythonMarkers = listOf("chaquopy", ".imy")

    /** Keys that only make sense for the host side (proot) and must never reach the guest. */
    private fun isHostOnlyKey(key: String): Boolean =
        key == "LD_LIBRARY_PATH" ||
            key.startsWith("LD_") ||
            key.startsWith("PROOT_") ||
            key == "PYTHONHOME" ||
            key == "PYTHONSTARTUP" ||
            key == "PYTHONEXECUTABLE" ||
            key.startsWith("CHAQUOPY")

    /** True when the key belongs to the host interpreter and is removed from the proot process too. */
    private fun isHostInterpreterKey(key: String): Boolean =
        key.startsWith("PYTHON") || key.startsWith("CHAQUOPY")

    fun isHostPythonEntry(entry: String): Boolean {
        val lower = entry.lowercase()
        return hostPythonMarkers.any { lower.contains(it) }
    }

    /**
     * Builds the complete guest environment: allow-listed defaults, caller supplied
     * variables merged on top (minus host-only keys), and a PYTHONPATH recomputed from
     * guest paths only.
     */
    fun build(
        callerEnvironment: Map<String, String>?,
        userSitePackageGuestPaths: List<String>
    ): LinkedHashMap<String, String> {
        val env = linkedMapOf(
            "HOME" to "/root",
            "USER" to "root",
            "LANG" to "C.UTF-8",
            "PATH" to DEFAULT_PATH,
            "TERM" to "xterm-256color",
            "TMPDIR" to GUEST_TMPDIR,
            "PIP_NO_INPUT" to "1",
            "PIP_DISABLE_PIP_VERSION_CHECK" to "1",
            "PIP_ROOT_USER_ACTION" to "ignore"
        )
        var callerPythonPath: String? = null
        callerEnvironment?.forEach { (key, value) ->
            if (!validKey.matches(key) || value.contains('\u0000')) return@forEach
            if (key == "PYTHONPATH") {
                callerPythonPath = value
                return@forEach
            }
            if (isHostOnlyKey(key)) return@forEach
            env[key] = value
        }
        val entries = userSitePackageGuestPaths.asSequence() +
            (callerPythonPath?.split(':')?.asSequence() ?: emptySequence())
        val pythonPath = entries
            .map { it.trim() }
            .filter { it.isNotEmpty() && !isHostPythonEntry(it) }
            .distinct()
            .joinToString(":")
        if (pythonPath.isNotEmpty()) env["PYTHONPATH"] = pythonPath
        return env
    }

    /** `/usr/bin/env -i K=V ...`, to be inserted right before the guest executable. */
    fun envCommand(env: Map<String, String>): List<String> {
        val result = mutableListOf(ENV_BINARY, "-i")
        env.forEach { (key, value) -> result.add("$key=$value") }
        return result
    }

    /**
     * Removes host interpreter variables (PYTHON*, CHAQUOPY*) from the environment of the
     * proot process. proot does not need them, and the guest is cleaned by `env -i` anyway;
     * this is a second line of defence.
     */
    fun scrubHostEnvironment(target: MutableMap<String, String>) {
        target.keys.removeAll { isHostInterpreterKey(it) }
    }
}
