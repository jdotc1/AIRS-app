"""Small synthetic comparison text regressions; no binary analysis."""
import unittest

from airs.diff_text import render_diff_text
from airs.types import InputError


class DiffTextTests(unittest.TestCase):
    def comparison(self):
        return {
            "comparison": {"model_compatible": True, "analysis_configuration_changed": True,
                           "same_image": False, "matching_policy": "exact_digest_then_unique_symbol"},
            "summary": {"matched_count": 2, "changed_count": 0, "unchanged_count": 0,
                        "ambiguous_count": 2, "added_count": 1, "removed_count": 1},
            "changes": [{"key": "symbol:_name", "function_name": "_name", "match_basis": "unique_symbol",
                         "change": "ambiguous", "notes": ["Review candidate only", "Configuration differs"]},
                        {"key": "unmatched:after:id", "change": "added", "match_basis": "unmatched", "notes": []}],
            "limitations": ["Cross-build candidates do not prove source identity", "Configuration differs"],
        }

    def test_full_counts_ambiguity_configuration_and_unmatched_status_are_preserved(self):
        text = render_diff_text(self.comparison())
        for item in ['"matched_count": 2', '"ambiguous_count": 2', '"added_count": 1',
                     '"removed_count": 1', '"model_compatible": true', '"analysis_configuration_changed": true',
                     '"change": "ambiguous"', '"change": "added"', '"match_basis": "unique_symbol"',
                     '"match_basis": "unmatched"', '"note": "Configuration differs"']:
            self.assertIn(item, text)
        self.assertIn("do not establish a regression or a fix", text)
        self.assertEqual(text, render_diff_text(self.comparison()))

    def test_every_saved_string_and_key_is_ascii_json_escaped(self):
        report = self.comparison()
        hostile = "\x1b[31m\n\r\t\x00\u202eCafé"
        report["comparison"][hostile] = {hostile: hostile}
        report["changes"][0]["function_name"] = hostile
        report["changes"][0]["notes"] = [hostile]
        report["limitations"] = [hostile]
        text = render_diff_text(report)
        self.assertTrue(text.isascii())
        self.assertNotIn("\x1b", text)
        self.assertNotIn("\x00", text)
        self.assertIn(r"\u001b[31m\n\r\t\u0000\u202eCaf\u00e9", text)
        self.assertTrue(all(character == "\n" or 32 <= ord(character) <= 126 for character in text))

    def test_clipping_reports_exact_omissions_without_clipping_full_counts(self):
        text = render_diff_text(self.comparison(), maximum_changes=1, maximum_notes=1, maximum_limitations=1)
        self.assertIn('"matched_count": 2', text)
        self.assertIn("Omitted change rows: 1", text)
        self.assertIn("Omitted notes: 1", text)
        self.assertIn("Omitted limitations: 1", text)
        self.assertNotIn('"change": "added"', text)

    def test_byte_cap_fails_before_return_and_accepts_exact_ascii_size(self):
        report = self.comparison()
        length = len(render_diff_text(report).encode("ascii"))
        self.assertEqual(len(render_diff_text(report, maximum_bytes=length)), length)
        for limit in [0, 8, length - 1]:
            with self.subTest(limit=limit), self.assertRaises(InputError) as error:
                render_diff_text(report, maximum_bytes=limit)
            self.assertEqual(error.exception.code, "generated_report_size_limit")
