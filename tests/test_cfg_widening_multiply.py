"""Owned signed/unsigned widening multiply words and concrete recovery boundaries."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI
BASES=(0x9b200000,0x9b208000,0x9ba00000,0x9ba08000)
def word(base,rd=3,rn=0,rm=1,ra=2):return base|(rm<<16)|(ra<<10)|(rn<<5)|rd
class WideningMultiplyTests(unittest.TestCase):
    def op(self,base,left,right,accum,flags=(False,True,True,False),rd=3,rn=0,rm=1,ra=2):
        state=PathState(flags=flags)
        for r,v in enumerate((left,right,accum)):state.registers[r]=Value('constant',v)
        state.apply(decode_instruction(word(base,rd,rn,rm,ra)));return state
    def test_signed_unsigned_factor_difference_and_subtract_order(self):
        for base,want in zip(BASES,(5,9,0x200000005,0xfffffffe00000009)):
            self.assertEqual(self.op(base,0xffffffff,2,7).registers[3],Value('constant',want))
            self.assertEqual(self.op(base,2,0xffffffff,7).registers[3],Value('constant',want))
    def test_all_four_zero_accumulator_aliases(self):
        for base,want in zip(BASES,(0xfffffffffffffffe,2,0x1fffffffe,0xfffffffe00000002)):
            self.assertEqual(self.op(base,0xffffffff,2,99,ra=31).registers[3],Value('constant',want))
    def test_both_factors_project_low32_before_signedness(self):
        for base,want in zip(BASES,(5,9,0x200000005,0xfffffffe00000009)):
            self.assertEqual(self.op(base,0x12345678ffffffff,0xabcdef0100000002,7).registers[3],Value('constant',want))
    def test_unsigned_max_and_signed_minimum_products(self):
        for base,left,right,want in ((BASES[0],0x80000000,0x80000000,0x4000000000000000),(BASES[2],0xffffffff,0xffffffff,0xfffffffe00000001),(BASES[0],0x80000000,0xffffffff,0x80000000),(BASES[2],0x80000000,0xffffffff,0x7fffffff80000000)):
            self.assertEqual(self.op(base,left,right,0).registers[3],Value('constant',want))
    def test_accumulator_keeps_high32_and_full64_wrap(self):
        for base,want in zip(BASES,(0x100000014,0xffffffec,0x100000014,0xffffffec)):
            self.assertEqual(self.op(base,4,5,0x100000000).registers[3],Value('constant',want))
        for base,left,right,accum,want in ((BASES[0],0xffffffff,2,0xffffffffffffffff,0xfffffffffffffffd),(BASES[1],0xffffffff,2,0xffffffffffffffff,1),(BASES[2],1,2,0xffffffffffffffff,1),(BASES[3],4,5,3,0xffffffffffffffef)):
            self.assertEqual(self.op(base,left,right,accum).registers[3],Value('constant',want))
    def test_zr_factors_accumulator_and_discard(self):
        for base in BASES:
            for field in ('rn','rm'):self.assertEqual(self.op(base,4,5,27,**{field:31}).registers[3],Value('constant',27))
            self.assertEqual(self.op(base,4,5,27,rn=31,rm=31,ra=31).registers[3],Value('constant',0))
            state=self.op(base,4,5,27,rd=31);self.assertEqual(state.sp,Value('stack'));self.assertEqual(state.registers[0],Value('constant',4))
    def test_overlap_reads_factors_and_full_accumulator_before_write(self):
        for base,want in zip(BASES,(5,9,0x200000005,0xfffffffe00000009)):
            for rd in (0,1,2):self.assertEqual(self.op(base,0xffffffff,2,7,rd=rd).registers[rd],Value('constant',want))
        for base,want in zip(BASES,(0x100000014,0xfffffff4,0x100000014,0xfffffff4)):
            self.assertEqual(self.op(base,0x100000010,9,7,rd=0,rn=0,rm=31,ra=0).registers[0],Value('constant',0x100000010))
            self.assertEqual(self.op(base,0x100000004,9,7,rd=0,rn=0,rm=0,ra=0).registers[0],Value('constant',want))
    def test_unknown_each_operand_even_zero_product(self):
        for base in BASES:
            for unknown in (0,1,2):
                state=PathState()
                for r in (0,1,2):
                    if r!=unknown:state.registers[r]=Value('constant',0)
                state.apply(decode_instruction(word(base)));self.assertFalse(state.registers[3].known)
    def test_zero_product_does_not_copy_original_accumulator_identity(self):
        for base in BASES:
            state=PathState();state.apply(decode_instruction(word(base,rd=19,rn=31,rm=31,ra=19)));self.assertFalse(state.registers[19].known)
    def test_all_three_raw_stack_operands_rejected_in_leaf_and_call(self):
        for base in BASES:
            for strict in (False,True):
                for source in (0,1,2):
                    state=PathState(strict_call_state=strict)
                    for r in (0,1,2):state.registers[r]=Value('stack') if r==source else Value('constant',0)
                    with self.assertRaisesRegex(ModelError,'derived stack address'):state.apply(decode_instruction(word(base,rd=31)))
    def test_known_and_unknown_flags_preserved(self):
        for base in BASES:
            for flags in (None,(True,False,True,True),(False,True,False,False)):
                self.assertEqual(self.op(base,0xffffffff,2,7,flags=flags).flags,flags)
                state=PathState(flags=flags);state.apply(decode_instruction(word(base)));self.assertEqual(state.flags,flags)
    def test_invalid_width_controls_high_multiply_and_dead_words_decline(self):
        for base in BASES:
            for bit in (1<<31,1<<29,1<<30,1<<22):
                with self.assertRaises(ModelError):decode_instruction(word(base)^bit)
        for base in (0x9b40fc00,0x9bc0fc00,0x9b600000,0x9be00000):
            with self.assertRaises(ModelError):decode_instruction(word(base,ra=31))
        result=audit_current_function(*fixture((0x14000002,word(BASES[0])^(1<<31),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
    def test_unknown_output_preserves_known_cfg_path(self):
        for base in BASES:
            result=audit_current_function(*fixture((0xd2800020,0x7100041f,word(base,rn=9,rm=10,ra=11),0x54000060,NOP,0x14000002,NOP,RET),0x02000000))
            self.assertEqual(result.verdict,'agreement');self.assertIn(0x1018,result.checked_pcs);self.assertNotIn(0x1010,result.checked_pcs)
    def test_known_mismatch_unknown_recovery_and_possible_only(self):
        for base in BASES:
            self.assertEqual(check((*PAIR_PRO,0xd2800080,0xd28000a1,word(base,rd=19,ra=31),CALL,*PAIR_EPI)).verdict,'inconsistency')
            self.assertEqual(check((*PAIR_PRO,word(base,rd=19,rn=19,ra=31),CALL,*PAIR_EPI)).reason_codes,('unknown_recovery_value',))
            self.assertEqual(check((*PAIR_PRO,0x54000080,0xd2800080,0xd28000a1,word(base,rd=19,ra=31),CALL,*PAIR_EPI)).reason_codes,('cfg_path_feasibility_unknown',))
    def test_fde_postcall_scope_and_frame_guard(self):
        for base in BASES:
            result=audit_current_function(*image_for((*PRO,CALL,word(base),0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
            self.assertEqual(check((*PRO,word(base,rd=29),0x54000040,CALL,*EPI)).reason_codes,('cfg_frame_transition_not_modeled',))
    def test_path_cap_and_carry_select_flag_consumers(self):
        result=audit_current_function(*fixture((word(BASES[2]),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
        state=self.op(BASES[0],0xffffffff,2,7);state.registers[0]=Value('constant',2);state.registers[1]=Value('constant',3)
        state.apply(decode_instruction(0x9a010003));self.assertEqual(state.registers[3],Value('constant',6))
        state.apply(decode_instruction(0x9a810004));self.assertEqual(state.registers[4],Value('constant',2))
