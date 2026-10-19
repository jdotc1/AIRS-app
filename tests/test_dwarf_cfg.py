"""Owned literal CFG code and bounded CFI programs; inspected code never runs."""
from dataclasses import replace
import struct
import unittest
from airs.cfg import audit_current_function
from airs.types import Limits, Section
from test_cfg_calls import call_fixture, CHOICE, FLAGS, SKIP, PAIR_BAD, PRO, EPI, CALL
from test_dwarf_cfi import CIE, record, EH_ADDRESS

# After STP: CFA=SP+16, FP@CFA-16, LR@CFA-8; after MOV: CFA=FP+16.
CFI=bytes.fromhex('440e109d029e01440c1d10')
def image_for(words=CHOICE,program=CFI,tail=b''):
    image,fn,entry=call_fixture(words)
    cie=record(bytes(4)+CIE); off=len(cie)
    body=struct.pack('<IqQ',off+4,fn.start-(EH_ADDRESS+off+8),fn.size)+b'\0'+program
    eh=cie+record(body)+tail
    section=Section('__TEXT','__eh_frame',EH_ADDRESS,len(eh),len(image.data))
    return replace(image,data=image.data+eh,sections=image.sections+(section,)),fn,replace(entry,encoding=0x03000000|off)
def check(words=CHOICE,program=CFI,limits=Limits(),tail=b''):
    return audit_current_function(*image_for(words,program,tail),limits)

class DwarfCFGTests(unittest.TestCase):
    def test_conditional_calls_use_evaluated_rows_and_call_scope(self):
        r=check();self.assertEqual((r.verdict,r.coverage,r.scope),('agreement','dwarf_evaluated','synchronous_call_sites'))
        self.assertEqual(r.checked_pcs,(0x1010,0x1018));self.assertTrue(any(e.code=='dwarf_cfi_row' for e in r.evidence))
    def test_row_at_bl_not_return_pc_and_exact_transition(self):
        # At BL 0x1010 change LR to same_value (wrong); PC+4 restores slot.
        r=check(program=CFI+bytes.fromhex('48081e449e01'))
        self.assertEqual((r.verdict,r.reason_codes),('unresolved',('cfg_path_feasibility_unknown',)))
        known=(*PRO,0xd2800100,0x71001c1f,0x5400006d,CALL,0x14000002,CALL,*EPI)
        r=check(known,CFI+bytes.fromhex('4c081e449e01'))
        self.assertEqual(r.verdict,'inconsistency')
        self.assertTrue(any(e.expected=='original x30' and e.observed=='constant 0x1018' for e in r.evidence))
    def test_unknown_overrides_known_mismatch(self):
        r=check(program=CFI+bytes.fromhex('081e0713'))
        self.assertEqual((r.verdict,r.reason_codes),('unresolved',('unknown_recovery_value',)))
    def test_flags_and_no_call_paths(self):
        self.assertEqual(check(FLAGS).verdict,'agreement');self.assertEqual(check(SKIP).verdict,'agreement')
        words=(*PRO,0xd2800100,0x71001c1f,0x5400004c,CALL,*EPI)
        self.assertEqual(check(words).reason_codes,('no_supported_observation',))
    def test_saved_pair_rules_and_known_mismatch(self):
        # Pair frame CFA=FP+16, saved x19 at CFA-24, x20 at CFA-32.
        cfi=bytes.fromhex('440e20489d029e01440c1d10')
        self.assertEqual(check(PAIR_BAD,cfi).verdict,'inconsistency')
        self.assertEqual(check(PAIR_BAD,cfi+bytes.fromhex('93039404')).verdict,'agreement')
    def test_late_unsupported_cfi_and_bad_extent_stay_reference(self):
        self.assertEqual(check(program=CFI+b'\x0a').coverage,'dwarf_reference')
        image,fn,entry=image_for();r=audit_current_function(image,replace(fn,end=fn.end-4),entry)
        self.assertEqual((r.verdict,r.coverage),('unresolved','dwarf_reference'))
    def test_cfg_budget_and_invalid_target_keep_evaluated_coverage(self):
        r=check(limits=replace(Limits(),max_cfg_steps_per_function=2))
        self.assertEqual((r.reason_codes,r.coverage),(('cfg_work_limit',),'dwarf_evaluated'))
        words=list(CHOICE);words[4]=0x94000000
        r=check(words);self.assertEqual((r.reason_codes,r.coverage),(('cfg_call_target_not_modeled',),'dwarf_evaluated'))
    def test_no_calls_or_loop_and_tiny_evidence_remain_bounded(self):
        words=(*PRO,0x71001c1f,0x5400002d,0xd503201f,*EPI)
        self.assertEqual(check(words).verdict,'unresolved')
        words=list(CHOICE);words[5]=0x17ffffff
        # v28 still excludes unconditional backward cycles.
        self.assertEqual(check(words).reason_codes,('cfg_loop_shape_not_modeled',))
        self.assertEqual(check(limits=replace(Limits(),max_evidence_per_function=0)).verdict,'unresolved')

    def test_stack_escape_and_partial_pointer_provenance_remain_unknown(self):
        words=(*PRO,0x910003e0,0x5400004d,CALL,*EPI)
        self.assertEqual(check(words).reason_codes,('stack_address_escapes_call',))
        words=(*PRO,0x910003e0,0x11000000,0x5400004d,CALL,*EPI)
        self.assertEqual(check(words).reason_codes,('stack_address_truncation_not_modeled',))

    def test_pipeline_charges_shared_cfg_budget_and_accepts_common_flags(self):
        from unittest.mock import patch
        import tempfile
        from pathlib import Path
        from airs.engine import audit_path
        from airs.types import UnwindTable
        from airs.report import validate_report
        image,fn,entry=image_for()
        image=replace(image,functions=(fn,fn,image.functions[1]))
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'owned';path.write_bytes(image.data)
            with patch('airs.engine.parse_macho',return_value=image),patch('airs.engine.parse_compact_unwind',return_value=UnwindTable((entry,))):
                # Two retained denominator entries deliberately share the same test range;
                # inspect engine outcomes before validator duplicate-identity gate.
                report=audit_path(path,limits=replace(Limits(),max_total_cfg_steps=15))
        self.assertEqual([f['verdict'] for f in report['findings'][:2]],['agreement','unresolved'])
        self.assertTrue(any(i['code']=='cfg_budget_reached' for i in report['issues']))
        image,fn,entry=image_for()
        self.assertEqual(audit_current_function(image,fn,replace(entry,encoding=entry.encoding|0x80000000)).verdict,'agreement')
