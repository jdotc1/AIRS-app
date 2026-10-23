"""Reason selection preserves the full saved-report inventory context."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from airs.cli import main
from airs.coverage import coverage_inventory, validate_reason_selection
from airs.report import dumps
from airs.types import InputError

ROOT = Path(__file__).resolve().parents[1]


class CoverageReasonSelectionTests(unittest.TestCase):
    def saved_report(self):
        return json.loads((ROOT / 'examples/mixed.audit.json').read_text())

    def test_selection_preserves_counts_dedup_conflicts_and_example_budget(self):
        report = self.saved_report()
        unresolved = next(row for row in report['findings'] if row['verdict'] == 'unresolved')
        reason = unresolved['reason_codes'][0]
        conflict = copy.deepcopy(report)
        conflict['findings'] = [copy.deepcopy(unresolved) for _ in range(10)]
        for index, finding in enumerate(conflict['findings']):
            finding['id'] = f'example-{index}'
            finding['reason_codes'] = [reason, reason]
        inputs = [report, copy.deepcopy(report), conflict]
        full = coverage_inventory(inputs)
        selected = coverage_inventory(inputs, reason_codes=[reason, reason])
        for key in full:
            if key != 'reasons':
                self.assertEqual(selected[key], full[key], key)
        self.assertEqual(selected['reasons'], [row for row in full['reasons'] if row['reason'] == reason])
        self.assertEqual(len(selected['reasons'][0]['examples']), 8)
        self.assertEqual(selected['summary']['duplicate_report_count'], 1)
        self.assertEqual(selected['status'], 'conflicting_reports')
        self.assertEqual(selected['reason_selection'], {'requested': [reason], 'matched': [reason], 'unmatched': []})

    def test_default_cli_serialization_and_absent_metadata_are_unchanged(self):
        report = self.saved_report()
        full = coverage_inventory([report])
        self.assertNotIn('reason_selection', full)
        self.assertEqual(dumps(full), dumps(coverage_inventory([report], reason_codes=None)))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = main(['coverage', '--report', str(ROOT / 'examples/mixed.audit.json')])
        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue(), dumps(full))

    def test_invalid_selection_rejected_before_report_io(self):
        invalid = ['', 'Upper', 'a-b', 'a.b', 'é', 'a\n', 'a' * 129]
        for codes in [[code] for code in invalid] + [['valid'] * 33]:
            arguments = ['coverage', '--report', '/missing/report.json']
            for code in codes:
                arguments.extend(['--reason', code])
            with self.subTest(codes=codes), patch('airs.cli.Path.stat') as stat, patch('airs.cli.load_report') as load:
                error = io.StringIO()
                with contextlib.redirect_stderr(error):
                    self.assertEqual(main(arguments), 2)
                stat.assert_not_called()
                load.assert_not_called()
                expected = 'reason_selection_limit' if len(codes) > 32 else 'invalid_reason_code'
                self.assertEqual(json.loads(error.getvalue())['error']['code'], expected)
        self.assertEqual(validate_reason_selection(['z', 'a' * 128, 'z']), ['a' * 128, 'z'])
        with self.assertRaises(InputError):
            coverage_inventory([], reason_codes=['Bad'])

    def test_unknown_codes_preserve_context_and_input_overwrite_protection(self):
        report = self.saved_report()
        full = coverage_inventory([report])
        selected = coverage_inventory([report], reason_codes=['zz_unknown_reason', 'aa_unknown_reason'])
        self.assertEqual(selected['reasons'], [])
        self.assertEqual(selected['summary'], full['summary'])
        self.assertEqual(selected['reason_selection'], {
            'requested': ['aa_unknown_reason', 'zz_unknown_reason'], 'matched': [],
            'unmatched': ['aa_unknown_reason', 'zz_unknown_reason'],
        })
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'saved.json'
            original = (ROOT / 'examples/mixed.audit.json').read_bytes()
            source.write_bytes(original)
            error = io.StringIO()
            with contextlib.redirect_stderr(error):
                result = main(['coverage', '--report', str(source), '--reason', 'zz_unknown_reason', '--output', str(source)])
            self.assertEqual(result, 2)
            self.assertEqual(json.loads(error.getvalue())['error']['code'], 'input_overwrite')
            self.assertEqual(source.read_bytes(), original)
