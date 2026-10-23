"""Composed saved-report text dispatch and selection boundaries."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from airs.cli import main

class SavedTextCLITests(unittest.TestCase):
    def setUp(self):
        base=os.environ.get('AIRS_TEST_OUTPUT_ROOT')
        if base: Path(base).mkdir(parents=True,exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=base);self.addCleanup(self.temp.cleanup)
        self.source=Path(self.temp.name)/'saved.json'
        self.original=(Path(__file__).resolve().parents[1]/'examples/mixed.audit.json').read_bytes()
        self.source.write_bytes(self.original)

    def test_summary_text_selection_preserves_source_counts_and_discloses_omissions(self):
        original=json.loads(self.original);out=io.StringIO()
        with patch('airs.cli.audit_path') as audit,contextlib.redirect_stdout(out):
            self.assertEqual(main(['summary','--report',str(self.source),'--format','text','--verdict','agreement']),0)
        audit.assert_not_called();text=out.getvalue()
        self.assertIn('selected rows',text);self.assertIn('"original_count":',text)
        self.assertIn('"omitted_count":',text);self.assertIn('"requested": ["agreement"]',text)
        self.assertEqual(self.source.read_bytes(),self.original)
        out=io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(main(['summary','--report',str(self.source),'--verdict','agreement']),0)
        selected=json.loads(out.getvalue());self.assertEqual(selected['summary'],original['summary'])
        self.assertTrue(all(row['verdict']=='agreement' for row in selected['findings']))

    def test_invalid_summary_selection_refuses_before_report_io(self):
        error=io.StringIO()
        with patch('airs.cli.load_report') as load,contextlib.redirect_stderr(error):
            self.assertEqual(main(['summary','--report','missing.json','--verdict','bogus']),2)
        load.assert_not_called();self.assertEqual(json.loads(error.getvalue())['error']['code'],'invalid_summary_verdict')

    def test_text_formats_dispatch_and_protect_saved_inputs(self):
        for args in [['diff','--baseline',str(self.source),'--current',str(self.source)],['coverage','--report',str(self.source)],['summary','--report',str(self.source)]]:
            with self.subTest(command=args[0]):
                out=io.StringIO()
                with patch('airs.cli.audit_path') as audit,contextlib.redirect_stdout(out):
                    self.assertEqual(main(args+['--format','text']),0)
                audit.assert_not_called();self.assertTrue(out.getvalue().isascii())
                error=io.StringIO()
                with contextlib.redirect_stderr(error):
                    self.assertEqual(main(args+['--format','text','--output',str(self.source)]),2)
                self.assertEqual(json.loads(error.getvalue())['error']['code'],'input_overwrite')
                self.assertEqual(self.source.read_bytes(),self.original)

    def test_summary_reason_selection_composes_and_validates_before_io(self):
        output=io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(['summary','--report',str(self.source),'--reason','definitely_absent_reason','--verdict','unresolved']),0)
        selected=json.loads(output.getvalue())
        self.assertEqual(selected['findings'],[])
        self.assertEqual(selected['summary'],json.loads(self.original)['summary'])
        self.assertEqual(selected['finding_selection']['requested_reasons'],['definitely_absent_reason'])
        error=io.StringIO()
        with patch('airs.cli.load_report') as load,contextlib.redirect_stderr(error):
            self.assertEqual(main(['summary','--report','missing.json','--reason','INVALID']),2)
        load.assert_not_called()

    def test_summary_zero_detail_limit_keeps_full_counts(self):
        output=io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(['summary','--report',str(self.source),'--limit','0']),0)
        result=json.loads(output.getvalue())
        self.assertEqual(result['findings'],[])
        self.assertEqual(result['summary'],json.loads(self.original)['summary'])
        self.assertEqual(result['finding_limit']['returned_count'],0)

    def test_summary_verdict_order_precedes_limit_without_changing_source_counts(self):
        original=json.loads(self.original)
        source_output=io.StringIO()
        with contextlib.redirect_stdout(source_output):
            self.assertEqual(main(['summary','--report',str(self.source),'--limit','1']),0)
        self.assertEqual(json.loads(source_output.getvalue())['findings'][0]['verdict'],'agreement')
        output=io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(['summary','--report',str(self.source),'--sort','verdict','--limit','1']),0)
        result=json.loads(output.getvalue())
        first_inconsistency=next(row for row in original['findings'] if row['verdict']=='inconsistency')
        self.assertEqual(result['findings'][0]['id'],first_inconsistency['id'])
        self.assertEqual(result['finding_order'],'verdict')
        self.assertEqual(result['summary'],original['summary'])
        self.assertEqual(result['finding_limit']['selected_count'],len(original['findings']))
        self.assertEqual(result['finding_limit']['returned_count'],1)
        self.assertEqual(self.source.read_bytes(),self.original)
