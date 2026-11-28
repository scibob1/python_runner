"""Host-side tests: pip resolver conflicts are reported like "no native package" (Debian hint)."""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "main", "python"))

import script_runner as sr  # noqa: E402

CONFLICT = """\
INFO: pip is looking at multiple versions of optiland to determine which version is compatible
ERROR: Cannot install optiland and numpy==1.26.2 because these package versions have conflicting dependencies.

The conflict is caused by:
    The user requested numpy==1.26.2
    optiland 0.5.0 depends on numpy>=2.0

To fix this you could try to:
1. loosen the range of package versions you've specified
2. remove package versions to allow pip attempt to solve the dependency conflict

ERROR: ResolutionImpossible: for help visit https://pip.pypa.io/en/latest/topics/dependency-resolution/
"""
NO_MATCH = ("ERROR: Could not find a version that satisfies the requirement scipy>=1.12\n"
            "ERROR: No matching distribution found for scipy>=1.12\n")
NETWORK = "ERROR: Could not connect: Temporary failure in name resolution\n"
BUILD = "  Preparing metadata (pyproject.toml) ... error\nERROR: Failed to build 'numpy'\n"


class FallbackBase(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(sr, "_LAST_PIP_OUTPUT", "")
        patch.start()
        self.addCleanup(patch.stop)
        self.calls = []

    def run_install(self, outputs):
        def fake(args):
            rc, text = outputs[len(self.calls)]
            self.calls.append(list(args))
            sr._LAST_PIP_OUTPUT = text
            return rc

        with mock.patch.object(sr, "_run_pip", fake):
            return sr._run_install_with_fallback(["install", "optiland"])


class ConflictBlockTest(unittest.TestCase):
    def test_extracts_only_the_conflict_lines(self):
        block = sr._conflict_block(CONFLICT)
        self.assertEqual(block.split("\n"), [
            "The conflict is caused by:",
            "The user requested numpy==1.26.2",
            "optiland 0.5.0 depends on numpy>=2.0",
        ])

    def test_no_conflict_gives_empty(self):
        self.assertEqual(sr._conflict_block(NO_MATCH), "")

    def test_long_conflict_is_capped(self):
        lines = "".join("    pkg%d 1.0 depends on dep%d>=9\n" % (i, i) for i in range(40))
        block = sr._conflict_block("The conflict is caused by:\n" + lines)
        self.assertEqual(len(block.split("\n")), 9)


class ConflictFallbackTest(FallbackBase):
    def test_conflict_is_retried_then_reported_as_no_native_package(self):
        rc = self.run_install([(1, CONFLICT), (1, CONFLICT)])
        self.assertEqual(rc, 1)
        self.assertIn("--only-binary=:all:", self.calls[0])
        self.assertNotIn("--only-binary=:all:", self.calls[1])
        self.assertTrue(sr._LAST_PIP_OUTPUT.startswith("该包没有适用于"))

    def test_last_pip_error_keeps_conflict_lines_and_points_to_debian(self):
        self.run_install([(1, CONFLICT), (1, CONFLICT)])
        message = sr.last_pip_error()
        self.assertIn("The conflict is caused by", message)
        self.assertIn("optiland 0.5.0 depends on numpy>=2.0", message)
        self.assertIn("Debian", message)
        self.assertNotIn("Linux-like", message)
        self.assertNotIn("ResolutionImpossible", message)
        self.assertLessEqual(len(message), 1500)

    def test_conflict_only_with_binaries_resolves_on_retry(self):
        self.assertEqual(self.run_install([(1, CONFLICT), (0, "")]), 0)

    def test_conflict_from_first_run_survives_a_later_build_failure(self):
        self.run_install([(1, CONFLICT), (1, BUILD)])
        message = sr.last_pip_error()
        self.assertTrue(message.startswith("该包没有适用于"))
        self.assertIn("optiland 0.5.0 depends on numpy>=2.0", message)
        self.assertIn("Debian", message)


class UnchangedBehaviourTest(FallbackBase):
    def test_other_failures_are_not_retried_and_keep_their_message(self):
        self.assertEqual(self.run_install([(1, NETWORK)]), 1)
        self.assertEqual(len(self.calls), 1)
        self.assertIn("name resolution", sr.last_pip_error())
        self.assertNotIn("Debian", sr.last_pip_error())

    def test_missing_wheel_still_gets_the_hint_with_debian(self):
        self.run_install([(1, NO_MATCH), (1, NO_MATCH)])
        message = sr.last_pip_error()
        self.assertTrue(message.startswith("该包没有适用于"))
        self.assertIn("Debian", message)
        self.assertNotIn("Linux-like", message)

    def test_explicit_binary_flags_bypass_the_fallback(self):
        calls = []

        def fake(args):
            calls.append(list(args))
            sr._LAST_PIP_OUTPUT = CONFLICT
            return 1

        with mock.patch.object(sr, "_run_pip", fake):
            sr._run_install_with_fallback(["install", "x", "--only-binary=:all:"])
        self.assertEqual(len(calls), 1)
        self.assertFalse(sr._LAST_PIP_OUTPUT.startswith("该包没有适用于"))


if __name__ == "__main__":
    unittest.main()
