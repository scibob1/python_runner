package com.daozhang.py

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class LinuxLikeShellSpecTest {
    @get:Rule
    val temp = TemporaryFolder()

    private fun rootfs(vararg files: String): File {
        val dir = temp.newFolder()
        files.forEach { rel ->
            val file = File(dir, rel)
            file.parentFile?.mkdirs()
            file.writeText("x")
        }
        return dir
    }

    @Test
    fun usesBashWhenPresent() {
        assertEquals("/bin/bash", LinuxLikeShellSpec.pickShell(rootfs("bin/bash")))
        assertEquals("/bin/bash", LinuxLikeShellSpec.pickShell(rootfs("usr/bin/bash")))
    }

    @Test
    fun fallsBackToShWithoutBash() {
        assertEquals("/bin/sh", LinuxLikeShellSpec.pickShell(rootfs("bin/sh")))
        assertEquals("/bin/sh", LinuxLikeShellSpec.pickShell(rootfs()))
    }

    @Test
    fun bashStartsWithoutRcAndReadline() {
        assertEquals(
            listOf("/bin/bash", "--norc", "--noediting", "-i"),
            LinuxLikeShellSpec.shellArguments("/bin/bash")
        )
        assertEquals(listOf("/bin/sh", "-i"), LinuxLikeShellSpec.shellArguments("/bin/sh"))
    }

    @Test
    fun guestEnvironmentOnlyCarriesThePrompt() {
        val env = LinuxLikeShellSpec.guestEnvironment()
        assertEquals("\\w # ", env["PS1"])
        assertTrue(env.keys.none { it.startsWith("PROOT_") || it.startsWith("LD_") })
    }

    @Test
    fun guestEnvironmentSurvivesTheGuestAllowList() {
        val merged = GuestEnvironment.build(
            LinuxLikeShellSpec.guestEnvironment(),
            listOf("/python-runner/site-packages")
        )
        assertEquals("\\w # ", merged["PS1"])
        assertEquals("/root", merged["HOME"])
        assertFalse(merged.keys.any { it.startsWith("PROOT_") })
    }

    @Test
    fun workingDirDefaultsToRoot() {
        assertEquals("/root", LinuxLikeShellSpec.resolveWorkingDir(null))
        assertEquals("/root", LinuxLikeShellSpec.resolveWorkingDir("  "))
        assertEquals("/sdcard/Download", LinuxLikeShellSpec.resolveWorkingDir(" /sdcard/Download "))
    }
}
