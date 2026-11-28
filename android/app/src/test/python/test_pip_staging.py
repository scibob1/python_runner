"""Host-side tests for pip_staging (run: python -m unittest in this directory)."""
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "main", "python"))

import pip_staging as ps  # noqa: E402


def write(root, rel, text="x"):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)


def snapshot(root):
    out = {}
    for base, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(base, name)
            with open(path) as handle:
                out[os.path.relpath(path, root)] = handle.read()
    return out


def dist(root, project, version, files):
    """Create an installed distribution with a RECORD listing ``files``."""
    meta = "%s-%s.dist-info" % (project, version)
    for rel in files:
        write(root, rel, project + "-" + version)
    record = "".join("%s,,\n" % rel for rel in files)
    write(root, meta + "/RECORD", record)
    write(root, meta + "/METADATA", "Name: %s\nVersion: %s\n" % (project, version))


class StagingTestBase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.site = os.path.join(self.root, "site")
        self.staging = os.path.join(self.root, "stage")
        os.makedirs(self.site)
        os.makedirs(self.staging)

    def backups(self):
        return [e for e in os.listdir(self.root) if e.startswith(ps.BACKUP_PREFIX)]


class MergeTest(StagingTestBase):
    def test_new_package_is_moved_in(self):
        dist(self.staging, "foo", "1.0", ["foo/__init__.py", "foo/core.py"])
        result = ps.merge_staging(self.staging, self.site)
        self.assertIn("foo", result["installed"])
        self.assertEqual(snapshot(self.site)["foo/core.py"], "foo-1.0")
        self.assertTrue(os.path.isdir(os.path.join(self.site, "foo-1.0.dist-info")))
        self.assertEqual(self.backups(), [])

    def test_leftover_of_failed_install_is_replaced(self):
        # an earlier failed install left foo/ behind without any dist-info
        write(self.site, "foo/__init__.py", "broken")
        dist(self.site, "other", "2.0", ["other/__init__.py"])
        dist(self.staging, "foo", "1.0", ["foo/__init__.py"])
        result = ps.merge_staging(self.staging, self.site)
        self.assertIn("foo", result["replaced"])
        self.assertEqual(snapshot(self.site)["foo/__init__.py"], "foo-1.0")
        self.assertEqual(snapshot(self.site)["other/__init__.py"], "other-2.0")
        self.assertEqual(self.backups(), [])

    def test_no_leftover_judgement_when_ownership_unknown(self):
        write(self.site, "foo/__init__.py", "keep")
        os.makedirs(os.path.join(self.site, "weird-1.0.dist-info"))  # no RECORD, no top_level
        dist(self.staging, "foo", "1.0", ["foo/__init__.py"])
        ps.merge_staging(self.staging, self.site)
        self.assertEqual(snapshot(self.site)["foo/__init__.py"], "keep")

    def test_owned_package_is_not_overwritten_without_upgrade(self):
        dist(self.site, "foo", "1.0", ["foo/__init__.py"])
        dist(self.staging, "foo", "2.0", ["foo/__init__.py"])
        result = ps.merge_staging(self.staging, self.site)
        self.assertEqual(snapshot(self.site)["foo/__init__.py"], "foo-1.0")
        self.assertNotIn("foo", result["replaced"])
        # metadata must keep matching the files that stayed
        self.assertTrue(os.path.isdir(os.path.join(self.site, "foo-1.0.dist-info")))
        self.assertFalse(os.path.exists(os.path.join(self.site, "foo-2.0.dist-info")))

    def test_namespace_dirs_are_merged_without_overwrite(self):
        dist(self.site, "google_a", "1.0", ["google/a/__init__.py"])
        dist(self.staging, "google_b", "1.0", ["google/b/__init__.py", "google/a/__init__.py"])
        ps.merge_staging(self.staging, self.site)
        snap = snapshot(self.site)
        self.assertEqual(snap["google/a/__init__.py"], "google_a-1.0")
        self.assertEqual(snap["google/b/__init__.py"], "google_b-1.0")

    def test_upgrade_replaces_package_and_drops_old_dist_info(self):
        dist(self.site, "foo", "1.0", ["foo/__init__.py", "foo/old.py"])
        dist(self.staging, "foo", "2.0", ["foo/__init__.py"])
        ps.merge_staging(self.staging, self.site, upgrade=True)
        snap = snapshot(self.site)
        self.assertEqual(snap["foo/__init__.py"], "foo-2.0")
        self.assertNotIn("foo/old.py", snap)
        self.assertFalse(os.path.exists(os.path.join(self.site, "foo-1.0.dist-info")))
        self.assertTrue(os.path.isdir(os.path.join(self.site, "foo-2.0.dist-info")))
        self.assertEqual(self.backups(), [])

    def test_shared_bin_dir_is_merged_not_replaced(self):
        write(self.site, "bin/tool_a", "a")
        write(self.staging, "bin/tool_b", "b")
        dist(self.staging, "foo", "1.0", ["foo/__init__.py"])
        ps.merge_staging(self.staging, self.site, upgrade=True)
        snap = snapshot(self.site)
        self.assertEqual(snap["bin/tool_a"], "a")
        self.assertEqual(snap["bin/tool_b"], "b")


class RollbackTest(StagingTestBase):
    def test_failure_mid_merge_restores_the_site_dir(self):
        dist(self.site, "foo", "1.0", ["foo/__init__.py"])
        write(self.site, "leftover/__init__.py", "broken")
        before = snapshot(self.site)
        dist(self.staging, "foo", "2.0", ["foo/__init__.py"])
        dist(self.staging, "leftover", "1.0", ["leftover/__init__.py"])
        dist(self.staging, "zzz", "1.0", ["zzz/__init__.py"])

        real_move = ps._move
        calls = {"n": 0}

        def flaky(src, dst):
            calls["n"] += 1
            if calls["n"] == 4:
                raise OSError("disk full")
            return real_move(src, dst)

        with mock.patch.object(ps, "_move", flaky):
            with self.assertRaises(OSError):
                ps.merge_staging(self.staging, self.site, upgrade=True)
        self.assertEqual(snapshot(self.site), before)
        self.assertEqual(self.backups(), [])

    def test_staging_dir_is_removed_even_on_error(self):
        with self.assertRaises(RuntimeError):
            with ps.staging_dir(self.site) as path:
                write(path, "a/b.txt")
                kept = path
                raise RuntimeError("pip failed")
        self.assertFalse(os.path.exists(kept))
        self.assertEqual(os.listdir(self.root).count("site"), 1)

    def test_stale_staging_dirs_are_swept(self):
        stale = os.path.join(self.root, ps.STAGING_PREFIX + "old")
        os.makedirs(stale)
        old = os.path.getmtime(stale) - 3600
        os.utime(stale, (old, old))
        fresh = os.path.join(self.root, ps.STAGING_PREFIX + "new")
        os.makedirs(fresh)
        ps.sweep_stale_staging(self.root)
        self.assertFalse(os.path.exists(stale))
        self.assertTrue(os.path.exists(fresh))


if __name__ == "__main__":
    unittest.main()
