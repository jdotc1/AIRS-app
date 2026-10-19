import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_dsym import dsym_bytes
from airs.bridge import make_handoff
from airs.diff import compare_reports
from airs.report import validate_report
from airs.types import InputError

ROOT=Path(__file__).resolve().parents[1]

class SourceCLITests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.report=json.loads((ROOT/'examples/before.audit.json').read_text())
        self.report['future_field']={'keep':[True,'owned value']}
        self.source=self.directory/'input.json';self.source.write_text(json.dumps(self.report))
        self.dsym=self.directory/"Owned symbols; 'quotes'.dSYM"
        self.dsym.write_bytes(dsym_bytes(ident=self.report['image']['uuid']))

    def cli(self,*args):
        return subprocess.run([sys.executable,'-I',str(ROOT/'airs_cli.py'),*map(str,args)],capture_output=True,text=True,timeout=10)

    def test_symbols_preserves_all_fields_and_stages_paths_as_arguments(self):
        output=self.directory/'enriched.json'
        result=self.cli('symbols','--report',self.source,'--dsym',self.dsym,'--output',output)
        self.assertEqual(result.returncode,0,result.stderr)
        report=json.loads(output.read_text());validate_report(report)
        annotations=report.pop('source_annotations')
        self.assertEqual(report,self.report)
        self.assertEqual(annotations['status'],'matched')
        self.assertEqual(annotations['functions'][0]['locations'][0]['line'],7)
        report['source_annotations']=annotations
        comparison=compare_reports(self.report,report)
        self.assertEqual(comparison['summary']['changed_count'],0)
        handoff=make_handoff(report,report['findings'][0]['id'])
        self.assertEqual(handoff['finding']['verdict'],self.report['findings'][0]['verdict'])
        self.assertEqual(handoff['image']['slice_sha256'],self.report['image']['slice_sha256'])

    def test_output_cannot_replace_selected_debug_artifact_or_input_report(self):
        for target in (self.dsym,self.source):
            original=target.read_bytes()
            result=self.cli('symbols','--report',self.source,'--dsym',self.dsym,'--output',target)
            self.assertEqual(result.returncode,2,result.stderr)
            self.assertEqual(target.read_bytes(),original)

    def test_inventory_uses_saved_reports_and_records_duplicate_inputs(self):
        result=self.cli('coverage','--report',self.source,'--report',self.source)
        self.assertEqual(result.returncode,0,result.stderr)
        inventory=json.loads(result.stdout)
        self.assertEqual(inventory['summary']['duplicate_report_count'],1)
        self.assertEqual(inventory['summary']['function_count'],3)

    def test_malformed_annotation_types_are_input_errors(self):
        from airs.dsym import attach_dsym
        report=attach_dsym(self.report,self.dsym)
        for mutate in ('status','identity','location','candidate_count'):
            changed=copy.deepcopy(report);a=changed['source_annotations']
            if mutate=='status':a['status']={}
            if mutate=='identity':a['image_identity']['cpu_subtype']=False
            if mutate=='location':a['functions'][0]['locations'][0]['source_status']=[]
            if mutate=='candidate_count':a['functions'][0]['candidate_count']=True
            with self.subTest(mutate=mutate),self.assertRaises(InputError):validate_report(changed)
