"""Nonflag logical immediates must preserve flags and caller identity boundaries."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI
from test_cfg_logical_immediate import word

BASES=(0x12000000,0x32000000,0x52000000,0x92000000,0xb2000000,0xd2000000)
class NonflagImmediateTests(unittest.TestCase):
    def run_op(self,op,value,flags=(True,False,True,True)):
        state=PathState(flags=flags);state.registers[0]=Value('constant',value)
        state.apply(decode_instruction(op));return state
    def test_w_and_orr_eor_mask_and_zero_extension(self):
        for base,want in ((BASES[0],0x00ff00ff),(BASES[1],0xffff00ff),(BASES[2],0xff000000)):
            state=self.run_op(word(base,0,39,0),0x1ffff00ff);self.assertEqual(state.registers[2],Value('constant',want)) # mask00ff00ff
    def test_x_and_orr_eor_full_width_and_rotated_mask(self):
        for base,want in ((BASES[3],0xf00000000000000f),(BASES[4],0xffffffffffffffff),(BASES[5],0x0ffffffffffffff0)):
            state=self.run_op(word(base,1,7,4),0xffffffffffffffff);self.assertEqual(state.registers[2],Value('constant',want))
    def test_each_family_uses_repeated_masks_and_ignored_rotation_bits(self):
        for base,want in ((BASES[0],0x55555555),(BASES[1],0x55555555),(BASES[2],0x55555555),(BASES[3],0x5555555555555555),(BASES[4],0x5555555555555555),(BASES[5],0x5555555555555555)):
            self.assertEqual(decode_instruction(word(base,0,60,62)).immediate,want)
    def test_known_nzcv_and_none_preserved_for_concrete_results(self):
        for flags in (None,(True,False,True,False),(False,True,False,True),(True,True,True,True),(False,False,False,False)):
            for base in BASES:
                state=self.run_op(word(base,0,60,0),3,flags);self.assertEqual(state.flags,flags)
    def test_unknown_results_preserve_flags_and_do_not_invent_original_identity(self):
        for flags in (None,(True,False,True,True),(False,True,False,False)):
            for base in BASES:
                state=PathState(flags=flags);state.apply(decode_instruction(word(base,0,60,0,rd=19,rn=19)))
                self.assertFalse(state.registers[19].known);self.assertEqual(state.flags,flags)
    def test_zr_source_bitmask_mov_alias_and_different_destination31_semantics(self):
        for index,base in enumerate(BASES):
            state=self.run_op(word(base,0,60,0,rn=31),99)
            want=0 if index in (0,3) else (0x55555555 if index<3 else 0x5555555555555555)
            self.assertEqual(state.registers[2],Value('constant',want))
            for rn in (0,31):
                with self.assertRaises(ModelError):decode_instruction(word(base,0,60,0,rd=31,rn=rn))
        state=self.run_op(word(0xf2000000,1,0,0,rd=31),3);self.assertEqual(state.registers[0],Value('constant',3));self.assertEqual(state.flags,(False,False,False,False))
    def test_reserved_masks_decline_for_every_new_opcode(self):
        for base in BASES:
            for s in (31,47,55,59,61,62,63):
                with self.assertRaises(ModelError):decode_instruction(word(base,0,s,0))
            if base in BASES[:3]:
                with self.assertRaises(ModelError):decode_instruction(word(base,1,0,0))
            else:
                with self.assertRaises(ModelError):decode_instruction(word(base,1,63,0))
    def test_overlap_reads_old_source_and_preserves_flags(self):
        for index,base in enumerate(BASES):
            state=self.run_op(word(base,0,0,0,rd=0),2)
            want=(0,3,3,0,0x100000003,0x100000003)[index] # X N0 mask0000000100000001.
            self.assertEqual(state.registers[0],Value('constant',want));self.assertEqual(state.flags,(True,False,True,True))
    def test_provenance_checked_before_nonflag_bit_operations(self):
        for base in BASES:
            state=PathState(strict_call_state=True);state.registers[0]=Value('stack')
            with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,0,0,0)))
        for base in BASES[3:]:
            state=PathState();state.registers[0]=Value('stack')
            with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,0,0,0)))
    def test_known_comparison_flags_survive_unknown_result_and_select_exact_cfg_path(self):
        for base in BASES:
            # W8−7 establishes Z=0,C=1,V=0. SourceX9 is unknown; result flags must stay.
            op=word(base,0,60,0,rn=9)
            words=(0xd2800100,0x71001c1f,op,0x54000062,NOP,0x14000002,NOP,RET)
            result=audit_current_function(*fixture(words,0x02000000));self.assertEqual(result.verdict,'agreement');self.assertIn(0x1018,result.checked_pcs);self.assertNotIn(0x1010,result.checked_pcs)
    def test_entry_unknown_flags_fork_despite_concrete_mov_bitmask(self):
        for base in BASES:
            op=word(base,0,60,0,rn=31)
            result=audit_current_function(*fixture((op,0x54000060,NOP,0x14000002,NOP,RET),0x02000000));self.assertEqual(result.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
    def test_known_vs_possible_saved_pair_witness_preserves_flag_feasibility(self):
        for base in BASES:
            op=word(base,0,60,0,rn=9)
            known=(*PAIR_PRO,0xd2800100,0x71001c1f,op,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(known).verdict,'inconsistency')
            unknown=(*PAIR_PRO,op,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_fde_unknown_flags_and_fresh_compare_scope(self):
        for base in BASES:
            words=(*PRO,CALL,word(base,0,60,0,rn=31),0x54000040,NOP,*EPI)
            result=audit_current_function(*image_for(words,CFI));self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
        words=(*PRO,CALL,0xd2800100,0x71001c1f,word(BASES[4],0,60,0,rn=31),0x54000042,NOP,*EPI)
        result=audit_current_function(*image_for(words,CFI));self.assertEqual(result.verdict,'agreement');self.assertTrue(any('1 terminal paths' in e.message for e in result.evidence))
    def test_frame_guard_dead_reserved_mask_and_path_cap(self):
        for base in BASES:
            result=check((*PRO,word(base,0,60,0,rd=29),0x54000040,CALL,*EPI));self.assertEqual(result.reason_codes,('cfg_frame_transition_not_modeled',))
        result=audit_current_function(*fixture((0x14000002,word(BASES[4],1,63,0),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
        result=audit_current_function(*fixture((word(BASES[4],0,60,0,rn=31),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
    def test_csel_consumes_preserved_flags_after_unknown_nonflag_result(self):
        for base in BASES:
            state=PathState(flags=(False,True,True,False));state.registers[1]=Value('constant',9);state.registers[2]=Value('constant',7)
            state.apply(decode_instruction(word(base,0,60,0,rd=4,rn=9)))
            state.apply(decode_instruction(0x1a810043));self.assertEqual(state.registers[3],Value('constant',7));self.assertEqual(state.flags,(False,True,True,False))
