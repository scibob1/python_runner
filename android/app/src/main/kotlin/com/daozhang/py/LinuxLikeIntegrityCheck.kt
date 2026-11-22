package com.daozhang.py

import java.io.File

internal data class LinuxLikeIntegrity(
    val status: String,
    val message: String,
    val missingImports: List<String>
)

/**
 * Decides whether an installed distribution in the Debian user site directory still has
 * the files it is supposed to provide (pure JVM, no Android dependencies).
 *
 * Import roots come from top_level.txt when the distribution has one; wheels built with
 * meson / maturin / flit (scikit-learn, ...) have none, so they are inferred from RECORD.
 * Only entries that can actually be imported count: a RECORD path must be a Python module
 * or an extension module. Directories such as `scikit_learn.libs/` (bundled shared
 * libraries), `bin/`, `share/` or `__pycache__/` are not import roots, otherwise they are
 * reported as "missing" (`scikit_learn`, `pillow`, ...) although nothing is wrong.
 */
internal object LinuxLikeIntegrityCheck {
    private val identifier = Regex("[A-Za-z_][A-Za-z0-9_]*")
    private val moduleSuffixes = listOf(".py", ".so", ".pyd")
    private val metadataSuffixes = listOf(".dist-info", ".egg-info", ".data", ".libs")

    fun resolve(
        siteDir: File,
        metadataDir: File,
        topLevelEntries: List<String>,
        recordEntries: List<String>
    ): LinuxLikeIntegrity {
        val metadataBacked = metadataDir.name.endsWith(".dist-info") ||
            metadataDir.name.endsWith(".egg-info")
        if (!metadataBacked) {
            return LinuxLikeIntegrity("ok", "", emptyList())
        }
        val importRoots = inferImportRoots(metadataDir.name, topLevelEntries, recordEntries)
        if (importRoots.isEmpty()) {
            return LinuxLikeIntegrity("unknown", "", emptyList())
        }
        val missingImports = importRoots
            .filterNot { importRootExists(siteDir, it) }
            .distinct()
            .sorted()
        if (missingImports.isEmpty()) {
            return LinuxLikeIntegrity("ok", "", emptyList())
        }
        return LinuxLikeIntegrity(
            "broken",
            "缺少 ${missingImports.joinToString("、")}",
            missingImports
        )
    }

    fun inferImportRoots(
        metadataDirName: String,
        topLevelEntries: List<String>,
        recordEntries: List<String>
    ): List<String> {
        val declaredRoots = topLevelEntries
            .mapNotNull(::normalizeImportRoot)
            .distinct()
        if (declaredRoots.isNotEmpty()) {
            return declaredRoots
        }
        return recordEntries
            .mapNotNull { recordPath -> importRootFromRecordPath(recordPath, metadataDirName) }
            .distinct()
    }

    fun normalizeImportRoot(value: String): String? {
        val normalizedPath = value
            .trim()
            .replace('\\', '/')
            .trim('/')
        if (normalizedPath.isBlank() || normalizedPath.contains("..")) {
            return null
        }
        val root = normalizedPath
            .substringBefore('/')
            .substringBefore('.')
            .trim()
        return root.takeIf { it.matches(identifier) }
    }

    fun importRootFromRecordPath(recordPath: String, metadataDirName: String): String? {
        val normalizedPath = recordPath
            .trim()
            .replace('\\', '/')
            .trim('/')
        if (normalizedPath.isBlank() || normalizedPath.contains("..")) {
            return null
        }
        val firstSegment = normalizedPath.substringBefore('/').trim()
        if (firstSegment.isBlank() ||
            firstSegment == metadataDirName ||
            firstSegment == "__pycache__" ||
            metadataSuffixes.any { firstSegment.endsWith(it) }
        ) {
            return null
        }
        if (!normalizedPath.contains('/')) {
            if (!firstSegment.endsWith(".py")) {
                return null
            }
            return normalizeImportRoot(firstSegment.dropLast(3))
        }
        if (moduleSuffixes.none { normalizedPath.endsWith(it) }) {
            return null
        }
        return normalizeImportRoot(firstSegment)
    }

    fun importRootExists(siteDir: File, importRoot: String): Boolean {
        val root = normalizeImportRoot(importRoot) ?: return false
        if (File(siteDir, root).exists() || File(siteDir, "$root.py").isFile) {
            return true
        }
        return siteDir.listFiles()?.any { file ->
            file.isFile && file.name.startsWith("$root.")
        } == true
    }
}
