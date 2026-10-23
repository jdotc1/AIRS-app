"""Focused equivalent compact-rule admission using new typed input data."""
import os
from dataclasses import replace
from pathlib import Path
import tempfile
from output_paths import output_root
import unittest
from unittest.mock import patch
from airs import ANALYSIS_MODEL_VERSION
from airs.engine import audit_path
from airs.report import validate_report, dumps, load_report
from airs.types import Limits, UnwindEntry, UnwindTable, InputError, Issue
from test_rbit_x_candidate import fixture, PRO, EPI, PAIR_PRO, PAIR_EPI, CALL, RET
from test_report_v32_admission_candidate import synthetic_report

OUTPUT = output_root()
MODEL='arm64-bounded-equivalent-compact-v39'


def report_for(entries=None, *, words=(0xd503201f,0xd503201f,0xd503201f,RET), encoding=0x02000000, limits=Limits(), with_callee=False, boundary='lc_function_starts', subtype=0, table_issues=(), append_sink=True):
    image,function,entry=fixture(words,encoding,with_callee=with_callee)
    if entries is None:
        middle=function.start+len(words)//2*4
        entries=(replace(entry,end=middle),replace(entry,start=middle,source_offset=8))
    if with_callee and append_sink:
        entries=(*entries,UnwindEntry(0x1100,0x1108,0x02000000,16))
    function=replace(function,boundary_source=boundary)
    image=replace(image,container_sha256='1'*64,slice_sha256='2'*64,cpu_subtype=subtype,functions=(function,*image.functions[1:]))
    with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
        source=Path(directory)/'typed.bin';source.write_bytes(image.data)
        with patch('airs.engine.parse_macho',return_value=image),patch('airs.engine.parse_compact_unwind',return_value=UnwindTable(entries,table_issues)):
            return audit_path(source,limits=limits)

class EquivalentCompactTests(unittest.TestCase):
    def test_equal_leaf_ranges_gain_without_replacing_original_metadata(self):
        report=report_for();finding=report['findings'][0]
        self.assertEqual((finding['verdict'],finding['scope']),('agreement','modeled_leaf_body'))
        self.assertEqual(finding['checked_pcs'],['0x1000','0x1004','0x1008'])
        self.assertEqual(report['metadata_ranges'],[{'start':'0x1000','end':'0x1008','encoding':'0x02000000','mode':'frameless'},{'start':'0x1008','end':'0x1010','encoding':'0x02000000','mode':'frameless'}])
        self.assertTrue(any(e['code']=='equivalent_compact_ranges' for e in finding['evidence']))
        self.assertIs(validate_report(report),report)
    def test_equal_frame_ranges_reuse_original_call_pcs_and_keep_sink(self):
        report=report_for(words=(*PRO,CALL,CALL,*EPI),encoding=0x04000000,with_callee=True)
        self.assertEqual(report['summary']['function_count'],2)
        self.assertEqual(report['summary']['agreement_count'],2)
        first=report['findings'][0]
        self.assertEqual((first['scope'],first['checked_pcs']),('synchronous_call_sites',['0x1008','0x100c']))
        self.assertEqual(len(report['metadata_ranges']),3)
    def test_covering_extents_can_start_before_and_end_after_function(self):
        report=report_for((UnwindEntry(0xff0,0x1008,0x02000000,64),UnwindEntry(0x1008,0x1020,0x02000000,80)))
        self.assertEqual(report['findings'][0]['verdict'],'agreement')
        self.assertEqual(report['metadata_ranges'][0]['start'],'0xff0')
        self.assertEqual(report['metadata_ranges'][-1]['end'],'0x1020')
    def test_changed_encoding_prefix_internal_and_trailing_gaps_decline(self):
        for entries in ((UnwindEntry(0x1000,0x1008,0x02000000,0),UnwindEntry(0x1008,0x1010,0x02001000,8)),(UnwindEntry(0x1004,0x1008,0x02000000,0),UnwindEntry(0x1008,0x1010,0x02000000,8)),(UnwindEntry(0x1000,0x1004,0x02000000,0),UnwindEntry(0x1008,0x1010,0x02000000,8)),(UnwindEntry(0x1000,0x1008,0x02000000,0),UnwindEntry(0x1008,0x100c,0x02000000,8))):
            finding=report_for(entries)['findings'][0]
            self.assertEqual((finding['verdict'],finding['reason_codes'],finding['checked_pcs']),('unresolved',['multiple_metadata_ranges'],[]))
    def test_overlapping_ranges_cannot_be_normalized(self):
        finding=report_for((UnwindEntry(0x1000,0x100c,0x02000000,0),UnwindEntry(0x1008,0x1010,0x02000000,8)))['findings'][0]
        self.assertEqual(finding['verdict'],'unresolved')
        self.assertEqual(finding['checked_pcs'],[])
    def test_excluded_modes_and_unknown_compact_bits_never_gain(self):
        for encoding in (0,0x03000000,0x01000000,0x05000000,0x02000800):
            finding=report_for(encoding=encoding)['findings'][0]
            self.assertEqual(finding['verdict'],'unresolved',hex(encoding))
            self.assertEqual(finding['checked_pcs'],[])
    def test_independent_boundary_and_ordinary_architecture_still_required(self):
        for boundary,subtype in (('compact_unwind',0),('lc_function_starts',0x80000000)):
            finding=report_for(boundary=boundary,subtype=subtype)['findings'][0]
            self.assertEqual(finding['verdict'],'unresolved')
            self.assertEqual(finding['checked_pcs'],[])
    def test_equal_rule_is_not_automatic_agreement_for_unknown_recovery(self):
        report=report_for(words=(*PAIR_PRO,0x9ac10813,CALL,*PAIR_EPI),encoding=0x04000000,with_callee=True)
        first=report['findings'][0]
        self.assertEqual(first['verdict'],'unresolved')
        self.assertIn('unknown_recovery_value',first['reason_codes'])
        self.assertEqual(first['checked_pcs'],[])
    def test_equivalent_wrong_rule_retains_concrete_inconsistency(self):
        report=report_for(words=(*PAIR_PRO,0xd28000d3,CALL,*PAIR_EPI),encoding=0x04000000,with_callee=True)
        first=report['findings'][0]
        self.assertEqual(first['verdict'],'inconsistency')
        self.assertEqual(first['checked_pcs'],['0x1014'])
        self.assertTrue(any(e.get('observed')=='constant 0x6' for e in first['evidence']))
    def test_small_evidence_and_work_budgets_never_fake_agreement(self):
        for limits in (Limits(max_evidence_per_function=0),Limits(max_evidence_per_function=1),Limits(max_total_evidence=0),Limits(max_cfg_steps_per_function=0),Limits(max_total_instructions=0),Limits(max_instructions_per_function=1)):
            words=(0x5ac00000,0xd503201f,0xd503201f,RET) if limits.max_cfg_steps_per_function==0 else (0xd503201f,0xd503201f,0xd503201f,RET)
            finding=report_for(limits=limits,words=words)['findings'][0]
            self.assertEqual(finding['verdict'],'unresolved')
            self.assertEqual(finding['checked_pcs'],[])
            self.assertLessEqual(len(finding['evidence']),limits.max_evidence_per_function)
    def test_single_rule_control_has_no_normalization_evidence(self):
        finding=report_for((UnwindEntry(0x1000,0x1010,0x02000000,0),))['findings'][0]
        self.assertEqual(finding['verdict'],'agreement')
        self.assertFalse(any(e['code']=='equivalent_compact_ranges' for e in finding['evidence']))
    def test_current_emission_serialization_and_v39_admission(self):
        report=report_for();self.assertEqual(report['generator']['analysis_model_version'],ANALYSIS_MODEL_VERSION)
        output=OUTPUT/'equivalent-v39.json';output.write_text(dumps(report));self.assertEqual(load_report(output),report)
        for model in (MODEL,'arm64-bounded-w-rbit-v38'):
            wire=synthetic_report(model);wire['image']['cpu_subtype']=0x80000000
            with self.assertRaises(InputError):validate_report(wire)
        wire=synthetic_report(MODEL+'-future');wire['image']['cpu_subtype']=0x80000000
        self.assertIs(validate_report(wire),wire)

    def test_one_equivalent_rule_spans_two_independent_functions(self):
        report=report_for((UnwindEntry(0x1000,0x1008,0x02000000,0),UnwindEntry(0x1008,0x1104,0x02000000,8),UnwindEntry(0x1104,0x1108,0x02000000,16)),with_callee=True,append_sink=False)
        self.assertEqual((report['summary']['function_count'],report['summary']['agreement_count']),(2,2))
        self.assertEqual([f['function']['address'] for f in report['findings']],['0x1000','0x1100'])
        self.assertEqual(report['findings'][1]['checked_pcs'],['0x1100'])
        self.assertTrue(all(any(e['code']=='equivalent_compact_ranges' for e in f['evidence']) for f in report['findings']))
        self.assertEqual(len(report['metadata_ranges']),3)
    def test_prior_overlapping_entry_and_table_issue_prevent_normalization(self):
        finding=report_for((UnwindEntry(0xff0,0x1008,0x02000000,0),UnwindEntry(0x1000,0x1008,0x02000000,8),UnwindEntry(0x1008,0x1010,0x02000000,16)))['findings'][0]
        self.assertEqual(finding['verdict'],'unresolved')
        report=report_for(table_issues=(Issue('owned_structural_issue','Typed malformed metadata control'),))
        self.assertEqual(report['findings'][0]['verdict'],'unresolved')
        self.assertEqual(report['issues'][0]['code'],'owned_structural_issue')
    def test_new_model_scope_boundary_and_dwarf_admission_are_exact(self):
        for fault in ('boundary','scope','encoding','dwarf'):
            wire=synthetic_report(MODEL);finding=wire['findings'][0]
            if fault=='boundary':finding['function']['boundary_source']='compact_unwind'
            elif fault=='scope':finding['scope']='modeled_leaf_body'
            elif fault=='encoding':finding['encoding']='0x04000100'
            else:finding.update(mode='dwarf',coverage='dwarf_reference',encoding='0x03000004')
            with self.subTest(fault=fault),self.assertRaises(InputError):validate_report(wire)

    def test_global_evidence_budget_retains_second_normalizable_function(self):
        entries=(UnwindEntry(0x1000,0x1008,0x02000000,0),UnwindEntry(0x1008,0x1104,0x02000000,8),UnwindEntry(0x1104,0x1108,0x02000000,16))
        report=report_for(entries,with_callee=True,append_sink=False,limits=Limits(max_evidence_per_function=2,max_total_evidence=3))
        self.assertEqual(report['summary']['function_count'],2)
        self.assertEqual([f['verdict'] for f in report['findings']],['agreement','unresolved'])
        self.assertEqual([len(f['evidence']) for f in report['findings']],[2,0])
        self.assertEqual(report['findings'][1]['reason_codes'],['report_evidence_budget'])
