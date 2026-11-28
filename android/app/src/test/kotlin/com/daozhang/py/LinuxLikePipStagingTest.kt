package com.daozhang.py

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.nio.file.Files

class LinuxLikePipStagingTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var site: File
    private lateinit var staging: File

    private fun prepare() {
        root = temp.newFolder()
        site = File(root, "site").also { it.mkdirs() }
        staging = File(root, "stage").also { it.mkdirs() }
    }

    private fun write(base: File, rel: String, text: String = "x") {
        val file = File(base, rel)
        file.parentFile?.mkdirs()
        file.writeText(text)
    }

    private fun snapshot(base: File): Map<String, String> =
        base.walkTopDown().filter { it.isFile }
            .associate { it.relativeTo(base).invariantSeparatorsPath to it.readText() }

    /** An installed distribution whose RECORD lists [files]. */
    private fun dist(base: File, project: String, version: String, files: List<String>) {
        val meta = "$project-$version.dist-info"
        files.forEach { write(base, it, "$project-$version") }
        write(base, "$meta/RECORD", files.joinToString("") { "$it,,\n" })
        write(base, "$meta/METADATA", "Name: $project\nVersion: $version\n")
    }

    private fun backups(): List<String> =
        root.list().orEmpty().filter { it.startsWith(LinuxLikePipStaging.BACKUP_PREFIX) }

    // --- merge -------------------------------------------------------------------------

    @Test
    fun newPackageIsMovedIn() {
        prepare()
        dist(staging, "foo", "1.0", listOf("foo/__init__.py", "foo/core.py"))
        val result = LinuxLikePipStaging.merge(staging, site)
        assertTrue("foo" in result.installed)
        assertEquals("foo-1.0", snapshot(site)["foo/core.py"])
        assertTrue(File(site, "foo-1.0.dist-info").isDirectory)
        assertEquals(emptyList<String>(), backups())
    }

    @Test
    fun leftoverOfFailedInstallIsReplaced() {
        prepare()
        // an earlier failed install left foo/ behind without any dist-info
        write(site, "foo/__init__.py", "broken")
        dist(site, "other", "2.0", listOf("other/__init__.py"))
        dist(staging, "foo", "1.0", listOf("foo/__init__.py"))
        val result = LinuxLikePipStaging.merge(staging, site)
        assertTrue("foo" in result.replaced)
        assertEquals("foo-1.0", snapshot(site)["foo/__init__.py"])
        assertEquals("other-2.0", snapshot(site)["other/__init__.py"])
        assertEquals(emptyList<String>(), backups())
    }

    @Test
    fun noLeftoverJudgementWhenOwnershipUnknown() {
        prepare()
        write(site, "foo/__init__.py", "keep")
        File(site, "weird-1.0.dist-info").mkdirs() // no RECORD, no top_level.txt
        dist(staging, "foo", "1.0", listOf("foo/__init__.py"))
        LinuxLikePipStaging.merge(staging, site)
        assertEquals("keep", snapshot(site)["foo/__init__.py"])
    }

    @Test
    fun ownedPackageIsNotOverwrittenWithoutUpgrade() {
        prepare()
        dist(site, "foo", "1.0", listOf("foo/__init__.py"))
        dist(staging, "foo", "2.0", listOf("foo/__init__.py"))
        val result = LinuxLikePipStaging.merge(staging, site)
        assertEquals("foo-1.0", snapshot(site)["foo/__init__.py"])
        assertFalse("foo" in result.replaced)
        // metadata must keep matching the files that stayed
        assertTrue(File(site, "foo-1.0.dist-info").isDirectory)
        assertFalse(File(site, "foo-2.0.dist-info").exists())
    }

    @Test
    fun packageOwnedByAnotherDistributionIsNotTreatedAsLeftover() {
        prepare()
        // dateutil/ belongs to python-dateutil; its RECORD names it, so a new install that also
        // ships dateutil/ must not wipe it
        dist(site, "python_dateutil", "2.9", listOf("dateutil/__init__.py"))
        dist(staging, "other", "1.0", listOf("dateutil/__init__.py", "other/__init__.py"))
        LinuxLikePipStaging.merge(staging, site)
        assertEquals("python_dateutil-2.9", snapshot(site)["dateutil/__init__.py"])
        assertEquals("other-1.0", snapshot(site)["other/__init__.py"])
    }

    @Test
    fun ownershipFromTopLevelTxtIsRespected() {
        prepare()
        write(site, "foo/__init__.py", "keep")
        write(site, "foo-1.0.dist-info/top_level.txt", "foo\n")
        dist(staging, "foo", "2.0", listOf("foo/__init__.py"))
        LinuxLikePipStaging.merge(staging, site)
        assertEquals("keep", snapshot(site)["foo/__init__.py"])
    }

    @Test
    fun namespaceDirsAreMergedWithoutOverwrite() {
        prepare()
        dist(site, "google_a", "1.0", listOf("google/a/__init__.py"))
        dist(staging, "google_b", "1.0", listOf("google/b/__init__.py", "google/a/__init__.py"))
        LinuxLikePipStaging.merge(staging, site)
        val snap = snapshot(site)
        assertEquals("google_a-1.0", snap["google/a/__init__.py"])
        assertEquals("google_b-1.0", snap["google/b/__init__.py"])
    }

    @Test
    fun upgradeReplacesPackageAndDropsOldDistInfo() {
        prepare()
        dist(site, "foo", "1.0", listOf("foo/__init__.py", "foo/old.py"))
        dist(staging, "foo", "2.0", listOf("foo/__init__.py"))
        LinuxLikePipStaging.merge(staging, site, upgrade = true)
        val snap = snapshot(site)
        assertEquals("foo-2.0", snap["foo/__init__.py"])
        assertFalse(snap.containsKey("foo/old.py"))
        assertFalse(File(site, "foo-1.0.dist-info").exists())
        assertTrue(File(site, "foo-2.0.dist-info").isDirectory)
        assertEquals(emptyList<String>(), backups())
    }

    @Test
    fun sharedDirsAreMergedNotReplaced() {
        prepare()
        for (shared in listOf("bin", "share", "include", "etc")) {
            write(site, "$shared/from_site", "a")
            write(staging, "$shared/from_stage", "b")
        }
        dist(staging, "foo", "1.0", listOf("foo/__init__.py"))
        LinuxLikePipStaging.merge(staging, site, upgrade = true)
        val snap = snapshot(site)
        for (shared in listOf("bin", "share", "include", "etc")) {
            assertEquals("a", snap["$shared/from_site"])
            assertEquals("b", snap["$shared/from_stage"])
        }
    }

    @Test
    fun existingFileInASharedDirIsNeverOverwritten() {
        prepare()
        write(site, "bin/tool", "old")
        write(staging, "bin/tool", "new")
        dist(staging, "foo", "1.0", listOf("foo/__init__.py"))
        LinuxLikePipStaging.merge(staging, site, upgrade = true)
        assertEquals("old", snapshot(site)["bin/tool"])
    }

    // --- rollback ----------------------------------------------------------------------

    @Test
    fun failureMidMergeRestoresTheSiteDir() {
        prepare()
        dist(site, "foo", "1.0", listOf("foo/__init__.py"))
        write(site, "leftover/__init__.py", "broken")
        val before = snapshot(site)
        dist(staging, "foo", "2.0", listOf("foo/__init__.py"))
        dist(staging, "leftover", "1.0", listOf("leftover/__init__.py"))
        dist(staging, "zzz", "1.0", listOf("zzz/__init__.py"))

        var calls = 0
        val flaky: (File, File) -> Unit = { src, dst ->
            calls++
            if (calls == 4) throw IOException("disk full")
            Files.move(src.toPath(), dst.toPath())
        }
        try {
            LinuxLikePipStaging.merge(staging, site, upgrade = true, mover = flaky)
            fail("merge should have failed")
        } catch (expected: IOException) {
            assertEquals("disk full", expected.message)
        }
        assertEquals(before, snapshot(site))
        assertEquals(emptyList<String>(), backups())
    }

    @Test
    fun failureWhileMergingASharedDirRemovesWhatWasAlreadyMovedIn() {
        prepare()
        write(site, "bin/tool_a", "a")
        write(staging, "bin/tool_b", "b")
        write(staging, "bin/tool_c", "c")
        dist(staging, "foo", "1.0", listOf("foo/__init__.py"))
        val before = snapshot(site)

        var calls = 0
        val flaky: (File, File) -> Unit = { src, dst ->
            calls++
            if (calls == 2) throw IOException("io error")
            Files.move(src.toPath(), dst.toPath())
        }
        try {
            LinuxLikePipStaging.merge(staging, site, mover = flaky)
            fail("merge should have failed")
        } catch (_: IOException) {
        }
        assertEquals(before, snapshot(site))
    }

    // --- staging dirs ------------------------------------------------------------------

    @Test
    fun stagingDirIsRemovedEvenOnError() {
        prepare()
        val stagingRoot = File(root, "user_site_staging")
        var kept: File? = null
        try {
            LinuxLikePipStaging.withStagingDir(stagingRoot) { dir ->
                write(dir, "a/b.txt")
                kept = dir
                throw IllegalStateException("pip failed")
            }
            fail("expected the exception to propagate")
        } catch (expected: IllegalStateException) {
            assertEquals("pip failed", expected.message)
        }
        assertFalse(kept!!.exists())
        assertTrue(stagingRoot.isDirectory)
    }

    @Test
    fun stagingDirsAreUniqueAndInsideTheRoot() {
        prepare()
        val stagingRoot = File(root, "user_site_staging")
        val first = LinuxLikePipStaging.newStagingDir(stagingRoot)
        val second = LinuxLikePipStaging.newStagingDir(stagingRoot)
        assertTrue(first != second)
        assertEquals(stagingRoot.absoluteFile, first.absoluteFile.parentFile)
        assertTrue(first.name.startsWith(LinuxLikePipStaging.STAGING_PREFIX))
    }

    @Test
    fun staleStagingDirsAreSweptAndFreshOnesKept() {
        prepare()
        val stagingRoot = File(root, "user_site_staging").also { it.mkdirs() }
        val stale = File(stagingRoot, LinuxLikePipStaging.STAGING_PREFIX + "old").also { it.mkdirs() }
        write(stale, "pkg/mod.py")
        val fresh = File(stagingRoot, LinuxLikePipStaging.STAGING_PREFIX + "new").also { it.mkdirs() }
        val foreign = File(stagingRoot, "not_ours").also { it.mkdirs() }
        stale.setLastModified(System.currentTimeMillis() - 2 * 60 * 60 * 1000L)
        foreign.setLastModified(System.currentTimeMillis() - 2 * 60 * 60 * 1000L)
        LinuxLikePipStaging.sweepStale(stagingRoot)
        assertFalse(stale.exists())
        assertTrue(fresh.exists())
        assertTrue(foreign.exists())
    }

    @Test
    fun deleteTreeDoesNotFollowSymlinks() {
        prepare()
        val outside = File(root, "outside").also { it.mkdirs() }
        write(outside, "keep.txt", "keep")
        val tree = File(root, "tree").also { it.mkdirs() }
        try {
            Files.createSymbolicLink(File(tree, "link").toPath(), outside.toPath())
        } catch (_: Exception) {
            return // symbolic links are not available on this file system
        }
        LinuxLikePipStaging.deleteTree(tree)
        assertFalse(tree.exists())
        assertEquals("keep", File(outside, "keep.txt").readText())
    }

    // --- helpers -----------------------------------------------------------------------

    @Test
    fun recordPathsAreParsedLikeACsvReader() {
        prepare()
        val meta = File(site, "foo-1.0.dist-info").also { it.mkdirs() }
        File(meta, "RECORD").writeText(
            listOf(
                "foo/__init__.py,sha256=abc,12",
                "\"quoted, dir/file.py\",,",
                "\"say \"\"hi\"\"/x.py\",,",
                "../../bin/foo,,",
                "/abs/path,,",
                "foo-1.0.dist-info/RECORD,,",
                ""
            ).joinToString("\n")
        )
        val owned = LinuxLikePipStaging.ownedTopLevels(site)
        assertTrue(owned.complete)
        assertEquals(
            setOf("foo", "quoted, dir", "say \"hi\"", "foo-1.0.dist-info"),
            owned.names
        )
    }

    @Test
    fun distributionWithoutRecordOrTopLevelMakesOwnershipIncomplete() {
        prepare()
        File(site, "weird-1.0.dist-info").mkdirs()
        assertFalse(LinuxLikePipStaging.ownedTopLevels(site).complete)
    }

    @Test
    fun projectNamesAreNormalizedLikeThePythonSide() {
        assertEquals("foo", LinuxLikePipStaging.projectOf("foo-1.0.dist-info"))
        assertEquals("python_dateutil", LinuxLikePipStaging.projectOf("python_dateutil-2.9.0.post0.dist-info"))
        assertEquals("scikit_learn", LinuxLikePipStaging.projectOf("scikit_learn-1.5.dist-info"))
        assertEquals("zope_interface", LinuxLikePipStaging.projectOf("zope.interface-6.0.egg-info"))
    }
}
