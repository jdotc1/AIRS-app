"""Pure synthetic summary ordering; no report or image I/O."""
from copy import deepcopy
import unittest

from airs.report_summary_ordering import order_summary_findings, validate_summary_order
from airs.types import InputError


def summary():
    verdicts = ("agreement", "unresolved", "inconsistency", "agreement", "inconsistency", "unresolved")
    return {
        "report_kind": "airs.report_summary", "schema_version": 1,
        "source_report": {"image": {"slice_offset": 4096}, "generator": {"analysis_model_version": "synthetic"}},
        "summary": {"function_count": 6, "agreement_count": 2, "unresolved_count": 2, "inconsistency_count": 2},
        "finding_counts": {"by_verdict": {"agreement": 2, "unresolved": 2, "inconsistency": 2}},
        "finding_selection": {"original_count": 9, "selected_count": 6, "omitted_count": 3},
        "findings": [{"id": str(i), "verdict": verdict, "checked_pcs": []}
                     for i, verdict in enumerate(verdicts)],
    }


class ReportSummaryOrderingTests(unittest.TestCase):
    def test_source_shape_is_detached_and_invalid_orders_decline(self):
        original = summary()
        snapshot = deepcopy(original)
        result = order_summary_findings(original)
        self.assertEqual(result, original)
        self.assertNotIn("finding_order", result)
        result["findings"][0]["checked_pcs"].append("0x1000")
        result["source_report"]["image"]["slice_offset"] = 0
        self.assertEqual(original, snapshot)
        for value in (None, [], "VERDICT", "name", 1):
            with self.subTest(value=value), self.assertRaises(InputError) as error:
                validate_summary_order(value)
            self.assertEqual(error.exception.code, "invalid_summary_order")

    def test_verdict_order_is_stable_and_preserves_full_context(self):
        original = summary()
        snapshot = deepcopy(original)
        result = order_summary_findings(original, "verdict")
        self.assertEqual([finding["id"] for finding in result["findings"]], ["2", "4", "1", "5", "0", "3"])
        self.assertEqual(result["finding_order"], "verdict")
        for key in ("summary", "finding_counts", "source_report", "finding_selection"):
            self.assertEqual(result[key], original[key])
        result["findings"][0]["checked_pcs"].append("0x2000")
        self.assertEqual(original, snapshot)
