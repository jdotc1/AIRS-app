"""Exercise the public verification command using temporary, owned test suites.

These tests fail if the command omits a receipt, hides a failing test or skip,
accepts an empty suite, leaks arbitrary environment values, or invents a Git
revision for a source directory that is not itself a checkout.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify-python.py"


class VerificationCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="airs-verifier-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "Owned source with spaces"
        (self.root / "tests").mkdir(parents=True)
        self.receipt = self.root / "build" / "verification" / "python.json"

    def suite(self, source):
        (self.root / "tests" / "test_owned.py").write_text(
            textwrap.dedent(source), encoding="utf-8"
        )

    def invoke(self, *arguments, environment=None):
        result = subprocess.run(
            [sys.executable, "-I", "-B", str(SCRIPT), "--root", str(self.root),
             "--receipt", str(self.receipt), *arguments],
            text=True, capture_output=True, timeout=30,
            env=environment,
        )
        return result

    def read_receipt(self):
        self.assertTrue(self.receipt.is_file(), "Every attempted run needs a receipt")
        return json.loads(self.receipt.read_text(encoding="utf-8"))

    def test_success_writes_a_complete_receipt(self):
        self.suite("""
            import unittest
            class OwnedTests(unittest.TestCase):
                def test_ready(self):
                    self.assertEqual(2 + 2, 4)
        """)
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["schema_version"], 1)
        self.assertEqual(receipt["check"], "python-unittest")
        self.assertEqual(receipt["status"], "passed")
        self.assertEqual(receipt["exit_code"], 0)
        self.assertEqual(receipt["counts"]["tests_run"], 1)
        self.assertEqual(receipt["counts"]["failures"], 0)
        self.assertEqual(receipt["counts"]["errors"], 0)
        self.assertEqual(receipt["counts"]["skipped"], 0)
        self.assertIn("started_at", receipt)
        self.assertIn("completed_at", receipt)
        self.assertGreaterEqual(receipt["duration_seconds"], 0)
        self.assertEqual(receipt["environment"]["python_version"],
                         ".".join(map(str, sys.version_info[:3])))
        self.assertIsNone(receipt["source"]["revision"])
        self.assertEqual(receipt["source"]["status"], "not_a_checkout")

    def test_failures_and_import_errors_keep_details_and_nonzero_status(self):
        self.suite("""
            import unittest
            class OwnedTests(unittest.TestCase):
                def test_failure(self):
                    self.fail("owned assertion failed")
        """)
        (self.root / "tests" / "test_import.py").write_text(
            "raise RuntimeError('owned import failed')\n", encoding="utf-8"
        )
        result = self.invoke()
        self.assertEqual(result.returncode, 1, result.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["counts"]["failures"], 1)
        self.assertEqual(receipt["counts"]["errors"], 1)
        self.assertIn("failures", receipt)
        self.assertIn("errors", receipt)
        self.assertIn("test_failure", receipt["failures"][0]["test"])
        self.assertIn("owned assertion failed", receipt["failures"][0]["detail"])
        self.assertIn("owned import failed", receipt["errors"][0]["detail"])

    def test_skips_are_visible_and_strict_mode_rejects_them(self):
        self.suite("""
            import unittest
            class OwnedTests(unittest.TestCase):
                @unittest.skip("owned prerequisite absent")
                def test_optional(self):
                    self.fail("a skipped test must not execute")
        """)
        ordinary = self.invoke()
        self.assertEqual(ordinary.returncode, 0, ordinary.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "passed_with_skips")
        self.assertEqual(receipt["counts"]["skipped"], 1)
        self.assertEqual(receipt["skipped"][0]["reason"], "owned prerequisite absent")
        strict = self.invoke("--fail-on-skip")
        self.assertEqual(strict.returncode, 1, strict.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "failed")
        self.assertTrue(receipt["policy"]["fail_on_skip"])

    def test_empty_discovery_fails_instead_of_producing_a_green_receipt(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "empty")
        self.assertEqual(receipt["counts"]["tests_run"], 0)
        self.assertEqual(receipt["discovery"]["test_cases"], 0)

    def test_discovery_error_replaces_any_old_success_receipt(self):
        (self.root / "tests").rmdir()
        self.receipt.parent.mkdir(parents=True)
        self.receipt.write_text('{"status":"passed"}\n', encoding="utf-8")
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "error")
        self.assertIn("tests", receipt["runner_error"])
        self.assertIn("completed_at", receipt)

    def test_pattern_selects_a_subset_and_is_recorded(self):
        self.suite("""
            import unittest
            class OwnedTests(unittest.TestCase):
                def test_ready(self):
                    self.assertTrue(True)
        """)
        (self.root / "tests" / "test_unselected.py").write_text(
            "raise RuntimeError('must not be discovered')\n", encoding="utf-8"
        )
        result = self.invoke("--pattern", "test_owned.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["discovery"]["pattern"], "test_owned.py")
        self.assertEqual(receipt["discovery"]["test_cases"], 1)

    def test_environment_is_allowlisted_and_never_dumps_secret_values(self):
        self.suite("""
            import unittest
            class OwnedTests(unittest.TestCase):
                def test_ready(self):
                    self.assertTrue(True)
        """)
        environment = dict(os.environ, AIRS_TEST_TOKEN="owned-private-value",
                           GITHUB_RUN_ID="owned-run-123")
        result = self.invoke(environment=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["environment"]["ci"]["GITHUB_RUN_ID"], "owned-run-123")
        self.assertNotIn("owned-private-value", self.receipt.read_text(encoding="utf-8"))

    def test_interrupt_writes_an_incomplete_receipt_and_returns_130(self):
        self.suite("""
            import unittest
            class OwnedTests(unittest.TestCase):
                def test_interrupt(self):
                    raise KeyboardInterrupt
        """)
        result = self.invoke()
        self.assertEqual(result.returncode, 130, result.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "interrupted")
        self.assertEqual(receipt["counts"]["tests_run"], 1)

    def test_expected_failures_and_unexpected_successes_are_recorded(self):
        self.suite("""
            import unittest
            class OwnedTests(unittest.TestCase):
                @unittest.expectedFailure
                def test_known_failure(self):
                    self.fail("owned expected failure")
                @unittest.expectedFailure
                def test_unexpected_success(self):
                    self.assertTrue(True)
        """)
        result = self.invoke()
        self.assertEqual(result.returncode, 1, result.stderr)
        receipt = self.read_receipt()
        self.assertIn("expected_failures", receipt["counts"])
        self.assertIn("unexpected_successes", receipt["counts"])
        self.assertEqual(receipt["counts"]["expected_failures"], 1)
        self.assertEqual(receipt["counts"]["unexpected_successes"], 1)
        self.assertIn("test_unexpected_success", receipt["unexpected_successes"][0])

    @unittest.skipUnless(shutil.which("git"), "Git is required for revision provenance")
    def test_actual_checkout_revision_and_dirty_state_are_recorded(self):
        self.suite("""
            import unittest
            class OwnedTests(unittest.TestCase):
                def test_ready(self):
                    self.assertTrue(True)
        """)
        (self.root / ".gitignore").write_text("build/\n", encoding="utf-8")
        def git(*arguments):
            return subprocess.run(
                ["git", "-C", str(self.root), *arguments], check=True,
                capture_output=True, text=True, timeout=10,
            ).stdout.strip()
        git("init", "-q")
        git("add", ".gitignore", "tests")
        git("-c", "user.name=Owned Test", "-c", "user.email=owned@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-qm", "Owned test fixture")
        revision = git("rev-parse", "HEAD")
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = self.read_receipt()
        self.assertEqual(receipt["source"]["revision"], revision)
        self.assertFalse(receipt["source"]["dirty"])
        (self.root / "tests" / "test_owned.py").write_text(
            (self.root / "tests" / "test_owned.py").read_text(encoding="utf-8") + "\n# edited\n",
            encoding="utf-8",
        )
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.read_receipt()["source"]["dirty"])

        nested = self.root / "extracted-source"
        (nested / "tests").mkdir(parents=True)
        shutil.copy2(self.root / "tests" / "test_owned.py", nested / "tests" / "test_owned.py")
        result = self.invoke("--root", str(nested))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(self.read_receipt()["source"]["revision"])


if __name__ == "__main__":
    unittest.main()
