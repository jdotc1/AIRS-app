"""Changed X-memory report integration with typed parser substitutes only."""
from dataclasses import replace
from pathlib import Path
import json
import os
import tempfile
import struct
import unittest
from unittest.mock import patch
from airs.engine import audit_path
from airs.report import dumps, load_report
from airs.types import InputError, Limits, UnwindTable
from test_rbit_x_candidate import fixture, BASE
from test_report_v32_admission_candidate import synthetic_report
from test_x_stack_slots import O0_CLZ, O0_CTZ, O0_UDIV

MODEL='arm64-bounded-x-stack-v35'
OUTPUT=Path(os.environ.get('AIRS_TEST_OUTPUT_ROOT') or tempfile.mkdtemp(prefix="airs-integration-"))


def report_for(words,limits=Limits(),second=False):
    image,function,entry=fixture(words,0x02001000)
    image=replace(image,container_sha256='1'*64,slice_sha256='2'*64,
                  functions=(replace(function,name='owned_x_stack'),))
    entries=(entry,)
    if second:
        next_function=replace(function,start=function.end,end=function.end+len(image.data),name='owned_second_x_stack')
        data=image.data+image.data
        image=replace(image,data=data,slice_size=len(data),functions=(*image.functions,next_function),
                      sections=(replace(image.sections[0],size=len(data)),))
        entries=(entry,replace(entry,start=next_function.start,end=next_function.end))
    with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
        path=Path(directory)/'synthetic-x-stack.bin';path.write_bytes(image.data)
        with patch('airs.engine.parse_macho',return_value=image),patch('airs.engine.parse_compact_unwind',return_value=UnwindTable(entries)):
            return audit_path(path,limits=limits)


class XStackV35IntegrationTests(unittest.TestCase):
    def test_three_complete_retained_bodies_emit_v35_and_round_trip(self):
        for name,words in (('clz',O0_CLZ),('ctz',O0_CTZ),('udiv',O0_UDIV)):
            report=report_for(words)
            self.assertEqual(report['generator']['analysis_model_version'],MODEL)
            finding=report['findings'][0]
            self.assertEqual((finding['verdict'],finding['scope']),('agreement','modeled_leaf_body'))
            self.assertEqual(finding['checked_pcs'],[hex(BASE+i*4) for i in range(1,len(words)-2)])
            output=OUTPUT/('x-stack-v35-'+name+'.json');output.write_text(dumps(report))
            self.assertEqual(load_report(output),report)

    def test_exact_v35_admission_refusals_and_generic_future_labels(self):
        for model in (MODEL,'arm64-bounded-udiv-v34','arm64-bounded-rbit-v33'):
            for fault in ('subtype','boundary','scope','encoding','dwarf'):
                report=synthetic_report(model);finding=report['findings'][0]
                if fault=='subtype':report['image']['cpu_subtype']=0x80000000
                elif fault=='boundary':finding['function']['boundary_source']='compact_unwind'
                elif fault=='scope':finding['scope']='modeled_leaf_body'
                elif fault=='encoding':finding['encoding']='0x02000100'
                else:finding.update(mode='dwarf',coverage='dwarf_reference',encoding='0x03000004',scope='synchronous_call_sites')
                with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
                    path=Path(directory)/'fault.json';path.write_text(json.dumps(report))
                    with self.subTest(model=model,fault=fault),self.assertRaises(InputError):load_report(path)
        future=synthetic_report(MODEL+'-future');future['image']['cpu_subtype']=0x80000000
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            path=Path(directory)/'future.json';path.write_text(json.dumps(future))
            self.assertEqual(load_report(path),future)

    def test_total_instruction_and_cfg_budgets_include_new_memory_work(self):
        for limits in (replace(Limits(),max_total_cfg_steps=7),replace(Limits(),max_total_instructions=7)):
            report=report_for(O0_CLZ,limits,second=True)
            self.assertEqual(report['summary']['function_count'],2)
            self.assertEqual([f['verdict'] for f in report['findings']],['agreement','unresolved'])
            self.assertEqual(report['findings'][1]['checked_pcs'],[])
