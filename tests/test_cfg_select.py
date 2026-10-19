"""Additional conditional selects: width, false transforms and recovery identity."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI
from test_cfg_conditions import TRUE_ROWS
BASES=(0x1a800000,0x1a800400,0x5a800000,0x5a800400,0x9a800000,0x9a800400,0xda800000,0xda800400)
def word(base,rd=2,rn=0,rm=1,condition=0):return base|(rm<<16)|(condition<<12)|(rn<<5)|rd
class SelectTests(unittest.TestCase):
    def op(self,base,left,right,flags=(False,True,True,False),condition=0,rd=2):
        state=PathState(flags=flags);state.registers[0]=Value('constant',left);state.registers[1]=Value('constant',right)
        state.apply(decode_instruction(word(base,rd=rd,condition=condition)));return state
    def test_true_and_false_every_form_width_preserve_flags(self):
        wants=(3,4,0xfffffffc,0xfffffffd,3,4,0xfffffffffffffffc,0xfffffffffffffffd)
        for index,base in enumerate(BASES):
            for condition,want in ((0,5),(1,wants[index])):
                state=self.op(base,5,3,condition=condition);self.assertEqual(state.registers[2],Value('constant',want));self.assertEqual(state.flags,(False,True,True,False))
    def test_all14_predicates_all16_nzcv_rows(self):
        for bits,truth in enumerate(TRUE_ROWS):
            flags=tuple(bool(bits&bit) for bit in (8,4,2,1))
            for index,base in enumerate(BASES):
                false=(3,4,0xfffffffc,0xfffffffd,3,4,0xfffffffffffffffc,0xfffffffffffffffd)[index]
                for condition in range(14):
                    state=self.op(base,5,3,flags,condition);self.assertEqual(state.registers[2],Value('constant',5 if condition in truth else false));self.assertEqual(state.flags,flags)
    def test_false_transform_wrap_and_signed_min_negation(self):
        for base,value,want in ((BASES[1],0xffffffff,0),(BASES[5],0xffffffffffffffff,0),(BASES[2],0,0xffffffff),(BASES[6],0,0xffffffffffffffff),(BASES[3],0x80000000,0x80000000),(BASES[7],0x8000000000000000,0x8000000000000000),(BASES[3],0,0),(BASES[7],0,0)):
            self.assertEqual(self.op(base,5,value,condition=1).registers[2],Value('constant',want))
        self.assertEqual(self.op(BASES[0],0x100000005,0).registers[2],Value('constant',5))
        self.assertEqual(self.op(BASES[4],0x100000005,0).registers[2],Value('constant',0x100000005))
        self.assertEqual(self.op(BASES[4],0x10000000000000005,0).registers[2],Value('constant',5))
    def test_unknown_predicate_compares_transformed_not_raw_alternatives(self):
        for index,base in enumerate(BASES):
            right=(7,6,0xfffffff8,0xfffffff9,7,6,0xfffffffffffffff8,0xfffffffffffffff9)[index]
            state=self.op(base,7,right,flags=None);self.assertEqual(state.registers[2],Value('constant',7));self.assertIsNone(state.flags)
            state=self.op(base,7,7,flags=None);self.assertEqual(state.registers[2].kind,'constant' if index%4==0 else 'unknown')
    def test_unknown_false_source_does_not_poison_known_true_selection(self):
        for base in BASES:
            state=PathState(flags=(False,True,True,False));state.registers[0]=Value('constant',5)
            state.apply(decode_instruction(word(base)));self.assertEqual(state.registers[2],Value('constant',5));self.assertEqual(state.flags,(False,True,True,False))
    def test_unknown_transformed_identity_is_not_recreated(self):
        for base in BASES[1:4]+BASES[5:]:
            state=PathState(flags=(False,True,True,False));state.apply(decode_instruction(word(base,rn=19,rm=19,condition=1)))
            self.assertFalse(state.registers[2].known)
        for base in BASES:
            state=PathState();state.apply(decode_instruction(word(base,rn=19,rm=20)));self.assertFalse(state.registers[2].known)
    def test_x_original_identity_retained_only_untransformed_selected_or_equal(self):
        for base in BASES[4:]:
            state=PathState(flags=(False,True,True,False));state.apply(decode_instruction(word(base,rn=19,rm=20)))
            self.assertEqual(state.registers[2],Value('original',19))
        state=PathState();state.apply(decode_instruction(word(BASES[4],rn=19,rm=19)));self.assertEqual(state.registers[2],Value('original',19))
        for base in BASES[:4]:
            state=PathState(flags=(False,True,True,False));state.apply(decode_instruction(word(base,rn=19,rm=19)));self.assertFalse(state.registers[2].known)
    def test_zr_and_inverted_condition_aliases(self):
        for base,want in ((BASES[1],1),(BASES[5],1),(BASES[2],0xffffffff),(BASES[6],0xffffffffffffffff)):
            state=PathState(flags=(False,True,True,False));state.apply(decode_instruction(word(base,rn=31,rm=31,condition=1)));self.assertEqual(state.registers[2],Value('constant',want))
        for base,want in ((BASES[5],6),(BASES[6],0xfffffffffffffffa),(BASES[7],0xfffffffffffffffb)):
            state=self.op(base,5,99,condition=0);state.apply(decode_instruction(word(base,rn=0,rm=0,condition=1)));self.assertEqual(state.registers[2],Value('constant',want))
        for base in BASES:
            state=self.op(base,5,3,rd=31);self.assertEqual(state.sp,Value('stack'));self.assertEqual(state.registers[0],Value('constant',5))
    def test_overlap_uses_old_sources(self):
        for index,base in enumerate(BASES):
            for rd in (0,1):
                state=self.op(base,5,3,condition=1,rd=rd);self.assertEqual(state.registers[rd],Value('constant',(3,4,0xfffffffc,0xfffffffd,3,4,0xfffffffffffffffc,0xfffffffffffffffd)[index]))
    def test_both_source_provenance_guard_even_unselected_or_discarded(self):
        for base in BASES:
            for source in (0,1):
                state=PathState(flags=(False,True,True,False),strict_call_state=True);state.registers[source]=Value('stack')
                with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,rd=31)))
        for base in BASES[4:]:
            state=PathState();state.registers[1]=Value('stack')
            with self.assertRaises(ModelError):state.apply(decode_instruction(word(base)))
    def test_reserved_bit11_sbit_and_al_nv_decline_even_dead(self):
        for base in BASES:
            for bits in (1<<11,1<<29):
                with self.assertRaises(ModelError):decode_instruction(word(base)|bits)
            for condition in (14,15):
                with self.assertRaises(ModelError):decode_instruction(word(base,condition=condition))
        result=audit_current_function(*fixture((0x14000002,word(BASES[5])|(1<<11),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
    def test_preserved_flags_select_exact_cfg_path_each_form(self):
        for base in BASES:
            result=audit_current_function(*fixture((0xd2800020,0xd2800061,0x7100041f,word(base,condition=1),0x54000060,NOP,0x14000002,NOP,RET),0x02000000))
            self.assertEqual(result.verdict,'agreement');self.assertIn(0x101c,result.checked_pcs);self.assertNotIn(0x1014,result.checked_pcs)
    def test_known_selected_constant_mismatch_and_unknown_recovery_precedence(self):
        for base in BASES:
            known=check((*PAIR_PRO,0xd2800020,0xd2800061,0x7100041f,word(base,rd=19),CALL,*PAIR_EPI));self.assertEqual(known.verdict,'inconsistency')
            unknown=check((*PAIR_PRO,word(base,rd=19,rn=19,rm=20),CALL,*PAIR_EPI));self.assertEqual(unknown.reason_codes,('unknown_recovery_value',))
    def test_possible_only_cfg_witness_stays_unresolved(self):
        for base in BASES:
            result=check((*PAIR_PRO,0x54000080,0xd2800020,0x7100041f,word(base,rd=19,rn=0,rm=0),CALL,*PAIR_EPI))
            self.assertEqual(result.reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_unknown_select_keeps_fde_scope_at_original_bl(self):
        for base in BASES:
            result=audit_current_function(*image_for((*PRO,CALL,word(base),0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
    def test_frame_guard_all_forms_and_path_budget(self):
        for base in BASES:self.assertEqual(check((*PRO,word(base,rd=29),0x54000040,CALL,*EPI)).reason_codes,('cfg_frame_transition_not_modeled',))
        result=audit_current_function(*fixture((word(BASES[5]),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
