"""Synthetic detail selection without report I/O or artifact verification."""
from copy import deepcopy
import unittest

from airs.report_summary_selection import select_summary_findings, validate_summary_verdicts, validate_summary_reasons
from airs.types import InputError


def summary():
    return {
        "report_kind": "airs.report_summary", "schema_version": 1,
        "source_report": {"image": {"slice_offset": 4096, "slice_sha256": "1" * 64},
                          "generator": {"analysis_model_version": "synthetic-model"},
                          "analysis_config": {"limits": {"max_total_instructions": 3}}},
        "summary": {"function_count": 3, "agreement_count": 1, "unresolved_count": 1,
                    "inconsistency_count": 1},
        "finding_counts": {"by_verdict": {"agreement": 1, "inconsistency": 1, "unresolved": 1}},
        "reason_counts_by_verdict": {"unresolved": {"unknown": 1}},
        "findings": [{"id": str(i), "verdict": v, "checked_pcs": ["0x1000"]}
                     for i, v in enumerate(("agreement", "inconsistency", "unresolved"))],
        "limitations": ["No whole-binary pass"],
    }


class ReportSummarySelectionTests(unittest.TestCase):
    def test_invalid_requests_and_deterministic_duplicate_removal(self):
        for invalid in ([], "agreement", ["pass"], [None], ["AGREEMENT"], [1]):
            with self.subTest(invalid=invalid), self.assertRaises(InputError) as error:
                validate_summary_verdicts(invalid)
            self.assertEqual(error.exception.code, "invalid_summary_verdict")
        self.assertEqual(validate_summary_verdicts(["unresolved", "agreement", "unresolved"]),
                         ("agreement", "unresolved"))

    def test_selection_preserves_full_unresolved_denominator_and_context(self):
        original = summary()
        selected = select_summary_findings(original, ["agreement"])
        self.assertEqual([f["verdict"] for f in selected["findings"]], ["agreement"])
        self.assertEqual(selected["finding_selection"], {"requested": ["agreement"],
                         "selected_count": 1, "omitted_count": 2, "original_count": 3})
        for key in ("source_report", "summary", "finding_counts", "reason_counts_by_verdict", "limitations"):
            self.assertEqual(selected[key], original[key])
        self.assertEqual(selected["summary"]["unresolved_count"], 1)
        self.assertNotIn("verdict", selected)

    def test_default_shape_and_selection_are_detached_without_mutation(self):
        original = summary()
        snapshot = deepcopy(original)
        default = select_summary_findings(original)
        self.assertEqual(default, original)
        self.assertNotIn("finding_selection", default)
        selected = select_summary_findings(original, ["unresolved"])
        selected["findings"][0]["checked_pcs"].clear()
        selected["source_report"]["analysis_config"]["limits"].clear()
        default["findings"].clear()
        self.assertEqual(original, snapshot)


class ReportSummaryReasonSelectionTests(unittest.TestCase):
    def test_literal_reason_selection_composes_with_verdict_and_keeps_counts(self):
        original = summary()
        for finding in original["findings"]:
            finding["reason_codes"] = ["shared"] if finding["verdict"] != "inconsistency" else ["other"]
        selected = select_summary_findings(original, ["unresolved"], reason_codes=["shared", "shared"])
        self.assertEqual([f["verdict"] for f in selected["findings"]], ["unresolved"])
        self.assertEqual(selected["finding_selection"]["requested_reasons"], ["shared"])
        self.assertEqual(selected["finding_selection"]["omitted_count"], 2)
        self.assertEqual(selected["summary"], original["summary"])
        reasons_only = select_summary_findings(original, reason_codes=["shared"])
        self.assertEqual(reasons_only["finding_selection"]["requested"], [])
        self.assertEqual(reasons_only["finding_selection"]["selected_count"], 2)
        self.assertNotIn("finding_selection", original)

    def test_reason_validation_uses_shared_literal_identifier_limits(self):
        for codes in (["Upper"], ["a.*"], ["a" * 129], ["é"], "shared", [1]):
            with self.subTest(codes=codes), self.assertRaises(InputError):
                validate_summary_reasons(codes)
        with self.assertRaises(InputError) as error:
            validate_summary_reasons(["valid"] * 33)
        self.assertEqual(error.exception.code, "reason_selection_limit")
        self.assertEqual(validate_summary_reasons(["z", "a", "z"]), ["a", "z"])
        self.assertIsNone(validate_summary_reasons(None))
