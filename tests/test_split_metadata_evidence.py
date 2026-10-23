"""New bounded range-refusal diagnostics, using tiny typed inputs only."""
import os
from dataclasses import replace
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
from airs.engine import audit_path
from airs.report import validate_report, dumps, load_report
from airs.types import FunctionRange, Limits, UnwindEntry, UnwindTable
from test_rbit_x_candidate import fixture, RET

OUTPUT = Path(os.environ.get('AIRS_TEST_OUTPUT_ROOT', str(Path(tempfile.gettempdir()) / 'AIRS-mixed-metadata-20261021')))

class SplitMetadataEvidenceTests(unittest.TestCase):
    def report(self, entries, limits=Limits()):
        image,function,_=fixture((0xd503201f,0xd503201f,0xd503201f,RET))
        image=replace(image,container_sha256='1'*64,slice_sha256='2'*64)
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            path=Path(directory)/'typed.bin';path.write_bytes(image.data)
            with patch('airs.engine.parse_macho',return_value=image),patch('airs.engine.parse_compact_unwind',return_value=UnwindTable(entries)):
                return audit_path(path,limits=limits)
    def test_intersecting_ranges_are_exact_and_exclude_adjacent_ranges(self):
        entries=(UnwindEntry(0xff0,0x1000,0,0),UnwindEntry(0x1000,0x1008,0x02000000,8),UnwindEntry(0x1008,0x1010,0x02001000,16),UnwindEntry(0x1010,0x1018,0,24))
        report=self.report(entries);finding=report['findings'][0]
        self.assertEqual((finding['verdict'],finding['scope'],finding['reason_codes'],finding['checked_pcs']),('unresolved','metadata_only',['multiple_metadata_ranges'],[]))
        details=finding['evidence'][1:]
        self.assertEqual([item['address'] for item in details],['0x1000','0x1008'])
        self.assertEqual([item['observed'] for item in details],['preferred_vm=[0x1000, 0x1008) encoding=0x02000000 mode=frameless','preferred_vm=[0x1008, 0x1010) encoding=0x02001000 mode=frameless'])
        self.assertEqual(finding['evidence'][0]['observed'],'2 intersecting ranges; 0 range details omitted')
        self.assertIs(validate_report(report),report)
    def test_detail_cap_reports_omissions_without_losing_refusal(self):
        entries=tuple(UnwindEntry(0x1000+i*4,0x1004+i*4,0x02000000+(0x1000 if i%2 else 0),i*8) for i in range(4))
        finding=self.report(entries,Limits(max_evidence_per_function=2))['findings'][0]
        self.assertEqual(len(finding['evidence']),2)
        self.assertEqual(finding['evidence'][0]['observed'],'4 intersecting ranges; 3 range details omitted')
        self.assertEqual(finding['evidence'][1]['address'],'0x1000')
        self.assertEqual(finding['checked_pcs'],[])
    def test_zero_and_global_evidence_caps_remain_explicit(self):
        entries=(UnwindEntry(0x1000,0x1008,0x02000000,0),UnwindEntry(0x1008,0x1010,0x02001000,8))
        for limits in (Limits(max_evidence_per_function=0),Limits(max_total_evidence=0)):
            report=self.report(entries,limits);finding=report['findings'][0]
            self.assertEqual(finding['verdict'],'unresolved');self.assertEqual(finding['evidence'],[])
    def test_uncovered_prefix_does_not_invent_entry_or_coverage(self):
        finding=self.report((UnwindEntry(0x1008,0x1010,0x02000000,0),))['findings'][0]
        self.assertEqual((finding['coverage'],finding['mode'],finding['encoding']),('unavailable','unknown',None))
        self.assertEqual(finding['evidence'][1]['address'],'0x1008')
    def test_detail_records_original_extent_when_rule_starts_before_function(self):
        finding=self.report((UnwindEntry(0xff0,0x1008,0x02000000,0),UnwindEntry(0x1008,0x1010,0x02001000,8)))['findings'][0]
        self.assertEqual(finding['evidence'][1]['address'],'0xff0')
        self.assertIn('[0xff0, 0x1008)',finding['evidence'][1]['observed'])
    def test_one_slot_summary_and_serialized_round_trip(self):
        entries=(UnwindEntry(0x1000,0x1008,0x02000000,0),UnwindEntry(0x1008,0x1010,0x02001000,8))
        report=self.report(entries,Limits(max_evidence_per_function=1))
        self.assertEqual(report['findings'][0]['evidence'][0]['observed'],'2 intersecting ranges; 2 range details omitted')
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            path=Path(directory)/'report.json';path.write_text(dumps(report))
            self.assertEqual(load_report(path),report)

    def test_single_rule_ending_before_function_remains_partial_metadata(self):
        finding=self.report((UnwindEntry(0x1000,0x1008,0x02000000,0),))['findings'][0]
        self.assertEqual(finding['reason_codes'],['multiple_metadata_ranges'])
        self.assertEqual(finding['evidence'][0]['observed'],'1 intersecting ranges; 0 range details omitted')
        self.assertEqual(finding['checked_pcs'],[])
    def test_global_budget_cannot_be_exceeded_across_split_functions(self):
        image,function,_=fixture((0xd503201f,0xd503201f,0xd503201f,RET))
        image=replace(image,data=image.data*2,slice_size=len(image.data)*2,
                      functions=(function,FunctionRange(0x1010,0x1020,'second','lc_function_starts')),
                      container_sha256='1'*64,slice_sha256='2'*64)
        entries=tuple(UnwindEntry(0x1000+i*8,0x1008+i*8,0x02000000+(0x1000 if i%2 else 0),i*8) for i in range(4))
        with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
            path=Path(directory)/'typed.bin';path.write_bytes(image.data)
            with patch('airs.engine.parse_macho',return_value=image),patch('airs.engine.parse_compact_unwind',return_value=UnwindTable(entries)):
                report=audit_path(path,limits=Limits(max_evidence_per_function=2,max_total_evidence=3))
        self.assertEqual(report['summary']['function_count'],2)
        self.assertEqual([len(f['evidence']) for f in report['findings']],[2,0])
        self.assertEqual(report['findings'][1]['reason_codes'],['report_evidence_budget'])
        self.assertTrue(all(f['verdict']=='unresolved' for f in report['findings']))
