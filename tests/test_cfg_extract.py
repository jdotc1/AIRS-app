"""Bounded EXTR and ROR immediate: high/low order, widths and unknown identity."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI
BASES=(0x13800000,0x93c00000)
def word(base,amount=8,rd=2,rn=0,rm=1):return base|(rm<<16)|(amount<<10)|(rn<<5)|rd
class ExtractTests(unittest.TestCase):
    def op(self,base,high,low,amount=8,flags=(True,False,True,True),rd=2,rn=0,rm=1):
        state=PathState(flags=flags);state.registers[0]=Value('constant',high);state.registers[1]=Value('constant',low)
        state.apply(decode_instruction(word(base,amount,rd,rn,rm)));return state
    def test_distinct_register_pair_high_low_order_both_widths(self):
        self.assertEqual(self.op(BASES[0],0x12345678,0x9abcdef0).registers[2],Value('constant',0x789abcde))
        self.assertEqual(self.op(BASES[1],0x0123456789abcdef,0xfedcba9876543210).registers[2],Value('constant',0xeffedcba98765432))
    def test_zero_shift_returns_width_bounded_low_register(self):
        self.assertEqual(self.op(BASES[0],0xffffffff,0x100000005,amount=0).registers[2],Value('constant',5))
        self.assertEqual(self.op(BASES[1],0xffffffff,0x10000000000000005,amount=0).registers[2],Value('constant',5))
    def test_one_and_maximum_shift_boundary_bits(self):
        for base,bits in ((BASES[0],32),(BASES[1],64)):
            self.assertEqual(self.op(base,1,0,amount=1).registers[2],Value('constant',1<<(bits-1)))
            self.assertEqual(self.op(base,1,1<<(bits-1),amount=bits-1).registers[2],Value('constant',3))
            self.assertEqual(self.op(base,(1<<bits)-1,(1<<bits)-1,amount=bits-1).registers[2],Value('constant',(1<<bits)-1))
    def test_ror_alias_same_source_zero_one_and_maximum(self):
        for base,bits in ((BASES[0],32),(BASES[1],64)):
            value=(1<<(bits-1))|1
            for amount,want in ((0,value),(1,3<<(bits-2)),(bits-1,3)):
                self.assertEqual(self.op(base,value,0,amount=amount,rn=0,rm=0).registers[2],Value('constant',want))
    def test_w_projection_and_destination_zero_extension(self):
        self.assertEqual(self.op(BASES[0],0x112345678,0x29abcdef0).registers[2],Value('constant',0x789abcde))
        self.assertEqual(self.op(BASES[0],0x1ffffffff,0x1ffffffff,amount=0).registers[2],Value('constant',0xffffffff))
    def test_all_known_and_unknown_flags_preserved(self):
        for base in BASES:
            for flags in (None,(True,True,False,True),(False,False,True,False)):
                self.assertEqual(self.op(base,1,2,flags=flags).flags,flags)
                state=PathState(flags=flags);state.apply(decode_instruction(word(base)));self.assertEqual(state.flags,flags)
    def test_unknown_either_source_and_zero_shift_high_source_remain_conservative(self):
        for base in BASES:
            for source in (0,1):
                for amount in (0,8):
                    state=PathState();state.registers[1-source]=Value('constant',5);state.apply(decode_instruction(word(base,amount)))
                    self.assertFalse(state.registers[2].known)
    def test_unknown_ror_zero_does_not_recreate_original_identity(self):
        for base in BASES:
            state=PathState();state.apply(decode_instruction(word(base,0,rd=19,rn=19,rm=19)));self.assertFalse(state.registers[19].known)
    def test_zr_sources_and_destination_discard(self):
        for base,bits in ((BASES[0],32),(BASES[1],64)):
            state=self.op(base,8,1,amount=1,rn=31);self.assertEqual(state.registers[2],Value('constant',0))
            state=self.op(base,1,8,amount=1,rm=31);self.assertEqual(state.registers[2],Value('constant',1<<(bits-1)))
            state=self.op(base,8,1,amount=1,rn=31,rm=31);self.assertEqual(state.registers[2],Value('constant',0))
            state=self.op(base,8,1,rd=31);self.assertEqual(state.sp,Value('stack'));self.assertEqual(state.registers[0],Value('constant',8))
    def test_overlap_reads_both_old_sources(self):
        for base,high,low,want in ((BASES[0],0x12345678,0x9abcdef0,0x789abcde),(BASES[1],0x0123456789abcdef,0xfedcba9876543210,0xeffedcba98765432)):
            for rd in (0,1):self.assertEqual(self.op(base,high,low,rd=rd).registers[rd],Value('constant',want))
    def test_both_source_provenance_even_zero_shift_or_discard(self):
        for base in BASES:
            for source in (0,1):
                for amount in (0,8):
                    state=PathState(strict_call_state=True);state.registers[source]=Value('stack')
                    with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,amount,rd=31)))
        state=PathState();state.registers[0]=Value('stack')
        with self.assertRaises(ModelError):state.apply(decode_instruction(word(BASES[1],0)))
    def test_illegal_n_op_controls_and_w_shift_decline_even_dead(self):
        for base in BASES:
            for bits in (1<<22,1<<21,1<<29,1<<30):
                with self.assertRaises(ModelError):decode_instruction(word(base)^bits)
        for amount in (32,63):
            with self.assertRaises(ModelError):decode_instruction(word(BASES[0],amount))
        result=audit_current_function(*fixture((0x14000002,word(BASES[0],32),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
    def test_known_flags_unknown_result_keep_exact_cfg_path(self):
        for base in BASES:
            result=audit_current_function(*fixture((0xd2800020,0x7100041f,word(base,rn=9,rm=10),0x54000060,NOP,0x14000002,NOP,RET),0x02000000))
            self.assertEqual(result.verdict,'agreement');self.assertIn(0x1018,result.checked_pcs);self.assertNotIn(0x1010,result.checked_pcs)
    def test_known_mismatch_unknown_recovery_and_possible_only_witness(self):
        for base in BASES:
            known=check((*PAIR_PRO,0xd2800020,0xd2800061,word(base,0,rd=19),CALL,*PAIR_EPI));self.assertEqual(known.verdict,'inconsistency')
            unknown=check((*PAIR_PRO,word(base,0,rd=19,rn=19,rm=19),CALL,*PAIR_EPI));self.assertEqual(unknown.reason_codes,('unknown_recovery_value',))
            possible=check((*PAIR_PRO,0x54000080,0xd2800020,0xd2800061,word(base,0,rd=19),CALL,*PAIR_EPI));self.assertEqual(possible.reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_unknown_flags_fde_scope_and_frame_guard(self):
        for base in BASES:
            result=audit_current_function(*image_for((*PRO,CALL,word(base),0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
            self.assertEqual(check((*PRO,word(base,rd=29),0x54000040,CALL,*EPI)).reason_codes,('cfg_frame_transition_not_modeled',))
    def test_path_budget_and_carry_select_flag_consumers(self):
        result=audit_current_function(*fixture((word(BASES[1]),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
        state=self.op(BASES[1],1,2,flags=(False,True,True,False));state.registers[0]=Value('constant',2);state.registers[1]=Value('constant',3)
        state.apply(decode_instruction(0x9a010003));self.assertEqual(state.registers[3],Value('constant',6))
        state.apply(decode_instruction(0x9a810004));self.assertEqual(state.registers[4],Value('constant',2))
