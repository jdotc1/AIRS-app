"""Tiny synthetic presentation checks; no report analysis or file I/O."""
from copy import deepcopy
import unittest

from airs.coverage_text import render_coverage_text
from airs.types import InputError


def inventory():
    return {
        "status": "conflicting_reports",
        "summary": {"input_report_count": 3, "duplicate_report_count": 1,
                    "unique_image_model_config_count": 1, "conflicting_report_count": 2,
                    "function_count": 7, "agreement_count": 2,
                    "inconsistency_count": 1, "unresolved_count": 4},
        "models": {"model-z": 2}, "conflicting_report_indices": [0, 2],
        "reports": [{"index": 0, "model": "model-z", "duplicate_of": None},
                    {"index": 1, "model": "model-z", "duplicate_of": 0},
                    {"index": 2, "model": "model-z", "duplicate_of": None}],
        "reasons": [{"reason": "unsupported", "count": 4,
                     "examples": [{"function_name": "owned", "report_index": 0}]}],
        "limitations": ["Supplied evidence only."],
    }


class CoverageTextTests(unittest.TestCase):
    def test_full_denominators_conflicts_models_and_duplicates_are_visible(self):
        value = inventory()
        before = deepcopy(value)
        text = render_coverage_text(value)
        for key, count in value["summary"].items():
            self.assertIn('"' + key + '": ' + str(count), text)
        self.assertIn('Models (nonduplicate report counts): {"model-z": 2}', text)
        self.assertIn('Conflicting report indices: [0, 2]', text)
        self.assertIn('"duplicate_of": 0', text)
        self.assertEqual(text.count('\nReport: '), 3)
        self.assertIn('not real-world prevalence', text)
        self.assertIn('Reason counts may overlap', text)
        self.assertEqual(value, before)
        self.assertTrue(text.endswith('\n'))

    def test_saved_keys_values_and_names_are_ascii_json_escaped(self):
        value = inventory()
        unsafe = '\x1b[31m\n\r\t\x00\u202eé\x7f'
        value["models"] = {unsafe: 2}
        value["reports"][0]["image"] = {unsafe: unsafe}
        value["reasons"][0]["examples"][0]["function_name"] = unsafe
        value["limitations"] = [unsafe]
        text = render_coverage_text(value)
        self.assertTrue(text.isascii())
        for raw in ('\x1b', '\r', '\t', '\x00', '\u202e', 'é', '\x7f'):
            self.assertNotIn(raw, text)
        self.assertIn('\\u001b[31m\\n\\r\\t\\u0000\\u202e\\u00e9\\u007f', text)

    def test_selection_context_and_detail_omissions_do_not_change_counts(self):
        value = inventory()
        value["reason_selection"] = {"requested": ["missing", "unsupported"],
                                     "matched": ["unsupported"], "unmatched": ["missing"]}
        value["reasons"] = [{"reason": "reason_%02d" % i, "count": 10,
                             "examples": [{"function_name": "example_%d" % n} for n in range(8)]}
                            for i in range(34)]
        before = deepcopy(value)
        text = render_coverage_text(value)
        self.assertIn('"matched": ["unsupported"]', text)
        self.assertIn('"unmatched": ["missing"]', text)
        self.assertIn('does not filter denominators', text)
        self.assertIn('"function_count": 7', text)
        self.assertIn('Reason rows available: 34', text)
        self.assertIn('Reason rows omitted: 2', text)
        self.assertEqual(text.count('\nReason: '), 32)
        self.assertEqual(text.count('\n  Example: '), 96)
        self.assertIn('Examples omitted (including inventory sampling): 7', text)
        self.assertEqual(value, before)
        reordered = deepcopy(value)
        reordered["reasons"].reverse()
        reordered["reports"].reverse()
        self.assertEqual(render_coverage_text(reordered), text)

    def test_invalid_limits_refuse_and_oversized_limits_keep_global_cap(self):
        value = inventory()
        for maximum in (True, False, -1, 1.5, float("nan"), float("inf"), "8", None):
            with self.subTest(maximum=maximum), self.assertRaises(InputError) as caught:
                render_coverage_text(value, maximum_bytes=maximum)
            self.assertEqual(caught.exception.code, "invalid_report_size_limit")
        # Shrink the global cap locally to exercise clamping with a tiny fixture.
        from unittest.mock import patch
        with patch("airs.coverage_text.MAX_REPORT_BYTES", 8):
            with self.assertRaises(InputError) as caught:
                render_coverage_text(value, maximum_bytes=1000)
            self.assertEqual(caught.exception.code, "generated_report_size_limit")

    def test_byte_limit_fails_without_returning_partial_output(self):
        value = inventory()
        complete = render_coverage_text(value)
        size = len(complete.encode('utf-8'))
        self.assertEqual(render_coverage_text(value, maximum_bytes=size), complete)
        for maximum in (0, 8, size - 1):
            with self.subTest(maximum=maximum), self.assertRaises(InputError) as caught:
                render_coverage_text(value, maximum_bytes=maximum)
            self.assertEqual(caught.exception.code, 'generated_report_size_limit')
