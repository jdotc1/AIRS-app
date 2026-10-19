"""Conditional compare flags are gated by incoming condition; no GPR writes."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI

BASES=(0x3a400000,0x3a400800,0x7a400000,0x7a400800,0xba400000,0xba400800,0xfa400000,0xfa400800)
def word(base,rn=0,second=1,nzcv=0,condition=0):
    return base|(second<<16)|(condition<<12)|(rn<<5)|nzcv
class ConditionalCompareTests(unittest.TestCase):
    def op(self,base,left,right=1,flags=(False,True,True,False),nzcv=9,condition=0):
        state=PathState(flags=flags);state.registers[0]=Value('constant',left);state.registers[1]=Value('constant',right)
        state.apply(decode_instruction(word(base,nzcv=nzcv,condition=condition)));return state
    def test_true_register_ccmp_subtraction_flags_both_widths(self):
        for base in (BASES[2],BASES[6]):
            state=self.op(base,0,1);self.assertEqual(state.flags,(True,False,False,False));self.assertEqual(state.registers[0],Value('constant',0))
        for base,left in ((BASES[2],0x80000000),(BASES[6],0x8000000000000000)):
            self.assertEqual(self.op(base,left,1).flags,(False,False,True,True))
    def test_true_register_ccmn_addition_carry_and_overflow(self):
        for base,maximum,signedmax in ((BASES[0],0xffffffff,0x7fffffff),(BASES[4],0xffffffffffffffff,0x7fffffffffffffff)):
            self.assertEqual(self.op(base,maximum,1).flags,(False,True,True,False))
            self.assertEqual(self.op(base,signedmax,1).flags,(True,False,False,True))
    def test_immediate_zero_and31_width_projection(self):
        for base in (BASES[1],BASES[3],BASES[5],BASES[7]):
            for immediate,want in ((0,(False,True,base in (BASES[3],BASES[7]),False)),(31,(base in (BASES[3],BASES[7]),False,False,False))):
                state=PathState(flags=(False,True,True,False));state.registers[0]=Value('constant',0)
                state.apply(decode_instruction(word(base,second=immediate)));self.assertEqual(state.flags,want)
        self.assertEqual(self.op(BASES[2],0x100000001,1).flags,(False,True,True,False))
        self.assertEqual(self.op(BASES[6],0x100000001,1).flags,(False,False,True,False))
    def test_false_predicate_installs_all16_literal_flag_tuples(self):
        expected=((False,False,False,False),(False,False,False,True),(False,False,True,False),(False,False,True,True),(False,True,False,False),(False,True,False,True),(False,True,True,False),(False,True,True,True),(True,False,False,False),(True,False,False,True),(True,False,True,False),(True,False,True,True),(True,True,False,False),(True,True,False,True),(True,True,True,False),(True,True,True,True))
        for base in BASES:
            for literal,want in enumerate(expected):self.assertEqual(self.op(base,0,nzcv=literal,condition=1).flags,want)
    def test_all14_conditions_use_old_nzcv_before_replace(self):
        # N0,Z1,C1,V0. True EQ,HS,PL,VC,LS,GE,LE; others false.
        for base in BASES:
            for condition in range(14):
                state=self.op(base,5,1,nzcv=9,condition=condition)
                trueflags=(False,False,base in (BASES[2],BASES[3],BASES[6],BASES[7]),False)
                self.assertEqual(state.flags,trueflags if condition in (0,2,5,7,9,10,13) else (True,False,False,True))
    def test_true_unknown_either_operand_drops_entire_old_flags(self):
        for base in BASES:
            for source in ((0,1) if not base&(1<<11) else (0,)):
                state=PathState(flags=(False,True,True,False));state.registers[1-source]=Value('constant',1)
                state.apply(decode_instruction(word(base)));self.assertIsNone(state.flags)
    def test_unknown_predicate_remains_unknown_even_equal_alternatives(self):
        for base in BASES:
            state=self.op(base,0,0,flags=None,nzcv=6);self.assertIsNone(state.flags)
        state=PathState();state.apply(decode_instruction(word(BASES[2],rn=31,second=31,nzcv=6)));self.assertIsNone(state.flags)
    def test_false_predicate_skips_unknown_and_stack_sources(self):
        for base in BASES:
            state=PathState(flags=(False,True,True,False),strict_call_state=True);state.registers[0]=Value('stack');state.registers[1]=Value('stack')
            state.apply(decode_instruction(word(base,nzcv=10,condition=1)));self.assertEqual(state.flags,(True,False,True,False))
    def test_true_or_unknown_predicate_keeps_both_source_provenance_guard(self):
        for base in BASES:
            for flags in (None,(False,True,True,False)):
                for source in ((0,1) if not base&(1<<11) else (0,)):
                    state=PathState(flags=flags,strict_call_state=True);state.registers[source]=Value('stack')
                    with self.assertRaises(ModelError):state.apply(decode_instruction(word(base)))
    def test_zr_fields_and_no_register_or_sp_memory_writes(self):
        for base in BASES:
            state=PathState(flags=(False,True,True,False));before=state.registers.copy();sp=state.sp
            ins=decode_instruction(word(base,rn=31,second=31));state.apply(ins)
            want=(True,False,False,False) if base in (BASES[3],BASES[7]) else ((False,True,True,False) if base in (BASES[2],BASES[6]) else ((False,False,False,False) if base&(1<<11) else (False,True,False,False)))
            self.assertEqual(state.flags,want);self.assertEqual(state.registers,before);self.assertEqual(state.sp,sp);self.assertEqual(state.memory,{})
    def test_reserved_bits_al_nv_and_dead_reserved_instructions_decline(self):
        for base in BASES:
            for bits in (1<<4,1<<10,1<<21):
                with self.assertRaises(ModelError):decode_instruction(word(base)|bits)
            for condition in (14,15):
                with self.assertRaises(ModelError):decode_instruction(word(base,condition=condition))
        result=audit_current_function(*fixture((0x14000002,word(BASES[2])|(1<<4),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
    def test_chained_compare_csel_and_carry_consume_new_or_fallback_flags(self):
        state=self.op(BASES[2],1,1);self.assertEqual(state.flags,(False,True,True,False))
        state.apply(decode_instruction(word(BASES[0],nzcv=9,condition=1)));self.assertEqual(state.flags,(True,False,False,True))
        state.registers[0]=Value('constant',5);state.registers[1]=Value('constant',3)
        state.apply(decode_instruction(0x9a010002));self.assertEqual(state.registers[2],Value('constant',8))
        state.apply(decode_instruction(0x1a814003));self.assertEqual(state.registers[3],Value('constant',5))
    def test_true_and_false_predicates_select_known_cfg_paths(self):
        for base in BASES:
            for condition in (0,1):
                words=(0x92800000,0xd2800021,0xd2800023,0x7100047f,word(base,nzcv=2,condition=condition),0x54000062,NOP,0x14000002,NOP,RET)
                result=audit_current_function(*fixture(words,0x02000000));self.assertEqual(result.verdict,'agreement');self.assertIn(0x1020,result.checked_pcs);self.assertNotIn(0x1018,result.checked_pcs)
    def test_known_and_possible_only_saved_pair_witnesses(self):
        for base in BASES:
            known=(*PAIR_PRO,0x92800000,0xd2800021,0xd2800023,0x7100047f,word(base,nzcv=2),0x54000063,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(known).verdict,'inconsistency')
            unknown=(*PAIR_PRO,word(base,nzcv=2),0x54000060,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_unknown_predicate_keeps_fde_scope_at_original_bl(self):
        for base in BASES:
            result=audit_current_function(*image_for((*PRO,CALL,word(base,nzcv=2),0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
    def test_source_x29_does_not_become_fake_destination_and_caps_hold(self):
        for base in BASES:
            result=check((*PRO,0xd2800023,0x7100047f,word(base,rn=29,nzcv=2,condition=1),0x54000042,NOP,CALL,*EPI));self.assertEqual(result.verdict,'agreement')
        result=audit_current_function(*fixture((word(BASES[0]),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
