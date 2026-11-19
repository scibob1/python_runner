package com.daozhang.py

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GuestEnvironmentTest {
    private val userSite = listOf(
        "/python-runner/site-packages",
        "/data/data/com.daozhang.py/files/linux_like/user_site_packages"
    )

    private val chaquopyPythonPath = listOf(
        "/data/data/com.daozhang.py/files/chaquopy/AssetFinder/stdlib-common.imy",
        "/data/data/com.daozhang.py/files/chaquopy/AssetFinder/bootstrap.imy",
        "/data/app/com.daozhang.py/base.apk/assets/chaquopy/bootstrap-native/arm64-v8a"
    ).joinToString(":")

    private fun assertNoHostPython(env: Map<String, String>) {
        env.forEach { (key, value) ->
            val text = "$key=$value".lowercase()
            assertFalse("leaked chaquopy: $text", text.contains("chaquopy"))
            assertFalse("leaked .imy: $text", text.contains(".imy"))
        }
    }

    @Test
    fun hostPythonPathNeverReachesGuest() {
        val env = GuestEnvironment.build(
            mapOf(
                "PYTHONPATH" to "$chaquopyPythonPath:/storage/emulated/0/proj",
                "PYTHONHOME" to "/data/data/com.daozhang.py/files/chaquopy",
                "CHAQUOPY_FOO" to "1"
            ),
            userSite
        )
        assertNoHostPython(env)
        assertNull(env["PYTHONHOME"])
        assertEquals(
            "/python-runner/site-packages:" +
                "/data/data/com.daozhang.py/files/linux_like/user_site_packages:" +
                "/storage/emulated/0/proj",
            env["PYTHONPATH"]
        )
    }

    @Test
    fun hostOnlyVariablesAreDropped() {
        val env = GuestEnvironment.build(
            mapOf(
                "LD_LIBRARY_PATH" to "/data/app/lib/arm64",
                "LD_PRELOAD" to "/x.so",
                "PROOT_TMP_DIR" to "/data/data/x/tmp",
                "PROOT_NO_SECCOMP" to "1",
                "PYRUNNER_HTTP_HOOK_CONFIG" to "{}"
            ),
            userSite
        )
        assertTrue(env.keys.none { it.startsWith("LD_") || it.startsWith("PROOT_") })
        assertEquals("{}", env["PYRUNNER_HTTP_HOOK_CONFIG"])
    }

    @Test
    fun allowListDefaultsArePresent() {
        val env = GuestEnvironment.build(null, userSite)
        assertEquals("/root", env["HOME"])
        assertEquals("root", env["USER"])
        assertEquals("C.UTF-8", env["LANG"])
        assertEquals(GuestEnvironment.DEFAULT_PATH, env["PATH"])
        assertEquals("xterm-256color", env["TERM"])
        assertEquals(GuestEnvironment.GUEST_TMPDIR, env["TMPDIR"])
        assertEquals("1", env["PIP_NO_INPUT"])
        assertEquals("1", env["PIP_DISABLE_PIP_VERSION_CHECK"])
        assertEquals("ignore", env["PIP_ROOT_USER_ACTION"])
        assertTrue(env["PYTHONPATH"]!!.startsWith("/python-runner/site-packages"))
    }

    @Test
    fun callerEnvironmentIsMergedOnTop() {
        val env = GuestEnvironment.build(
            mapOf(
                "HOME" to "/storage/emulated/0/Download/PythonRunner",
                "PIP_INDEX_URL" to "https://example.invalid/simple"
            ),
            userSite
        )
        assertEquals("/storage/emulated/0/Download/PythonRunner", env["HOME"])
        assertEquals("https://example.invalid/simple", env["PIP_INDEX_URL"])
    }

    @Test
    fun invalidKeysAndValuesAreRejected() {
        val env = GuestEnvironment.build(
            mapOf(
                "" to "x",
                "A=B" to "x",
                "-i" to "x",
                "BAD" to "a\u0000b",
                "GOOD" to "ok"
            ),
            userSite
        )
        assertNull(env["A=B"])
        assertNull(env["-i"])
        assertNull(env["BAD"])
        assertEquals("ok", env["GOOD"])
    }

    @Test
    fun envCommandStartsWithEnvDashIAndContainsNoLeak() {
        val env = GuestEnvironment.build(
            mapOf("PYTHONPATH" to chaquopyPythonPath),
            userSite
        )
        val command = GuestEnvironment.envCommand(env)
        assertEquals("/usr/bin/env", command[0])
        assertEquals("-i", command[1])
        assertTrue(command.drop(2).all { it.contains('=') })
        val joined = command.joinToString(" ").lowercase()
        assertFalse(joined.contains("chaquopy"))
        assertFalse(joined.contains(".imy"))
    }

    @Test
    fun scrubHostEnvironmentRemovesInterpreterVariablesOnly() {
        val host = mutableMapOf(
            "PYTHONPATH" to chaquopyPythonPath,
            "PYTHONHOME" to "/data/data/com.daozhang.py/files/chaquopy",
            "CHAQUOPY_X" to "1",
            "PATH" to "/system/bin",
            "ANDROID_ROOT" to "/system"
        )
        GuestEnvironment.scrubHostEnvironment(host)
        assertEquals(setOf("PATH", "ANDROID_ROOT"), host.keys)
    }
}
