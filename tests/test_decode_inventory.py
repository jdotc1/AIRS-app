"""New decode-only diagnostics; no retained library or semantic workload run."""
import os
from dataclasses import replace
from pathlib import Path
import contextlib
import io
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from airs import ANALYSIS_MODEL_VERSION
from airs.decode_inventory import decode_inventory, decode_inventory_path
from airs.cli import main
from airs.report import validate_report
from airs.types import FunctionRange, InputError, Limits
from parser_helpers import build_macho
from test_rbit_x_candidate import fixture, BASE, RET


OUTPUT = Path(os.environ.get('AIRS_TEST_OUTPUT_ROOT', str(Path(tempfile.gettempdir()) / 'AIRS-decode-inventory-20261021')))
REPO=Path(__file__).resolve().parents[1]


class DecodeInventoryTests(unittest.TestCase):
    def test_collects_later_refusals_and_keeps_admitted_words_separate(self):
        # B skips two refusals at runtime; inventory deliberately makes no path claim.
        image,_,_=fixture((0x14000003,0x1ac10c00,0x93000000,0x9ac10c00,RET))
        report=decode_inventory(image)
        row=report['functions'][0]
        self.assertEqual(report['report_kind'],'airs.decode_inventory')
        self.assertEqual(report['decoder_model'],ANALYSIS_MODEL_VERSION)
        self.assertEqual((row['observed_word_count'],row['decoder_admitted_word_count'],row['decline_count']),(5,3,2))
        self.assertEqual([b['address'] for b in row['blockers']],['0x1004','0x1008'])
        self.assertEqual([b['word'] for b in row['blockers']],['0x1ac10c00','0x93000000'])
        self.assertEqual([b['reason'] for b in row['blockers']],['unsupported_instruction','invalid_bitfield_encoding'])
        self.assertTrue(row['word_scan_complete']);self.assertTrue(row['blockers_complete'])
        self.assertNotIn('verdict',row);self.assertNotIn('checked_pcs',row)
        with self.assertRaises(InputError):validate_report(report)

    def test_function_and_total_word_caps_preserve_every_function(self):
        image,first,_=fixture((0x1ac10c00,RET,0x1ac10c00,RET))
        first=replace(first,end=BASE+8)
        second=replace(first,start=BASE+8,end=BASE+16,name='second')
        image=replace(image,functions=(first,second))
        report=decode_inventory(image,replace(Limits(),max_instructions_per_function=1,max_total_instructions=1))
        self.assertEqual(report['summary']['function_count'],2)
        self.assertEqual([r['observed_word_count'] for r in report['functions']],[1,0])
        self.assertTrue(all(not r['word_scan_complete'] for r in report['functions']))
        self.assertEqual(report['status'],'partial')

    def test_evidence_caps_retain_exact_observed_decline_counts(self):
        image,_,_=fixture((0x1ac10c00,0x93000000,RET))
        for cap in (0,1):
            result=decode_inventory(image,replace(Limits(),max_evidence_per_function=cap,max_total_evidence=cap))
            row=result['functions'][0]
            self.assertEqual(row['decline_count'],2);self.assertEqual(len(row['blockers']),cap)
            self.assertTrue(row['word_scan_complete']);self.assertFalse(row['blockers_complete'])
            self.assertEqual(row['omitted_decline_count'],2-cap);self.assertEqual(result['status'],'partial')

    def test_untrusted_bounds_bad_extents_and_unmapped_bytes_remain_visible(self):
        image,fn,_=fixture((RET,))
        cases=((replace(fn,boundary_source='symbol'), 'excluded_boundary'),
               (replace(fn,end=fn.end-1),'invalid_extent'),
               (replace(fn,start=BASE+100,end=BASE+104),'unmapped_bytes'))
        for function,status in cases:
            result=decode_inventory(replace(image,functions=(function,)))
            self.assertEqual(result['summary']['function_count'],1)
            self.assertEqual(result['functions'][0]['scan_status'],status)
            self.assertFalse(result['functions'][0]['word_scan_complete'])
            self.assertEqual(result['status'],'partial')

    def test_nonordinary_architecture_and_over_function_cap_never_look_complete(self):
        image,fn,_=fixture((RET,))
        for changed in (replace(image,architecture='arm64e'),replace(image,cpu_subtype=0x80000000)):
            result=decode_inventory(changed)
            self.assertEqual(result['functions'][0]['scan_status'],'excluded_architecture')
        with self.assertRaises(InputError):decode_inventory(image,replace(Limits(),max_functions=0))
        empty=decode_inventory(replace(image,functions=()))
        self.assertEqual(empty['status'],'no_functions')

    def test_new_macho_cli_json_and_source_overwrite_protection(self):
        data=build_macho(struct.pack('<III',0x1ac10c00,0x93000000,RET))
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            source=Path(directory)/'owned.macho';source.write_bytes(data)
            dest=Path(directory)/'inventory.json'
            self.assertEqual(main(['decode-blockers',str(source),'--output',str(dest)]),0)
            result=json.loads(dest.read_text())
            self.assertEqual((result['summary']['function_count'],result['summary']['decline_count']),(1,2))
            self.assertEqual(result['image']['slice_size'],len(data))
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(['decode-blockers',str(source),'--output',str(source)]),2)
            self.assertEqual(source.read_bytes(),data)

    def test_file_budget_and_unreadable_input_decline(self):
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            source=Path(directory)/'owned.bin';source.write_bytes(b'12345')
            with self.assertRaises(InputError) as error:decode_inventory_path(source,limits=replace(Limits(),max_file_bytes=4))
            self.assertEqual(error.exception.code,'file_size_limit')
            with self.assertRaises(InputError):decode_inventory_path(Path(directory)/'missing')


class DecodeInventoryBootstrapTests(unittest.TestCase):
    def test_isolated_bootstrap_emits_decode_only_identity_bound_json(self):
        data=build_macho(struct.pack('<III',0xd503201f,0x1ac10c00,0xd65f03c0))
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            source=Path(directory)/'owned.macho';source.write_bytes(data)
            output=Path(directory)/'blockers.json'
            run=subprocess.run([sys.executable,'-I','-B',str(REPO/'airs_cli.py'),'decode-blockers',str(source),'--output',str(output)],capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,0,run.stderr)
            report=json.loads(output.read_text())
            self.assertEqual(report['report_kind'],'airs.decode_inventory')
            self.assertEqual((report['status'],report['summary']['decline_count']),('complete',1))
            self.assertEqual(report['decoder_model'],ANALYSIS_MODEL_VERSION)
            self.assertEqual(len(report['image']['slice_sha256']),64)
            self.assertNotIn('verdict',report['functions'][0])

    def test_cli_partial_inventory_returns_one_without_dropping_function(self):
        # Just over the diagnostic's default per-function word cap. Fixed NOPs
        # exercise budget reporting; this is not a real-binary corpus or sweep.
        data=build_macho(struct.pack('<I',0xd503201f)*4097+struct.pack('<I',0xd65f03c0))
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            source=Path(directory)/'owned.macho';source.write_bytes(data)
            output=Path(directory)/'partial.json'
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(['decode-blockers',str(source),'--output',str(output)]),1)
            report=json.loads(output.read_text())
            self.assertEqual((report['status'],report['summary']['function_count']),('partial',1))
            self.assertEqual(report['summary']['observed_word_count'],4096)
            self.assertFalse(report['functions'][0]['word_scan_complete'])
