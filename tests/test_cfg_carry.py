"""Literal carry arithmetic boundaries and known/possible recovery witnesses."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI

# W/X ADC, ADCS, SBC, SBCS R2,R0,R1, with no shift/extension encoding.
OPS=(0x1a010002,0x3a010002,0x5a010002,0x7a010002,0x9a010002,0xba010002,0xda010002,0xfa010002)
FLAGGED=(OPS[1],OPS[3],OPS[5],OPS[7])
class CarryTests(unittest.TestCase):
    def op(self,word,left,right,flags):
        state=PathState(flags=flags);state.registers[0]=Value('constant',left);state.registers[1]=Value('constant',right)
        state.apply(decode_instruction(word));return state
    def test_adc_and_sbc_both_carry_inputs_each_width(self):
        for index,op in enumerate(OPS):
            for carry in (False,True):
                flags=(True,True,carry,True);state=self.op(op,9,3,flags)
                expected=(12+carry) if index%4<2 else (5+carry)
                self.assertEqual(state.registers[2],Value('constant',expected))
                self.assertEqual(state.flags, (False,False,index%4>=2,False) if op in FLAGGED else flags)
    def test_adcs_w_wrap_carry_and_zero_extension(self):
        for left,right,c,result,flags in ((0xffffffff,0,1,0,(False,True,True,False)),(0xffffffff,0,0,0xffffffff,(True,False,False,False)),(0x100000000,0x100000001,1,2,(False,False,False,False)),(0x7fffffff,0,1,0x80000000,(True,False,False,True)),(0x80000000,0xffffffff,0,0x7fffffff,(False,False,True,True))):
            state=self.op(OPS[1],left,right,(False,False,bool(c),False));self.assertEqual((state.registers[2],state.flags),(Value('constant',result),flags))
    def test_adcs_x_wrap_and_signed_overflow_includes_carry(self):
        for left,right,c,result,flags in ((0xffffffffffffffff,0,1,0,(False,True,True,False)),(0x7fffffffffffffff,0,1,0x8000000000000000,(True,False,False,True)),(0x8000000000000000,0xffffffffffffffff,0,0x7fffffffffffffff,(False,False,True,True))):
            state=self.op(OPS[5],left,right,(False,False,bool(c),False));self.assertEqual((state.registers[2],state.flags),(Value('constant',result),flags))
    def test_sbcs_zero_minus_zero_carry_borrow_both_widths(self):
        for op,minusone in ((OPS[3],0xffffffff),(OPS[7],0xffffffffffffffff)):
            for c,result,flags in ((0,minusone,(True,False,False,False)),(1,0,(False,True,True,False))):
                state=self.op(op,0,0,(True,False,bool(c),True));self.assertEqual((state.registers[2],state.flags),(Value('constant',result),flags))
    def test_sbcs_signed_bounds_and_allones_borrow(self):
        cases=((OPS[3],0x80000000,0,0,0x7fffffff,(False,False,True,True)),(OPS[3],0x7fffffff,0xffffffff,1,0x80000000,(True,False,False,True)),(OPS[7],0x8000000000000000,0,0,0x7fffffffffffffff,(False,False,True,True)),(OPS[7],0x7fffffffffffffff,0xffffffffffffffff,1,0x8000000000000000,(True,False,False,True)),(OPS[7],0xffffffffffffffff,0xffffffffffffffff,0,0xffffffffffffffff,(True,False,False,False)))
        for op,left,right,c,result,flags in cases:
            state=self.op(op,left,right,(False,False,bool(c),False));self.assertEqual((state.registers[2],state.flags),(Value('constant',result),flags))
    def test_nonflag_forms_preserve_entire_old_tuple(self):
        for op in (OPS[0],OPS[2],OPS[4],OPS[6]):
            for flags in (None,(True,True,False,True),(False,True,True,True)):
                state=self.op(op,0xffffffffffffffff,1,flags);self.assertEqual(state.flags,flags)
    def test_unknown_carry_makes_concrete_operands_unknown(self):
        for op in OPS:
            state=self.op(op,0,0,None);self.assertFalse(state.registers[2].known);self.assertIsNone(state.flags)
    def test_either_unknown_operand_invalidates_flagged_only(self):
        for op in OPS:
            for unknown in (0,1):
                flags=(True,True,True,True);state=PathState(flags=flags);state.registers[1-unknown]=Value('constant',0)
                state.apply(decode_instruction(op));self.assertFalse(state.registers[2].known);self.assertEqual(state.flags,None if op in FLAGGED else flags)
    def test_zr_sources_destination_and_ngc_aliases(self):
        for index,op in enumerate(OPS):
            base=op&~((31<<16)|(31<<5)|31)
            state=self.op(base|(31<<16)|(31<<5)|2,99,99,(False,False,True,False))
            self.assertEqual(state.registers[2],Value('constant',1 if index%4<2 else 0))
            state=self.op(base|(1<<16)|(31<<5)|2,99,3,(False,False,False,False))
            want=3 if index%4<2 else (0xfffffffc if index<4 else 0xfffffffffffffffc)
            self.assertEqual(state.registers[2],Value('constant',want))
            state=self.op((op&~31)|31,9,3,(False,False,True,False));self.assertEqual(state.sp,Value('stack'));self.assertEqual(state.registers[0],Value('constant',9))
    def test_overlap_reads_old_sources_and_carry_before_flags_write(self):
        for op in OPS:
            for rd in (0,1):
                state=self.op((op&~31)|rd,9,3,(False,False,True,False));self.assertEqual(state.registers[rd],Value('constant',13 if op in OPS[:2]+OPS[4:6] else 6))
    def test_both_source_provenance_guard_before_discard_or_unknown_carry(self):
        for op in OPS:
            for source in (0,1):
                state=PathState(flags=None,strict_call_state=True);state.registers[source]=Value('stack')
                with self.assertRaises(ModelError):state.apply(decode_instruction((op&~31)|31))
        for op in OPS[4:]:
            state=PathState();state.registers[1]=Value('stack')
            with self.assertRaises(ModelError):state.apply(decode_instruction(op))
    def test_exact_encoding_excludes_reserved_shift_and_other_flag_families(self):
        for op in OPS:
            for bits in (1<<10,1<<15,1<<21,(1<<22)|(1<<4)):
                with self.assertRaises(ModelError):decode_instruction(op|bits)
        for word in (0x3a000800,0xba000400,0xfa000800):
            with self.assertRaises(ModelError):decode_instruction(word)
    def test_known_branch_csel_and_unknown_carry_cfg_paths(self):
        for op in OPS:
            known=(0x92800000,0xd2800001,0x7100041f,op,0x1a800043,0x54000062,NOP,0x14000002,NOP,RET)
            result=audit_current_function(*fixture(known,0x02000000));self.assertEqual(result.verdict,'agreement');self.assertIn(0x1020,result.checked_pcs);self.assertNotIn(0x1018,result.checked_pcs)
            unknown=(0x92800000,0xd2800001,op,0x54000060,NOP,0x14000002,NOP,RET)
            result=audit_current_function(*fixture(unknown,0x02000000));self.assertEqual(result.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
    def test_known_vs_possible_only_saved_pair_discrepancy(self):
        for op in OPS:
            known=(*PAIR_PRO,0x92800000,0xd2800001,0x7100041f,op,0x54000063,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(known).verdict,'inconsistency')
            unknown=(*PAIR_PRO,0x92800000,0xd2800001,op,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_unknown_carry_and_fresh_cmp_keep_fde_scope(self):
        for op in OPS:
            result=audit_current_function(*image_for((*PRO,CALL,0xd2800020,0xd2800001,op,0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
        for op in OPS:
            result=audit_current_function(*image_for((*PRO,CALL,0x92800000,0xd2800001,0x7100041f,op,0x54000042,NOP,*EPI),CFI))
            self.assertEqual(result.verdict,'agreement');self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('1 terminal paths' in e.message for e in result.evidence))
    def test_frame_guard_dead_reserved_and_path_budget(self):
        for op in OPS:self.assertEqual(check((*PRO,(op&~31)|29,0x54000040,CALL,*EPI)).reason_codes,('cfg_frame_transition_not_modeled',))
        result=audit_current_function(*fixture((0x14000002,OPS[1]|(1<<10),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
        result=audit_current_function(*fixture((OPS[0],0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
    def test_carry_chains_use_previous_flagged_output(self):
        state=self.op(OPS[1],0xffffffff,0,(False,False,True,False))
        state.registers[0]=Value('constant',5);state.registers[1]=Value('constant',2)
        state.apply(decode_instruction(OPS[4]));self.assertEqual(state.registers[2],Value('constant',8));self.assertEqual(state.flags,(False,True,True,False))
        state=self.op(OPS[7],0,0,(False,False,False,False))
        state.registers[0]=Value('constant',5);state.registers[1]=Value('constant',2)
        state.apply(decode_instruction(OPS[6]));self.assertEqual(state.registers[2],Value('constant',2));self.assertEqual(state.flags,(True,False,False,False))
