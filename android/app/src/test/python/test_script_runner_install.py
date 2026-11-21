"""Host-side tests: script_runner.install_package goes through pip_staging (stage + merge)."""
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "main", "python"))

import pip_staging as ps  # noqa: E402
import script_runner as sr  # noqa: E402


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


def make_dist(root, project, version, files):
    for rel in files:
        write(root, rel, "%s-%s" % (project, version))
    meta = "%s-%s.dist-info" % (project, version)
    write(root, meta + "/RECORD", "".join("%s,,\n" % rel for rel in files))
    write(root, meta + "/METADATA", "Name: %s\nVersion: %s\n" % (project, version))


def target_of(args):
    return args[args.index("--target") + 1]


class InstallTestBase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, True)
        patches = [
            mock.patch.dict(os.environ, {}, clear=False),
            mock.patch.object(sr, "_APP_DATA_DIR", os.path.join(self.root, "files")),
            mock.patch.object(sr, "_PIP_PATCHED", True),
            mock.patch.object(sr, "_LAST_PIP_OUTPUT", ""),
            mock.patch.object(sys, "path", list(sys.path)),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.site = sr._ensure_site_packages()
        self.parent = os.path.dirname(self.site)
        self.pip_calls = []

    def fake_pip(self, project="foo", version="1.0", files=None, rc=0, partial_only=False):
        files = files or ["%s/__init__.py" % project, "%s/core.py" % project]

        def run(args):
            self.pip_calls.append(list(args))
            target = target_of(args)
            if partial_only:
                write(target, files[0], "partial")
            else:
                make_dist(target, project, version, files)
            return rc

        return run

    def leftovers(self):
        return [e for e in os.listdir(self.parent)
                if e.startswith((ps.STAGING_PREFIX, ps.BACKUP_PREFIX))]


class UpgradeFlagTest(unittest.TestCase):
    def test_upgrade_flags(self):
        for flags in (["--upgrade"], ["-U"], ["--force-reinstall"], ["-I"],
                      ["--ignore-installed"], ["-Ur"], ["-q", "-U"]):
            self.assertTrue(sr._is_upgrade_request(["install", "foo"] + flags), flags)

    def test_not_upgrade(self):
        for flags in ([], ["--upgrade-strategy", "eager"], ["-q"], ["-r", "requirements.txt"],
                      ["--prefer-binary"]):
            self.assertFalse(sr._is_upgrade_request(["install", "foo"] + flags), flags)


class StagedInstallTest(InstallTestBase):
    def test_pip_targets_staging_not_site_dir(self):
        with mock.patch.object(sr, "_run_pip", self.fake_pip()):
            self.assertEqual(sr.install_package(["install", "foo"]), 0)
        self.assertTrue(self.pip_calls)
        for call in self.pip_calls:
            target = target_of(call)
            self.assertNotEqual(os.path.abspath(target), os.path.abspath(self.site))
            self.assertTrue(os.path.basename(target).startswith(ps.STAGING_PREFIX))

    def test_fresh_install_lands_in_site_dir(self):
        with mock.patch.object(sr, "_run_pip", self.fake_pip()):
            self.assertEqual(sr.install_package(["install", "foo"]), 0)
        snap = snapshot(self.site)
        self.assertEqual(snap["foo/core.py"], "foo-1.0")
        self.assertTrue(os.path.isdir(os.path.join(self.site, "foo-1.0.dist-info")))
        self.assertEqual(self.leftovers(), [])

    def test_failed_pip_leaves_site_dir_clean_and_next_install_works(self):
        with mock.patch.object(sr, "_run_pip", self.fake_pip(rc=1, partial_only=True)):
            self.assertEqual(sr.install_package(["install", "foo"]), 1)
        self.assertEqual(snapshot(self.site), {})
        self.assertEqual(self.leftovers(), [])
        # the original bug: leftovers of the failed install blocked this one
        with mock.patch.object(sr, "_run_pip", self.fake_pip()):
            self.assertEqual(sr.install_package(["install", "foo"]), 0)
        self.assertEqual(snapshot(self.site)["foo/core.py"], "foo-1.0")

    def test_leftover_of_an_earlier_failed_install_is_replaced(self):
        write(self.site, "foo/__init__.py", "broken")  # left by the old --target flow
        with mock.patch.object(sr, "_run_pip", self.fake_pip()):
            self.assertEqual(sr.install_package(["install", "foo"]), 0)
        snap = snapshot(self.site)
        self.assertEqual(snap["foo/__init__.py"], "foo-1.0")
        self.assertEqual(snap["foo/core.py"], "foo-1.0")

    def test_installed_package_kept_without_upgrade(self):
        make_dist(self.site, "foo", "1.0", ["foo/__init__.py"])
        with mock.patch.object(sr, "_run_pip", self.fake_pip(version="2.0", files=["foo/__init__.py"])):
            self.assertEqual(sr.install_package(["install", "foo"]), 0)
        self.assertEqual(snapshot(self.site)["foo/__init__.py"], "foo-1.0")
        self.assertTrue(os.path.isdir(os.path.join(self.site, "foo-1.0.dist-info")))

    def test_upgrade_flags_replace_installed_package(self):
        for flag in ("--upgrade", "-U", "--force-reinstall", "-I"):
            shutil.rmtree(self.site)
            os.makedirs(self.site)
            make_dist(self.site, "foo", "1.0", ["foo/__init__.py", "foo/old.py"])
            with mock.patch.object(sr, "_run_pip", self.fake_pip(version="2.0", files=["foo/__init__.py"])):
                self.assertEqual(sr.install_package(["install", "foo", flag]), 0, flag)
            snap = snapshot(self.site)
            self.assertEqual(snap["foo/__init__.py"], "foo-2.0", flag)
            self.assertNotIn("foo/old.py", snap, flag)
            self.assertFalse(os.path.exists(os.path.join(self.site, "foo-1.0.dist-info")), flag)
            self.assertTrue(os.path.isdir(os.path.join(self.site, "foo-2.0.dist-info")), flag)

    def test_merge_failure_rolls_back_and_reports(self):
        make_dist(self.site, "foo", "1.0", ["foo/__init__.py"])
        before = snapshot(self.site)
        real_move = ps._move
        calls = {"n": 0}

        def flaky(src, dst):
            calls["n"] += 1
            if calls["n"] == 2:
                raise OSError("disk full")
            return real_move(src, dst)

        run = self.fake_pip(version="2.0", files=["foo/__init__.py", "bar/__init__.py"])
        with mock.patch.object(sr, "_run_pip", run), mock.patch.object(ps, "_move", flaky):
            self.assertEqual(sr.install_package(["install", "foo", "--upgrade"]), 1)
        self.assertEqual(snapshot(self.site), before)
        self.assertEqual(self.leftovers(), [])
        self.assertIn("已回滚", sr.last_pip_error())


class NativeProviderTest(InstallTestBase):
    LIB = "chaquopy/lib/libc++_shared.so"

    def provider_pip(self, rc=0):
        return self.fake_pip(project="chaquopy_libcxx", version="1.0", files=[self.LIB], rc=rc)

    def test_provider_is_merged_into_shared_chaquopy_dir(self):
        write(self.site, "chaquopy/lib/libother.so", "other")
        with mock.patch.object(sr, "_run_pip", self.provider_pip()):
            self.assertTrue(sr._install_native_provider("chaquopy-libcxx", self.site))
        snap = snapshot(self.site)
        self.assertEqual(snap[self.LIB], "chaquopy_libcxx-1.0")
        self.assertEqual(snap["chaquopy/lib/libother.so"], "other")
        self.assertEqual(self.leftovers(), [])

    def test_provider_pip_failure_changes_nothing(self):
        write(self.site, "chaquopy/lib/libother.so", "other")
        before = snapshot(self.site)
        with mock.patch.object(sr, "_run_pip", self.provider_pip(rc=1)):
            self.assertFalse(sr._install_native_provider("chaquopy-libcxx", self.site))
        self.assertEqual(snapshot(self.site), before)
        self.assertEqual(self.leftovers(), [])

    def test_provider_merge_failure_rolls_back(self):
        write(self.site, "chaquopy/lib/libother.so", "other")
        before = snapshot(self.site)
        with mock.patch.object(sr, "_run_pip", self.provider_pip()), \
                mock.patch.object(ps, "_move", side_effect=OSError("disk full")):
            self.assertFalse(sr._install_native_provider("chaquopy-libcxx", self.site))
        self.assertEqual(snapshot(self.site), before)
        self.assertEqual(self.leftovers(), [])

    def test_provider_run_keeps_last_pip_output(self):
        sr._LAST_PIP_OUTPUT = "keep me"
        with mock.patch.object(sr, "_run_pip", self.provider_pip()):
            sr._install_native_provider("chaquopy-libcxx", self.site)
        self.assertEqual(sr._LAST_PIP_OUTPUT, "keep me")


if __name__ == "__main__":
    unittest.main()
