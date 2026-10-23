"""New v36 report/admission boundary, using tiny typed parser substitutes."""
from dataclasses import replace
from pathlib import Path
import json
import os
import tempfile
import unittest
from unittest.mock import patch
from airs import ANALYSIS_MODEL_VERSION
from airs.engine import audit_path
from airs.report import dumps, load_report
from airs.types import InputError, UnwindEntry, UnwindTable
from test_rbit_x_candidate import fixture
from test_fp_x_stack import MODEL, FRAME_WORDS
from test_report_v32_admission_candidate import synthetic_report

OUTPUT=Path(os.environ.get('AIRS_TEST_OUTPUT_ROOT',str(Path(tempfile.gettempdir()) / 'AIRS-FP-X-stack-v36-20261021')))


class FPXStackIntegrationTests(unittest.TestCase):
    def test_emitted_fp_call_report_and_owned_sink_round_trip(self):
        image,function,entry=fixture(FRAME_WORDS,0x04000000,with_callee=True)
        image=replace(image,container_sha256='1'*64,slice_sha256='2'*64,
                      functions=(replace(function,name='owned_fp_x_call'),image.functions[1]))
        sink=image.functions[1]
        table=UnwindTable((entry,UnwindEntry(sink.start,sink.end,0x02000000,0)))
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            path=Path(directory)/'synthetic-fp-x.bin';path.write_bytes(image.data)
            with patch('airs.engine.parse_macho',return_value=image),patch('airs.engine.parse_compact_unwind',return_value=table):
                report=audit_path(path)
        self.assertEqual(report['generator']['analysis_model_version'],ANALYSIS_MODEL_VERSION)
        self.assertEqual((report['summary']['function_count'],report['summary']['agreement_count']),(2,2))
        first=report['findings'][0]
        self.assertEqual((first['verdict'],first['scope'],first['checked_pcs']),('agreement','synchronous_call_sites',['0x1020']))
        output=OUTPUT/'fp-x-stack-v37.json';output.write_text(dumps(report))
        self.assertEqual(load_report(output),report)

    def test_exact_v36_historical_admission_and_unknown_labels(self):
        for model in (MODEL,'arm64-bounded-x-stack-v35','arm64-bounded-udiv-v34'):
            for fault in ('subtype','boundary','scope','encoding','dwarf'):
                report=synthetic_report(model);finding=report['findings'][0]
                if fault=='subtype':report['image']['cpu_subtype']=0x80000000
                elif fault=='boundary':finding['function']['boundary_source']='compact_unwind'
                elif fault=='scope':finding['scope']='modeled_leaf_body'
                elif fault=='encoding':finding['encoding']='0x04000100'
                else:finding.update(mode='dwarf',coverage='dwarf_reference',encoding='0x03000004')
                with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
                    path=Path(directory)/'fault.json';path.write_text(json.dumps(report))
                    with self.subTest(model=model,fault=fault),self.assertRaises(InputError):load_report(path)
        future=synthetic_report(MODEL+'-future');future['image']['cpu_subtype']=0x80000000
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            path=Path(directory)/'future.json';path.write_text(json.dumps(future))
            self.assertEqual(load_report(path),future)
