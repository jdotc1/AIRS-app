"""First saved-summary dispatcher boundaries; no target images are opened."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from airs.cli import main

ROOT = Path(__file__).resolve().parents[1]


class SavedReportSummaryCLITests(unittest.TestCase):
    def setUp(self):
        base = os.environ.get('AIRS_TEST_OUTPUT_ROOT')
        if base:
            Path(base).mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source = self.directory / 'saved.json'
        self.original = (ROOT / 'examples/mixed.audit.json').read_bytes()
        self.source.write_bytes(self.original)

    def test_summary_dispatch_preserves_saved_identity_without_analysis(self):
        output = io.StringIO()
        with patch('airs.cli.audit_path') as audit, contextlib.redirect_stdout(output):
            self.assertEqual(main(['summary', '--report', str(self.source)]), 0)
        audit.assert_not_called()
        result = json.loads(output.getvalue())
        original = json.loads(self.original)
        self.assertEqual(result['report_kind'], 'airs.report_summary')
        self.assertEqual(result['source_report']['image'], original['image'])
        self.assertEqual(result['source_report']['generator'], original['generator'])
        self.assertEqual(result['summary'], original['summary'])
        self.assertNotIn('verdict', result)
        self.assertNotIn('status', result)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_summary_refuses_malformed_report_before_creating_output(self):
        self.source.write_bytes(b'not JSON')
        target = self.directory / 'not-created.json'
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            self.assertEqual(main(['summary', '--report', str(self.source), '--output', str(target)]), 2)
        self.assertEqual(json.loads(error.getvalue())['error']['code'], 'unreadable_report')
        self.assertFalse(target.exists())

    def test_summary_file_output_protects_source_and_uses_existing_writer(self):
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            self.assertEqual(main(['summary', '--report', str(self.source), '--output', str(self.source)]), 2)
        self.assertEqual(json.loads(error.getvalue())['error']['code'], 'input_overwrite')
        self.assertEqual(self.source.read_bytes(), self.original)
        target = self.directory / 'summary.json'
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(['summary', '--report', str(self.source), '--output', str(target)]), 0)
        self.assertEqual(json.loads(output.getvalue())['report_kind'], 'airs.report_summary')
        self.assertEqual(json.loads(target.read_text())['source_report']['report_kind'], 'airs.audit')
