"""Presentation-only nullable evidence cases from small report dictionaries."""
from __future__ import annotations

from copy import deepcopy
import unittest

from airs.report import render_html


def report_with_evidence(evidence: dict) -> dict:
    return {
        "schema_version": 1,
        "report_kind": "airs.audit",
        "generator": {"name": "AIRS", "version": "1", "analysis_model_version": "arm64-linear-v1"},
        "image": {"display_name": "synthetic", "architecture": "arm64", "file_type": "execute",
                  "container_sha256": "0" * 64, "slice_sha256": "0" * 64,
                  "cpu_subtype": 0, "slice_offset": 0, "slice_size": 4,
                  "preferred_base": "0x1000"},
        "findings": [{
            "id": "airsf-" + "0" * 64,
            "function": {"name": "synthetic", "boundary_source": "lc_function_starts",
                         "address": "0x1000", "end_address": "0x1004",
                         "image_offset": "0x0", "size": 4},
            "verdict": "unresolved", "coverage": "none", "mode": "none",
            "scope": "metadata_only", "checked_pcs": [], "instruction_count": 0,
            "reason_codes": [], "limitations": [],
            "evidence": [{"code": "comparison", "message": "Synthetic evidence", **evidence}],
        }],
        "metadata_ranges": [], "issues": [], "limitations": [],
        "summary": {"function_count": 1, "agreement_count": 0, "inconsistency_count": 0,
                    "unresolved_count": 1, "metadata_entry_count": 0, "checked_pc_count": 0},
    }


class HTMLBoundaryRegressionTests(unittest.TestCase):
    def test_null_expected_matches_absent_expected_and_escapes_observed(self):
        report = report_with_evidence({"expected": None, "observed": '<value a="b">&'})
        html = render_html(report)
        self.assertIn("<th>Expected</th><td><code>unknown</code>", html)
        self.assertIn("&lt;value a=&quot;b&quot;&gt;&amp;", html)
        self.assertNotIn('<value a="b">', html)
        del report["findings"][0]["evidence"][0]["expected"]
        self.assertEqual(html, render_html(report))

    def test_null_observed_matches_absent_observed(self):
        report = report_with_evidence({"expected": "entry_sp", "observed": None})
        html = render_html(report)
        self.assertIn("<th>Observed</th><td><code>unknown</code>", html)
        del report["findings"][0]["evidence"][0]["observed"]
        self.assertEqual(html, render_html(report))

    def test_empty_known_value_is_preserved_without_mutating_report(self):
        report = report_with_evidence({"expected": "", "observed": None})
        original = deepcopy(report)
        html = render_html(report)
        self.assertIn("<th>Expected</th><td><code></code>", html)
        self.assertIn("<th>Observed</th><td><code>unknown</code>", html)
        self.assertEqual(report, original)


if __name__ == "__main__":
    unittest.main()
