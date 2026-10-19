"""Fixed bitmask expectations and recovery witnesses; no exhaustive corpus pass."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI

def word(base,n,s,r,rd=2,rn=0):
    # Independent field placement only; expectations are literal masks below.
    return base|(n<<22)|(r<<16)|(s<<10)|(rn<<5)|rd

class LogicalImmediateTests(unittest.TestCase):
    def run_op(self,op,value):
        state=PathState(flags=(True,True,True,True));state.registers[0]=Value('constant',value)
        state.apply(decode_instruction(op));return state
    def test_w_repeated_elements_2_4_8_16_32(self):
        for n,s,r,want in ((0,60,0,0x55555555),(0,60,1,0xaaaaaaaa),(0,56,0,0x11111111),(0,58,1,0xbbbbbbbb),(0,48,0,0x01010101),(0,51,4,0xf0f0f0f0),(0,32,0,0x00010001),(0,39,8,0xff00ff00),(0,0,0,1),(0,15,16,0xffff0000)):
            self.assertEqual(decode_instruction(word(0x72000000,n,s,r)).immediate,want)
    def test_x_repeated_elements_and_full_width(self):
        for n,s,r,want in ((0,60,0,0x5555555555555555),(0,60,1,0xaaaaaaaaaaaaaaaa),(0,56,0,0x1111111111111111),(0,58,1,0xbbbbbbbbbbbbbbbb),(0,48,0,0x0101010101010101),(0,51,4,0xf0f0f0f0f0f0f0f0),(0,32,0,0x0001000100010001),(0,39,8,0xff00ff00ff00ff00),(0,0,0,0x0000000100000001),(0,15,16,0xffff0000ffff0000),(1,0,0,1),(1,7,4,0xf00000000000000f)):
            self.assertEqual(decode_instruction(word(0xf2000000,n,s,r)).immediate,want)
    def test_max_rotations_and_longest_legal_runs(self):
        for base,n,s,r,want in ((0x72000000,0,60,1,0xaaaaaaaa),(0x72000000,0,58,3,0xeeeeeeee),(0x72000000,0,54,7,0xfefefefe),(0x72000000,0,46,15,0xfffefffe),(0x72000000,0,30,31,0xfffffffe),(0xf2000000,1,0,63,2),(0xf2000000,1,62,1,0xbfffffffffffffff)):
            self.assertEqual(decode_instruction(word(base,n,s,r)).immediate,want)
    def test_high_rotation_bits_are_ignored_for_small_elements(self):
        for base,want in ((0x72000000,0x55555555),(0xf2000000,0x5555555555555555)):
            self.assertEqual(decode_instruction(word(base,0,60,62)).immediate,want)
    def test_reserved_n_length_and_all_ones_codes_decline(self):
        for n,s in ((1,0),(1,15),(1,63)):
            with self.assertRaises(ModelError):decode_instruction(word(0x72000000,n,s,0))
        for base in (0x72000000,0xf2000000):
            for s in (31,47,55,59,61,62,63):
                with self.assertRaises(ModelError):decode_instruction(word(base,0,s,0))
        with self.assertRaises(ModelError):decode_instruction(word(0xf2000000,1,63,0))
    def test_reserved_nonflag_masks_and_fixed_bits_decline(self):
        for op in (0x12400002,0x9240fc02,0x32400002,0xb240fc02,0x52400002,0xd240fc02,0x72800002,0xf2800002):
            with self.assertRaises(ModelError):decode_instruction(op)
    def test_concrete_flags_zero_extension_and_cv_reset(self):
        for op,source,want,flags in ((word(0x72000000,0,15,16),0x1ffffffff,0xffff0000,(True,False,False,False)),(word(0x72000000,0,0,0),2,0,(False,True,False,False)),(word(0xf2000000,1,7,4),0xffffffffffffffff,0xf00000000000000f,(True,False,False,False))):
            state=self.run_op(op,source);self.assertEqual((state.registers[2],state.flags),(Value('constant',want),flags))
    def test_zr_source_and_tst_discard_destination(self):
        for base,n in ((0x72000000,0),(0xf2000000,1)):
            state=self.run_op(word(base,n,0,0,rn=31),99);self.assertEqual((state.registers[2],state.flags),(Value('constant',0),(False,True,False,False)))
            state=self.run_op(word(base,n,0,0,rd=31),3);self.assertEqual(state.registers[0],Value('constant',3));self.assertEqual(state.flags,(False,False,False,False))
    def test_unknown_source_clears_stale_flags_and_original_identity(self):
        for base,n in ((0x72000000,0),(0xf2000000,1)):
            state=PathState(flags=(True,True,True,True));state.apply(decode_instruction(word(base,n,0,0,rd=19,rn=19)));self.assertFalse(state.registers[19].known);self.assertIsNone(state.flags)
    def test_stack_provenance_precedes_immediate_mask(self):
        for base,n in ((0x72000000,0),(0xf2000000,1)):
            state=PathState(strict_call_state=True);state.registers[0]=Value('stack')
            with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,n,0,0)))
        state=PathState();state.registers[0]=Value('stack')
        with self.assertRaises(ModelError):state.apply(decode_instruction(word(0xf2000000,1,0,0)))
    def test_source_destination_overlap_uses_old_source(self):
        for base,n in ((0x72000000,0),(0xf2000000,1)):
            state=self.run_op(word(base,n,0,0,rd=0),3);self.assertEqual(state.registers[0],Value('constant',1))
    def test_known_paths_and_unknown_forks_for_repeated_and_rotated_masks(self):
        for op in (word(0x72000000,0,60,0),word(0x72000000,0,51,4),word(0xf2000000,0,39,8),word(0xf2000000,1,7,4)):
            words=(0x92800000,op,0x54000061,NOP,0x14000002,NOP,RET)
            result=audit_current_function(*fixture(words,0x02000000));self.assertEqual(result.verdict,'agreement');self.assertIn(0x1014,result.checked_pcs);self.assertNotIn(0x100c,result.checked_pcs)
            unknown=(op,0x54000061,NOP,0x14000002,NOP,RET)
            result=audit_current_function(*fixture(unknown,0x02000000));self.assertEqual(result.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
    def test_known_vs_possible_saved_pair_witness_for_w_and_x_masks(self):
        for op in (word(0x72000000,0,51,4),word(0xf2000000,1,7,4)):
            known=(*PAIR_PRO,0x92800000,op,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(known).verdict,'inconsistency')
            unknown=(*PAIR_PRO,op,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_fde_unknown_and_fresh_flags_keep_original_bl_scope(self):
        for op in (word(0x72000000,0,60,0),word(0xf2000000,1,7,4)):
            words=(*PRO,CALL,op,0x54000040,NOP,*EPI)
            result=audit_current_function(*image_for(words,CFI));self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
        words=(*PRO,CALL,0x92800000,word(0xf2000000,1,7,4),0x54000043,NOP,*EPI)
        result=audit_current_function(*image_for(words,CFI));self.assertEqual(result.verdict,'agreement');self.assertTrue(any('1 terminal paths' in e.message for e in result.evidence))
    def test_frame_guard_dead_reserved_encoding_path_cap_and_csel(self):
        for base,n in ((0x72000000,0),(0xf2000000,1)):
            result=check((*PRO,word(base,n,0,0,rd=29),0x54000040,CALL,*EPI));self.assertEqual(result.reason_codes,('cfg_frame_transition_not_modeled',))
        result=audit_current_function(*fixture((0x14000002,word(0xf2000000,1,63,0),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
        result=audit_current_function(*fixture((word(0x72000000,0,60,0),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
        state=self.run_op(word(0x72000000,0,0,0),2);state.registers[1]=Value('constant',9);state.apply(decode_instruction(0x1a810043));self.assertEqual(state.registers[3],Value('constant',0))
