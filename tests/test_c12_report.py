"""Real final-image v3 pipeline and bounded shared work accounting."""
from dataclasses import replace
from pathlib import Path
import json
import struct
import tempfile
import unittest

from airs.engine import audit_path
from airs.report import validate_report
from airs.types import InputError, Limits
from parser_helpers import build_macho, regular_unwind
from test_cfg import O0,O2


class CFGReportTests(unittest.TestCase):
    def report(self,limits=Limits(),subtype=0):
        text=struct.pack('<'+str(len(O2)*2)+'I',*O2,*O2)
        unwind=regular_unwind(((0x1000,0x02000000),),0x1000+len(text))
        data=build_macho(text,function_offsets=(0,len(O2)*4),unwind_info=unwind,cpusubtype=subtype)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'owned';path.write_bytes(data)
            return audit_path(path,limits=limits)

    def test_real_pipeline_emits_v3_and_keeps_two_independent_functions(self):
        report=validate_report(self.report())
        self.assertEqual(report['generator']['analysis_model_version'],'arm64-bounded-sequential-loops-v31')
        self.assertEqual(report['summary']['function_count'],2)
        self.assertEqual(report['summary']['agreement_count'],2)
        self.assertTrue(all(any(e['code']=='cfg_paths_checked' for e in f['evidence']) for f in report['findings']))

    def test_global_cfg_budget_cannot_be_reset_for_next_function(self):
        report=validate_report(self.report(replace(Limits(),max_total_cfg_steps=5)))
        self.assertEqual([f['verdict'] for f in report['findings']],['agreement','unresolved'])
        self.assertEqual(report['summary']['function_count'],2)
        self.assertTrue(any(i['code']=='cfg_budget_reached' for i in report['issues']))

    def test_v3_requires_exact_subtype_and_preserves_reference_or_compact_coverage(self):
        report=validate_report(self.report(subtype=0x01000000))
        self.assertEqual([f['verdict'] for f in report['findings']],['unresolved','unresolved'])
        self.assertTrue(all(f['coverage']=='compact' for f in report['findings']))
        report=self.report();report['image']['cpu_subtype']=0x01000000
        with self.assertRaises(InputError):validate_report(report)

    def test_v3_invalid_supported_metadata_relationship_is_rejected(self):
        report=self.report();report['findings'][0].update(scope='synchronous_call_sites')
        with self.assertRaises(InputError):validate_report(report)
