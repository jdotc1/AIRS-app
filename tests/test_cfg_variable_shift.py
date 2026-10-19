"""Owned variable-shift words: literal results, unknowns and recovery boundaries."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI
BASES=(0x1ac02000,0x1ac02400,0x1ac02800,0x1ac02c00,0x9ac02000,0x9ac02400,0x9ac02800,0x9ac02c00)
def word(base,rd=2,rn=0,rm=1):return base|(rm<<16)|(rn<<5)|rd
class VariableShiftTests(unittest.TestCase):
    def op(self,base,value,count,flags=(False,True,True,False),rd=2,rn=0,rm=1):
        state=PathState(flags=flags);state.registers[0]=Value('constant',value);state.registers[1]=Value('constant',count)
        state.apply(decode_instruction(word(base,rd,rn,rm)));return state
    def test_operation_and_operand_order_both_widths(self):
        for base,want in zip(BASES,(24,6,6,6,24,6,6,6)):
            self.assertEqual(self.op(base,12,1).registers[2],Value('constant',want))
    def test_signed_asr_differs_from_logical_right(self):
        for base,value,want in ((BASES[1],0x80000001,0x40000000),(BASES[2],0x80000001,0xc0000000),(BASES[5],0x8000000000000001,0x4000000000000000),(BASES[6],0x8000000000000001,0xc000000000000000)):
            self.assertEqual(self.op(base,value,1).registers[2],Value('constant',want))
    def test_rotate_wrap_and_maximum_shift(self):
        for base,value,count,want in ((BASES[3],0x80000001,1,0xc0000000),(BASES[7],0x8000000000000001,1,0xc000000000000000),(BASES[3],0x80000001,31,3),(BASES[7],0x8000000000000001,63,3),(BASES[0],1,31,0x80000000),(BASES[4],1,63,0x8000000000000000),(BASES[2],0x80000001,31,0xffffffff),(BASES[6],0x8000000000000001,63,0xffffffffffffffff)):
            self.assertEqual(self.op(base,value,count).registers[2],Value('constant',want))
    def test_modulo_zero_width_width_plus_one_and_high_count_bits(self):
        for base in BASES:
            width=64 if base&(1<<31) else 32
            for count in (0,width,width*3,1<<63):self.assertEqual(self.op(base,12,count).registers[2],Value('constant',12))
            want=24 if base in (BASES[0],BASES[4]) else 6
            for count in (1,width+1,(1<<63)|1):self.assertEqual(self.op(base,12,count).registers[2],Value('constant',want))
    def test_allones_count_and_output_width_normalization(self):
        for base,value,want in ((BASES[0],0x100000001,0x80000000),(BASES[1],0x180000001,1),(BASES[2],0x180000001,0xffffffff),(BASES[3],0x180000001,3),(BASES[4],1,0x8000000000000000),(BASES[5],0x8000000000000001,1),(BASES[6],0x8000000000000001,0xffffffffffffffff),(BASES[7],0x8000000000000001,3)):
            self.assertEqual(self.op(base,value,0xffffffffffffffff).registers[2],Value('constant',want))
    def test_unknown_either_operand_even_zero_value_or_count(self):
        for base in BASES:
            for source in (0,1):
                state=PathState();state.registers[1-source]=Value('constant',0);state.apply(decode_instruction(word(base)))
                self.assertFalse(state.registers[2].known)
    def test_zero_count_does_not_copy_original_identity(self):
        for base in BASES:
            state=PathState();state.registers[1]=Value('constant',0);state.apply(decode_instruction(word(base,rd=19,rn=19)))
            self.assertFalse(state.registers[19].known)
    def test_zr_value_count_and_discard(self):
        for base in BASES:
            self.assertEqual(self.op(base,12,1,rn=31).registers[2],Value('constant',0))
            self.assertEqual(self.op(base,12,1,rm=31).registers[2],Value('constant',12))
            state=self.op(base,12,1,rd=31);self.assertEqual(state.sp,Value('stack'));self.assertEqual(state.registers[0],Value('constant',12))
    def test_overlap_reads_original_value_and_count(self):
        for base in BASES:
            want=24 if base in (BASES[0],BASES[4]) else 6
            for rd in (0,1):self.assertEqual(self.op(base,12,1,rd=rd).registers[rd],Value('constant',want))
            want=8 if base in (BASES[0],BASES[4]) else (0x80000000 if base==BASES[3] else 0x8000000000000000 if base==BASES[7] else 0)
            self.assertEqual(self.op(base,2,0,rn=0,rm=0).registers[2],Value('constant',want))
    def test_known_and_unknown_flags_preserved(self):
        for base in BASES:
            for flags in (None,(True,False,True,True),(False,True,False,False)):
                self.assertEqual(self.op(base,12,1,flags=flags).flags,flags)
                state=PathState(flags=flags);state.apply(decode_instruction(word(base)));self.assertEqual(state.flags,flags)
    def test_both_stack_operands_guarded_even_zero_or_discard(self):
        for base in BASES:
            for source in (0,1):
                state=PathState(strict_call_state=True);state.registers[source]=Value('stack');state.registers[1-source]=Value('constant',0)
                with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,rd=31)))
        for base in BASES[4:]:
            state=PathState();state.registers[1]=Value('stack')
            with self.assertRaises(ModelError):state.apply(decode_instruction(word(base)))
    def test_reserved_controls_neighbor_operations_and_dead_words_decline(self):
        for base in BASES:
            for bit in (1<<29,1<<30,1<<21,1<<15,1<<12):
                with self.assertRaises(ModelError):decode_instruction(word(base)^bit)
        for base in (0x1ac00800,0x9ac00c00,0x9ac03000):
            with self.assertRaises(ModelError):decode_instruction(word(base))
        result=audit_current_function(*fixture((0x14000002,word(BASES[0])|(1<<29),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
    def test_unknown_output_preserves_known_cfg_path(self):
        for base in BASES:
            result=audit_current_function(*fixture((0xd2800020,0x7100041f,word(base,rn=9,rm=10),0x54000060,NOP,0x14000002,NOP,RET),0x02000000))
            self.assertEqual(result.verdict,'agreement');self.assertIn(0x1018,result.checked_pcs);self.assertNotIn(0x1010,result.checked_pcs)
    def test_known_mismatch_unknown_recovery_and_possible_only(self):
        for base in BASES:
            self.assertEqual(check((*PAIR_PRO,0xd2800020,0xd2800001,word(base,rd=19),CALL,*PAIR_EPI)).verdict,'inconsistency')
            self.assertEqual(check((*PAIR_PRO,0xd2800001,word(base,rd=19,rn=19),CALL,*PAIR_EPI)).reason_codes,('unknown_recovery_value',))
            self.assertEqual(check((*PAIR_PRO,0x54000080,0xd2800020,0xd2800001,word(base,rd=19),CALL,*PAIR_EPI)).reason_codes,('cfg_path_feasibility_unknown',))
    def test_fde_postcall_scope_and_body_frame_guard(self):
        for base in BASES:
            result=audit_current_function(*image_for((*PRO,CALL,word(base),0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
            self.assertEqual(check((*PRO,word(base,rd=29),0x54000040,CALL,*EPI)).reason_codes,('cfg_frame_transition_not_modeled',))
    def test_path_limit_and_carry_select_flag_consumers(self):
        result=audit_current_function(*fixture((word(BASES[7]),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
        state=self.op(BASES[7],12,1);state.registers[0]=Value('constant',2);state.registers[1]=Value('constant',3)
        state.apply(decode_instruction(0x9a010003));self.assertEqual(state.registers[3],Value('constant',6))
        state.apply(decode_instruction(0x9a810004));self.assertEqual(state.registers[4],Value('constant',2))
