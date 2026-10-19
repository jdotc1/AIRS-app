from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "fixtures"))
from generate import generate  # noqa: E402


class CLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temporary.name)
        generate(cls.directory)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_cli(self, *arguments):
        return subprocess.run([sys.executable, "-I", str(ROOT / "airs_cli.py"), *map(str, arguments)], capture_output=True, text=True, timeout=15)

    def test_isolated_bootstrap_works_outside_repository(self):
        result = self.run_cli("audit", "--", self.directory / "before.macho")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["summary"]["agreement_count"], 3)

    def test_report_success_and_explicit_ci_policy_have_distinct_exit_codes(self):
        ordinary = self.run_cli("audit", self.directory / "after.macho")
        gated = self.run_cli("audit", "--fail-on-inconsistency", "--", self.directory / "after.macho")
        self.assertEqual(ordinary.returncode, 0, ordinary.stderr)
        self.assertEqual(gated.returncode, 1, gated.stderr)
        self.assertEqual(json.loads(gated.stdout)["summary"]["inconsistency_count"], 2)

    def test_file_output_and_paths_with_spaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "Example with spaces.macho"
            path.write_bytes((self.directory / "before.macho").read_bytes())
            output = Path(temporary) / "Output report.json"
            result = self.run_cli("audit", "--output", output, "--", path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["report_kind"], "airs.audit")
            self.assertEqual(json.loads(output.read_text())["image"]["display_name"], path.name)

    def test_invalid_input_is_structured_error_without_report(self):
        with tempfile.NamedTemporaryFile(suffix=".macho") as source:
            source.write(b"This is not Mach-O")
            source.flush()
            result = self.run_cli("audit", source.name)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("code", json.loads(result.stderr)["error"])

    def test_report_cannot_replace_binary(self):
        path = self.directory / "before.macho"
        before = path.read_bytes()
        result = self.run_cli("audit", "--output", path, "--", path)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr)["error"]["code"], "input_overwrite")
        self.assertEqual(path.read_bytes(), before)

    def test_diff_and_handoff_commands_use_saved_reports(self):
        with tempfile.TemporaryDirectory() as temporary:
            reports = []
            for name in ("before", "after"):
                path = Path(temporary) / f"{name}.json"
                result = self.run_cli("audit", "--output", path, "--", self.directory / f"{name}.macho")
                self.assertEqual(result.returncode, 0, result.stderr)
                reports.append(path)
            diff = self.run_cli("diff", "--baseline", reports[0], "--current", reports[1])
            self.assertEqual(diff.returncode, 0, diff.stderr)
            self.assertEqual(json.loads(diff.stdout)["summary"]["changed_count"], 2)
            fid = json.loads(reports[1].read_text())["findings"][0]["id"]
            handoff = self.run_cli("handoff", "--report", reports[1], "--finding-id", fid)
            self.assertEqual(handoff.returncode, 0, handoff.stderr)
            self.assertEqual(json.loads(handoff.stdout)["report_kind"], "airs.macscope_handoff")


if __name__ == "__main__":
    unittest.main()
