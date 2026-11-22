package com.daozhang.py

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class LinuxLikeIntegrityCheckTest {
    @get:Rule
    val temp = TemporaryFolder()

    private fun site(vararg files: String): File {
        val dir = temp.newFolder()
        files.forEach { rel ->
            val file = File(dir, rel)
            file.parentFile?.mkdirs()
            file.writeText("x")
        }
        return dir
    }

    private fun check(
        siteDir: File,
        metaName: String,
        record: List<String>,
        topLevel: List<String> = emptyList()
    ): LinuxLikeIntegrity {
        val metaDir = File(siteDir, metaName).also { it.mkdirs() }
        return LinuxLikeIntegrityCheck.resolve(siteDir, metaDir, topLevel, record)
    }

    // RECORD of a real scikit-learn 1.x wheel: no top_level.txt, bundled libs in scikit_learn.libs/
    private val sklearnRecord = listOf(
        "sklearn/__init__.py",
        "sklearn/_isotonic.cpython-311-aarch64-linux-gnu.so",
        "sklearn/utils/__init__.py",
        "scikit_learn.libs/libgomp-a49a47f9.so.1.0.0",
        "scikit_learn-1.9.1.dist-info/METADATA",
        "scikit_learn-1.9.1.dist-info/RECORD"
    )

    @Test
    fun bundledLibsDirectoryIsNotAnImportRoot() {
        val dir = site("sklearn/__init__.py", "scikit_learn.libs/libgomp-a49a47f9.so.1.0.0")
        val result = check(dir, "scikit_learn-1.9.1.dist-info", sklearnRecord)
        assertEquals("ok", result.status)
        assertTrue(result.missingImports.isEmpty())
        assertEquals(
            listOf("sklearn"),
            LinuxLikeIntegrityCheck.inferImportRoots("scikit_learn-1.9.1.dist-info", emptyList(), sklearnRecord)
        )
    }

    @Test
    fun pillowLibsDirectoryDoesNotProduceMissingPillow() {
        val record = listOf(
            "PIL/__init__.py",
            "PIL/_imaging.cpython-311-aarch64-linux-gnu.so",
            "pillow.libs/libjpeg-1234.so.62.4.0",
            "pillow-12.0.0.dist-info/RECORD"
        )
        val result = check(site("PIL/__init__.py", "pillow.libs/libjpeg-1234.so.62.4.0"), "pillow-12.0.0.dist-info", record)
        assertEquals("ok", result.status)
    }

    @Test
    fun trulyMissingPackageIsStillReportedBroken() {
        val result = check(
            site("scikit_learn.libs/libgomp-a49a47f9.so.1.0.0"),
            "scikit_learn-1.9.1.dist-info",
            sklearnRecord
        )
        assertEquals("broken", result.status)
        assertEquals(listOf("sklearn"), result.missingImports)
        assertEquals("缺少 sklearn", result.message)
    }

    @Test
    fun onlyTheMissingRootIsReported() {
        // optiland ships two import packages
        val record = listOf(
            "optiland/__init__.py",
            "optiland_gui/__init__.py",
            "optiland-0.6.3.dist-info/METADATA"
        )
        assertEquals("ok", check(site("optiland/__init__.py", "optiland_gui/__init__.py"), "optiland-0.6.3.dist-info", record).status)
        val broken = check(site("optiland/__init__.py"), "optiland-0.6.3.dist-info", record)
        assertEquals("broken", broken.status)
        assertEquals(listOf("optiland_gui"), broken.missingImports)
    }

    @Test
    fun topLevelTxtWinsOverRecord() {
        val result = check(
            site("yaml/__init__.py"),
            "PyYAML-6.0.dist-info",
            record = listOf("_yaml/__init__.py", "yaml/__init__.py"),
            topLevel = listOf("yaml")
        )
        assertEquals("ok", result.status)
    }

    @Test
    fun dataOnlyEntriesGiveUnknownNotBroken() {
        val record = listOf(
            "bin/tool",
            "share/jupyter/kernels/x.json",
            "include/site/python3.11/foo.h",
            "foo/__pycache__/a.cpython-311.pyc",
            "foo-1.0.dist-info/METADATA"
        )
        val result = check(site(), "foo-1.0.dist-info", record)
        assertEquals("unknown", result.status)
    }

    @Test
    fun extensionModuleInsideRootCountsAndTopLevelSingleFilesWork() {
        val record = listOf(
            "numpy/_core/_multiarray_umath.cpython-311-aarch64-linux-gnu.so",
            "numpy.libs/libscipy_openblas64_-abc.so",
            "six.py",
            "numpy-2.5.0.dist-info/RECORD"
        )
        assertEquals(
            listOf("numpy", "six"),
            LinuxLikeIntegrityCheck.inferImportRoots("numpy-2.5.0.dist-info", emptyList(), record)
        )
    }

    @Test
    fun importRootExistsAcceptsDirectoryModuleFileAndExtensionFile() {
        val dir = site(
            "pkg/__init__.py",
            "single.py",
            "_cffi_backend.cpython-311-aarch64-linux-gnu.so"
        )
        assertTrue(LinuxLikeIntegrityCheck.importRootExists(dir, "pkg"))
        assertTrue(LinuxLikeIntegrityCheck.importRootExists(dir, "single"))
        assertTrue(LinuxLikeIntegrityCheck.importRootExists(dir, "_cffi_backend"))
        assertTrue(!LinuxLikeIntegrityCheck.importRootExists(dir, "nothing"))
    }

    @Test
    fun suspiciousRecordPathsAreIgnored() {
        assertNull(LinuxLikeIntegrityCheck.importRootFromRecordPath("../../etc/passwd.py", "x-1.dist-info"))
        assertNull(LinuxLikeIntegrityCheck.importRootFromRecordPath("x-1.dist-info/RECORD", "x-1.dist-info"))
        assertNull(LinuxLikeIntegrityCheck.importRootFromRecordPath("", "x-1.dist-info"))
    }

    @Test
    fun ownedRootsCoverExtraImportDirectoriesOfAPackage() {
        // none of these wheels has top_level.txt; their second import root must stay owned
        assertEquals(
            setOf("dateutil"),
            LinuxLikeIntegrityCheck.ownedImportRoots(
                "python_dateutil-2.9.0.dist-info",
                emptyList(),
                listOf("dateutil/__init__.py", "dateutil/parser/__init__.py", "python_dateutil-2.9.0.dist-info/RECORD")
            )
        )
        assertEquals(
            setOf("matplotlib", "mpl_toolkits", "pylab"),
            LinuxLikeIntegrityCheck.ownedImportRoots(
                "matplotlib-3.10.0.dist-info",
                emptyList(),
                listOf(
                    "matplotlib/__init__.py",
                    "matplotlib/_path.cpython-311-aarch64-linux-gnu.so",
                    "mpl_toolkits/axes_grid1/__init__.py",
                    "pylab.py",
                    "matplotlib.libs/libfoo.so"
                )
            )
        )
        assertEquals(
            setOf("optiland", "optiland_gui"),
            LinuxLikeIntegrityCheck.ownedImportRoots(
                "optiland-0.6.3.dist-info",
                emptyList(),
                listOf("optiland/__init__.py", "optiland_gui/__init__.py")
            )
        )
    }

    @Test
    fun ownedRootsUnionDeclaredAndRecord() {
        assertEquals(
            setOf("yaml", "_yaml"),
            LinuxLikeIntegrityCheck.ownedImportRoots(
                "PyYAML-6.0.dist-info",
                listOf("yaml"),
                listOf("_yaml/__init__.py", "yaml/__init__.py")
            )
        )
    }

    @Test
    fun nonMetadataEntriesAreAlwaysOk() {
        val dir = site("loose/__init__.py")
        val result = LinuxLikeIntegrityCheck.resolve(dir, File(dir, "loose"), listOf("loose"), emptyList())
        assertEquals("ok", result.status)
    }
}
