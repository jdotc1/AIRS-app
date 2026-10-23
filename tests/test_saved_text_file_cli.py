"""Saved report text file delivery, without re-auditing source images."""
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


class SavedTextFileCLITests(unittest.TestCase):
    def test_text_file_matches_stdout_and_preserves_saved_source(self):
        base = os.environ.get('AIRS_TEST_OUTPUT_ROOT')
        if base:
            Path(base).mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=base) as temporary:
            directory = Path(temporary)
            source = directory / 'saved audit.json'
            original = (ROOT / 'examples/mixed.audit.json').read_bytes()
            source.write_bytes(original)
            cases = (
                ('summary', ['summary', '--report', str(source)], 'airs.report_summary'),
                ('diff', ['diff', '--baseline', str(source), '--current', str(source)], 'airs.diff'),
                ('coverage', ['coverage', '--report', str(source)], 'airs.coverage_inventory'),
            )
            with patch('airs.cli.audit_path') as audit:
                for name, arguments, kind in cases:
                    with self.subTest(command=name):
                        stdout = io.StringIO()
                        error = io.StringIO()
                        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(error):
                            code = main(arguments + ['--format', 'text'])
                        self.assertEqual(code, 0, error.getvalue())
                        self.assertTrue(stdout.getvalue())
                        target = directory / (name + ' output.txt')
                        acknowledgment = io.StringIO()
                        with contextlib.redirect_stdout(acknowledgment), contextlib.redirect_stderr(error):
                            code = main(arguments + ['--format', 'text', '--output', str(target)])
                        self.assertEqual(code, 0, error.getvalue())
                        self.assertEqual(json.loads(acknowledgment.getvalue()),
                                         {'written': str(target), 'report_kind': kind})
                        self.assertEqual(target.read_bytes(), stdout.getvalue().encode('utf-8'))
                        self.assertEqual(source.read_bytes(), original)
                audit.assert_not_called()
