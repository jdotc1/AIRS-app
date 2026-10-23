"""Focused text rendering cases using synthetic saved-report data only."""
from copy import deepcopy
import unittest
from unittest.mock import patch

from airs.types import InputError
from airs.report_summary import summarize_report
from airs.report_summary_text import render_summary_text
from test_report_summary import saved_report


class ReportSummaryTextTests(unittest.TestCase):
    def test_full_counts_scope_identity_and_omitted_examples(self):
        report = saved_report()
        report['findings'] = report['findings'] * 3
        report['summary'].update(function_count=9, agreement_count=3, inconsistency_count=3, unresolved_count=3)
        summary = summarize_report(report)
        before = deepcopy(summary)
        text = render_summary_text(summary)
        self.assertIn('Function denominator (includes unresolved): 9', text)
        self.assertIn('"agreement": 3, "inconsistency": 3, "unresolved": 3', text)
        self.assertIn('"synchronous_call_sites": 6', text)
        self.assertIn('"metadata_only": 3', text)
        self.assertIn('"future-model"', text)
        self.assertIn('"slice_sha256": "' + '2' * 64 + '"', text)
        self.assertIn('not a whole-binary pass', text)
        self.assertIn('4 finding examples omitted', text)
        self.assertIn('Metadata entries (not additional functions): 1', text)
        self.assertEqual(summary, before)

    def test_untrusted_strings_are_visible_json_escapes(self):
        report = saved_report()
        unsafe = 'name\x1b[31m\r\n\t\x00\u202e"\\'
        report['image']['display_name'] = unsafe
        report['generator']['analysis_model_version'] = unsafe
        report['findings'][0]['function']['name'] = unsafe
        report['findings'][0]['scope'] = unsafe
        report['findings'][0]['reason_codes'] = [unsafe]
        report['limitations'] = [unsafe]
        text = render_summary_text(summarize_report(report))
        self.assertNotIn('\x1b', text)
        self.assertNotIn('\r', text)
        self.assertNotIn('\t', text)
        self.assertNotIn('\x00', text)
        self.assertNotIn('\u202e', text)
        self.assertIn('\\u001b[31m\\r\\n\\t\\u0000\\u202e\\"\\\\', text)
        self.assertTrue(text.isascii())

    def test_deterministic_empty_summary_and_bounded_reason_rows(self):
        report = saved_report()
        report['findings'] = []
        report['summary'].update(function_count=0, agreement_count=0, inconsistency_count=0, unresolved_count=0, checked_pc_count=0)
        report['metadata_ranges'] = []
        report['issues'] = []
        report['limitations'] = []
        summary = summarize_report(report)
        text = render_summary_text(summary)
        self.assertEqual(text, render_summary_text(deepcopy(summary)))
        self.assertTrue(text.endswith('\n'))
        self.assertFalse(text.endswith('\n\n'))
        self.assertIn('Function denominator (includes unresolved): 0', text)
        self.assertIn('Finding examples (first 0 of 0 saved rows):\n  (none)', text)
        self.assertIn('0 finding examples omitted', text)
        self.assertIn('not a whole-binary pass', text)
        summary['reason_counts_by_verdict']['unresolved'] = {f'reason_{i:02}': 1 for i in range(15)}
        clipped = render_summary_text(summary)
        self.assertIn('3 additional rows omitted', clipped)
        self.assertIn('"reason_00": 1', clipped)
        self.assertNotIn('"reason_14": 1', clipped)

    def test_ascii_expansion_and_exact_output_byte_budget(self):
        report = saved_report()
        report['image']['display_name'] = 'é😀\x7f\x1b'
        summary = summarize_report(report)
        expected = render_summary_text(summary)
        self.assertIn('\\u00e9\\ud83d\\ude00\\u007f\\u001b', expected)
        size = len(expected.encode('ascii'))
        self.assertEqual(render_summary_text(summary, maximum_bytes=size), expected)
        with self.assertRaises(InputError) as caught:
            render_summary_text(summary, maximum_bytes=size - 1)
        self.assertEqual(caught.exception.code, 'generated_report_size_limit')
        with self.assertRaises(InputError) as tiny:
            render_summary_text(summary, maximum_bytes=32)
        self.assertEqual(tiny.exception.code, 'generated_report_size_limit')

    def test_selected_examples_show_full_selection_metadata_with_safe_budget(self):
        summary = summarize_report(saved_report())
        summary['findings'] = summary['findings'][:1]
        summary['finding_selection'] = {
            'requested': ['unsafe\x1b[31m'], 'selected_count': 1, 'original_count': 3, 'omitted_count': 2,
        }
        text = render_summary_text(summary)
        self.assertIn('Function denominator (includes unresolved): 3', text)
        self.assertIn('Finding examples (first 1 of 1 selected rows):', text)
        self.assertIn('"selected_count": 1', text)
        self.assertIn('"original_count": 3', text)
        self.assertIn('"omitted_count": 2', text)
        self.assertIn('"requested": ["unsafe\\u001b[31m"]', text)
        self.assertNotIn('\x1b', text)
        self.assertNotIn('1 of 1 saved rows', text)
        with self.assertRaises(InputError) as caught:
            render_summary_text(summary, maximum_bytes=len(text) - 1)
        self.assertEqual(caught.exception.code, 'generated_report_size_limit')

    def test_invalid_byte_limits_and_global_clamp(self):
        summary = summarize_report(saved_report())
        for invalid in (True, False, -1, 1.5, float('nan'), float('inf'), '100', None):
            with self.subTest(invalid=invalid), self.assertRaises(InputError) as caught:
                render_summary_text(summary, maximum_bytes=invalid)
            self.assertEqual(caught.exception.code, 'invalid_report_size_limit')
        with patch('airs.report_summary_text.MAX_REPORT_BYTES', 32):
            with self.assertRaises(InputError) as caught:
                render_summary_text(summary, maximum_bytes=10 ** 9)
            self.assertEqual(caught.exception.code, 'generated_report_size_limit')
        with self.assertRaises(InputError):
            render_summary_text(summary, maximum_bytes=0)

    def test_order_selection_and_limit_metadata_remain_distinct_and_escaped(self):
        summary = summarize_report(saved_report())
        summary['findings'] = summary['findings'][1:2]
        summary['finding_order'] = 'verdict'
        summary['finding_selection'] = {
            'requested': ['inconsistency', 'unresolved'], 'requested_reasons': ['reason\x1b[31m'],
            'selected_count': 2, 'original_count': 3, 'omitted_count': 1,
        }
        summary['finding_limit'] = {
            'maximum': 1, 'returned_count': 1, 'omitted_count': 1, 'selected_count': 2,
        }
        original = deepcopy(summary)
        text = render_summary_text(summary)
        self.assertIn('Finding detail order (as supplied; saved values preserved): "verdict"', text)
        self.assertIn('Finding examples (first 1 of 1 retained rows):', text)
        self.assertIn('Finding selection (full source counts above remain unchanged):', text)
        self.assertIn('Finding detail limit (full source counts above remain unchanged):', text)
        self.assertIn('"original_count": 3', text)
        self.assertIn('"maximum": 1', text)
        self.assertIn('"returned_count": 1', text)
        self.assertIn('"selected_count": 2', text)
        self.assertIn('"requested_reasons": ["reason\\u001b[31m"]', text)
        self.assertIn('Function denominator (includes unresolved): 3', text)
        self.assertIn('"agreement": 1, "inconsistency": 1, "unresolved": 1', text)
        self.assertNotIn('\x1b', text)
        self.assertTrue(text.isascii())
        self.assertEqual(summary, original)
        summary['finding_order'] = 'verdict\x1b[0m'
        self.assertIn('"verdict\\u001b[0m"', render_summary_text(summary))
