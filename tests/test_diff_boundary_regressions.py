"""Saved-report comparison boundaries; no binary analysis is performed."""
from copy import deepcopy
import json
from pathlib import Path
import unittest

from airs.diff import compare_reports

ROOT = Path(__file__).resolve().parents[1]


class DiffBoundaryRegressionTests(unittest.TestCase):
    def report(self, name="before"):
        return json.loads((ROOT / "examples" / f"{name}.audit.json").read_text())

    def test_different_budget_identity_makes_exact_matches_ambiguous(self):
        before = self.report()
        after = deepcopy(before)
        after["analysis_config"]["limits"]["max_total_instructions"] += 1
        result = compare_reports(before, after)
        self.assertTrue(result["comparison"]["model_compatible"])
        self.assertTrue(result["comparison"]["analysis_configuration_changed"])
        self.assertEqual(result["summary"]["matched_count"], len(before["findings"]))
        self.assertEqual(result["summary"]["ambiguous_count"], len(before["findings"]))
        self.assertEqual(result["summary"]["unchanged_count"], 0)
        self.assertTrue(all(row["match_basis"] == "exact_image_offset" for row in result["changes"]))
        self.assertTrue(all(any("configuration" in note for note in row["notes"]) for row in result["changes"]))

    def test_one_missing_configuration_qualifies_symbol_candidates_but_equal_legacy_stays_compatible(self):
        before, after = self.report(), self.report("after")
        del after["analysis_config"]
        result = compare_reports(before, after)
        self.assertEqual(result["summary"]["ambiguous_count"], 3)
        self.assertEqual(result["summary"]["changed_count"], 0)
        self.assertTrue(all(row["match_basis"] == "unique_symbol" for row in result["changes"]))
        self.assertTrue(all(any("review candidate" in note for note in row["notes"]) for row in result["changes"]))
        del before["analysis_config"]
        legacy = compare_reports(before, after)
        self.assertFalse(legacy["comparison"]["analysis_configuration_changed"])
        self.assertEqual(legacy["summary"]["changed_count"], 2)
        self.assertEqual(legacy["summary"]["unchanged_count"], 1)

    def test_configuration_difference_does_not_join_unmatched_functions(self):
        before, after = self.report(), self.report("after")
        after["analysis_config"]["limits"]["max_total_instructions"] += 1
        for report in (before, after):
            for finding in report["findings"]:
                finding["function"]["name"] = "sub_" + finding["function"]["address"]
        result = compare_reports(before, after)
        self.assertEqual(result["summary"]["matched_count"], 0)
        self.assertEqual(result["summary"]["ambiguous_count"], 0)
        self.assertEqual(result["summary"]["added_count"], 3)
        self.assertEqual(result["summary"]["removed_count"], 3)
        self.assertTrue(all(row["match_basis"] == "unmatched" for row in result["changes"]))
