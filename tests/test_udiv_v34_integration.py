"""Engine/report boundary for new v34; binary parsers use tiny typed substitutes."""
from dataclasses import replace
import json
from pathlib import Path
import tempfile
from output_paths import output_root
import unittest
from unittest.mock import patch
from airs import ANALYSIS_MODEL_VERSION
from airs.engine import audit_path
from airs.report import dumps, load_report, validate_report
from airs.types import InputError, UnwindTable
from test_rbit_x_candidate import fixture
from test_udiv_x import WITNESS

OUTPUT = output_root()


class UDIVV34IntegrationTests(unittest.TestCase):
    def test_emitted_complete_witness_serializes_and_reopens(self):
        image,function,entry=fixture(WITNESS)
        image=replace(image,container_sha256='1'*64,slice_sha256='2'*64,
                      functions=(replace(function,name='owned_udiv_witness'),))
        # Typed substitute tests composition, not Mach-O parsing or real digests.
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            path=Path(directory)/'synthetic-udiv.bin';path.write_bytes(image.data)
            with patch('airs.engine.parse_macho',return_value=image),patch('airs.engine.parse_compact_unwind',return_value=UnwindTable((entry,))):
                report=audit_path(path)
        self.assertEqual(report['generator']['analysis_model_version'],ANALYSIS_MODEL_VERSION)
        finding=report['findings'][0]
        self.assertEqual((finding['verdict'],finding['scope'],finding['checked_pcs']),('agreement','modeled_leaf_body',['0x1000']))
        output=OUTPUT/'udiv-v37.json';output.write_text(dumps(report))
        self.assertEqual(load_report(output),report)

    def test_v34_serialized_subtype_metadata_and_scope_are_strict(self):
        # Existing typed report structure, independent admission faults.
        from test_report_v32_admission_candidate import synthetic_report
        for fault in ('subtype','boundary','scope','encoding','dwarf'):
            report=synthetic_report('arm64-bounded-udiv-v34');finding=report['findings'][0]
            if fault=='subtype':report['image']['cpu_subtype']=0x80000000
            elif fault=='boundary':finding['function']['boundary_source']='compact_unwind'
            elif fault=='scope':finding['scope']='modeled_leaf_body'
            elif fault=='encoding':finding['encoding']='0x02000100'
            else:
                finding.update(mode='dwarf',coverage='dwarf_reference',encoding='0x03000004',scope='synchronous_call_sites')
            with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
                path=Path(directory)/'fault.json';path.write_text(json.dumps(report))
                with self.subTest(fault=fault), self.assertRaises(InputError):load_report(path)
