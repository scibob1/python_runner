package com.daozhang.py

import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.util.Locale

internal data class LinuxLikeMergeResult(
    val installed: List<String>,
    val replaced: List<String>,
    val skipped: List<String>
)

internal data class LinuxLikeOwnedTopLevels(
    val names: Set<String>,
    val complete: Boolean
)

/**
 * Staged pip installs for the Debian user site directory (pure JVM, no Android dependencies;
 * the Kotlin twin of python/pip_staging.py).
 *
 * pip is pointed at a fresh staging directory; only after it exits successfully are the
 * results merged into the real site directory. Any failure -- pip's own, or while merging --
 * leaves the site directory exactly as it was, so a failed or interrupted install can no
 * longer leave half-installed packages behind that block the next attempt.
 *
 * Merge rules (mirroring `pip --target` where it makes sense):
 *  - top-level entry missing in the site dir             -> moved in
 *  - entry exists, `upgrade` requested                   -> old one backed up, new one moved in
 *  - entry exists but no installed distribution owns it  -> leftover of an earlier failed
 *                                                           install: replaced
 *  - dist-info / egg-info that already exists            -> skipped (same distribution)
 *  - other existing directories (namespace packages,
 *    `bin/`, `share/`, ...)                              -> files merged, never overwritten
 *
 * Differences from the Python version: the shared directories are the ones a wheel's
 * `.data` scheme writes next to the packages under `--target` (bin, include, share, etc);
 * there is no `chaquopy/` here.
 */
internal object LinuxLikePipStaging {
    const val STAGING_PREFIX = "stage_"
    const val BACKUP_PREFIX = ".pip_backup_"
    private const val DEFAULT_STALE_MILLIS = 60L * 60L * 1000L

    // Shared directories are always merged file by file, never replaced as a whole.
    private val sharedDirs = setOf("bin", "include", "share", "etc", "__pycache__")

    /** A fresh empty directory below [stagingRoot] (same filesystem as the site dir). */
    fun newStagingDir(stagingRoot: File): File {
        sweepStale(stagingRoot)
        stagingRoot.mkdirs()
        return Files.createTempDirectory(stagingRoot.toPath(), STAGING_PREFIX).toFile()
    }

    /** Runs [block] with a fresh staging directory that is always removed afterwards. */
    fun <T> withStagingDir(stagingRoot: File, block: (File) -> T): T {
        val staging = newStagingDir(stagingRoot)
        try {
            return block(staging)
        } finally {
            deleteTree(staging)
        }
    }

    /** Removes staging directories left behind by a crashed install. */
    fun sweepStale(
        stagingRoot: File,
        maxAgeMillis: Long = DEFAULT_STALE_MILLIS,
        now: Long = System.currentTimeMillis()
    ) {
        val entries = stagingRoot.listFiles() ?: return
        for (entry in entries) {
            if (!entry.name.startsWith(STAGING_PREFIX)) continue
            if (now - entry.lastModified() > maxAgeMillis) {
                deleteTree(entry)
            }
        }
    }

    /**
     * Top-level names owned by installed distributions. `complete` is false when some
     * distribution has neither RECORD nor top_level.txt (or one could not be read), in
     * which case ownership cannot be judged and nothing is treated as a leftover.
     */
    fun ownedTopLevels(siteDir: File): LinuxLikeOwnedTopLevels {
        val owned = HashSet<String>()
        var complete = true
        val entries = siteDir.list() ?: return LinuxLikeOwnedTopLevels(owned, false)
        for (entry in entries) {
            if (!isMetaDir(entry)) continue
            val meta = File(siteDir, entry)
            var found = false
            val record = File(meta, "RECORD")
            if (record.isFile) {
                found = true
                try {
                    record.forEachLine(Charsets.UTF_8) { line ->
                        val path = firstCsvField(line)
                        if (path.isNotEmpty() && !path.startsWith("..") && !path.startsWith("/")) {
                            owned.add(path.substringBefore('/'))
                        }
                    }
                } catch (_: IOException) {
                    complete = false
                }
            }
            val topLevel = File(meta, "top_level.txt")
            if (topLevel.isFile) {
                found = true
                try {
                    topLevel.forEachLine(Charsets.UTF_8) { line ->
                        val name = line.trim()
                        if (name.isNotEmpty()) owned.add(name)
                    }
                } catch (_: IOException) {
                    complete = false
                }
            }
            if (!found) complete = false
        }
        return LinuxLikeOwnedTopLevels(owned, complete)
    }

    /**
     * Merges [staging] into [siteDir] atomically (all or nothing). On any error everything
     * done so far is undone and the exception is re-thrown. [mover] exists for tests.
     */
    fun merge(
        staging: File,
        siteDir: File,
        upgrade: Boolean = false,
        mover: ((File, File) -> Unit)? = null
    ): LinuxLikeMergeResult {
        val move = mover ?: ::moveEntry
        siteDir.mkdirs()
        val (owned, complete) = ownedTopLevels(siteDir)
        val existingMeta = siteDir.list().orEmpty().filter(::isMetaDir)
        val tx = Transaction(siteDir.absoluteFile.parentFile ?: siteDir.absoluteFile)
        val installed = ArrayList<String>()
        val replaced = ArrayList<String>()
        val skipped = ArrayList<String>()
        try {
            for (name in staging.list().orEmpty().sorted()) {
                val src = File(staging, name)
                val dst = File(siteDir, name)
                val meta = isMetaDir(name)
                if (!lexists(dst)) {
                    if (meta && !upgrade && existingMeta.any { projectOf(it) == projectOf(name) }) {
                        // Files of this project are kept (no upgrade), so keep its metadata too.
                        skipped.add(name)
                        continue
                    }
                    move(src, dst)
                    tx.created(dst)
                    installed.add(name)
                    continue
                }
                val shared = name in sharedDirs
                val leftover = complete && !meta && !shared && name !in owned
                if ((upgrade && !shared) || leftover) {
                    tx.moveAside(dst)
                    move(src, dst)
                    tx.created(dst)
                    replaced.add(name)
                } else if (meta) {
                    skipped.add(name)
                } else if (Files.isDirectory(src.toPath()) && isRealDir(dst)) {
                    mergeDirs(src, dst, tx, move)
                    installed.add(name)
                } else {
                    skipped.add(name)
                }
            }
            if (upgrade) {
                // Drop older dist-info of the same project so versions don't pile up.
                val fresh = (installed + replaced)
                    .filter(::isMetaDir)
                    .associateBy { projectOf(it) }
                for (old in existingMeta) {
                    val newer = fresh[projectOf(old)] ?: continue
                    if (old != newer && lexists(File(siteDir, old))) {
                        tx.moveAside(File(siteDir, old))
                    }
                }
            }
        } catch (error: Throwable) {
            tx.rollback()
            throw error
        }
        tx.finish()
        return LinuxLikeMergeResult(installed, replaced, skipped)
    }

    internal fun projectOf(metaName: String): String =
        metaName.substringBeforeLast('.')
            .substringBefore('-')
            .replace('-', '_')
            .replace('.', '_')
            .lowercase(Locale.ROOT)

    internal fun isMetaDir(name: String): Boolean =
        name.endsWith(".dist-info") || name.endsWith(".egg-info")

    /** First field of a RECORD (CSV) line: handles quoted paths containing commas. */
    internal fun firstCsvField(line: String): String {
        if (!line.startsWith("\"")) {
            return line.substringBefore(',').trim()
        }
        val field = StringBuilder()
        var index = 1
        while (index < line.length) {
            val ch = line[index]
            if (ch == '"') {
                if (index + 1 < line.length && line[index + 1] == '"') {
                    field.append('"')
                    index += 2
                    continue
                }
                break
            }
            field.append(ch)
            index++
        }
        return field.toString()
    }

    private fun lexists(file: File): Boolean =
        Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)

    private fun isRealDir(file: File): Boolean =
        Files.isDirectory(file.toPath(), LinkOption.NOFOLLOW_LINKS)

    private fun moveEntry(src: File, dst: File) {
        try {
            Files.move(src.toPath(), dst.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(src.toPath(), dst.toPath())
        }
    }

    /** Copies the files of [src] into the existing [dst]; never overwrites an existing file. */
    private fun mergeDirs(src: File, dst: File, tx: Transaction, move: (File, File) -> Unit) {
        for (name in src.list().orEmpty().sorted()) {
            val s = File(src, name)
            val d = File(dst, name)
            if (Files.isDirectory(s.toPath()) && !Files.isSymbolicLink(s.toPath())) {
                if (isRealDir(d)) {
                    mergeDirs(s, d, tx, move)
                } else if (!lexists(d)) {
                    move(s, d)
                    tx.created(d)
                }
            } else if (!lexists(d)) {
                move(s, d)
                tx.created(d)
            }
        }
    }

    /** Best effort, never follows symbolic links. */
    internal fun deleteTree(file: File) {
        val path = file.toPath()
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return
        try {
            Files.walkFileTree(path, object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    Files.deleteIfExists(file)
                    return FileVisitResult.CONTINUE
                }

                override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult {
                    Files.deleteIfExists(dir)
                    return FileVisitResult.CONTINUE
                }
            })
        } catch (_: IOException) {
        }
    }

    /** Undo journal for the merge. */
    private class Transaction(parent: File) {
        private class Undo(val path: File, val backup: File?)

        private val backupRoot: File =
            Files.createTempDirectory(parent.toPath(), BACKUP_PREFIX).toFile()
        private val undo = ArrayList<Undo>()
        private var backupCount = 0

        fun created(path: File) {
            undo.add(Undo(path, null))
        }

        fun moveAside(path: File) {
            backupCount++
            val backup = File(backupRoot, "${backupCount}_${path.name}")
            moveEntry(path, backup)
            undo.add(Undo(path, backup))
        }

        fun rollback() {
            for (entry in undo.asReversed()) {
                try {
                    deleteTree(entry.path)
                    if (entry.backup != null) {
                        moveEntry(entry.backup, entry.path)
                    }
                } catch (_: IOException) {
                }
            }
            finish()
        }

        fun finish() {
            deleteTree(backupRoot)
        }
    }
}
