"""Synthetic presentation-limit boundaries without report analysis."""
from copy import deepcopy
import unittest

from airs.report_summary_limit import limit_summary_findings, validate_summary_limit
from airs.types import InputError


class ReportSummaryLimitTests(unittest.TestCase):
    def summary(self):
        return {
            "summary": {"function_count": 9, "agreement_count": 4, "unresolved_count": 5},
            "finding_selection": {"selected_count": 3, "verdicts": ["unresolved"]},
            "findings": [{"id": "third", "notes": ["original"]}, {"id": "first"}, {"id": "second"}],
        }

    def test_validation_and_default_return_detached_unchanged_summary(self):
        for value in [None, 0, 1, 200000]:
            validate_summary_limit(value)
        for value in [True, False, -1, 200001, 1.0, "1", [], {}]:
            with self.subTest(value=value), self.assertRaises(InputError) as error:
                validate_summary_limit(value)
            self.assertEqual(error.exception.code, "invalid_summary_limit")
        original = self.summary()
        result = limit_summary_findings(original, None)
        self.assertEqual(result, original)
        self.assertIsNot(result, original)
        result["findings"][0]["notes"].append("changed")
        result["finding_selection"]["verdicts"].append("agreement")
        result["summary"]["function_count"] = 0
        self.assertEqual(original, self.summary())

    def test_truncation_zero_and_counts_preserve_full_summary_selection_and_order(self):
        original = self.summary()
        saved = deepcopy(original)
        for maximum in [0, 2, 3, 200000]:
            with self.subTest(maximum=maximum):
                result = limit_summary_findings(original, maximum)
                returned = min(maximum, 3)
                self.assertEqual(result["findings"], original["findings"][:returned])
                self.assertEqual(result["finding_limit"], {
                    "maximum": maximum, "returned_count": returned,
                    "omitted_count": 3 - returned, "selected_count": 3,
                })
                self.assertEqual(result["summary"], original["summary"])
                self.assertEqual(result["finding_selection"], original["finding_selection"])
                self.assertIsNot(result["summary"], original["summary"])
                self.assertIsNot(result["finding_selection"], original["finding_selection"])
        self.assertEqual(original, saved)
