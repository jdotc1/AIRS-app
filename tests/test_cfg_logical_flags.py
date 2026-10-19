"""A64 logical flags: literal expected results, no inspected target execution."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI

OPS=(0x6a010002,0x6a210002,0xea010002,0xea210002) # ANDS/BICS W2/X2, W0/X0, W1/X1.
class LogicalFlagTests(unittest.TestCase):
    def run_op(self,word,left,right):
        s=PathState(flags=(True,True,True,True));s.registers[0]=Value('constant',left);s.registers[1]=Value('constant',right)
        s.apply(decode_instruction(word));return s
    def test_ands_width_zero_extension_sign_zero_and_clear_cv(self):
        for op,left,right,want,flags in ((OPS[0],0x180000001,0x180000000,0x80000000,(True,False,False,False)),(OPS[0],7,8,0,(False,True,False,False)),(OPS[2],0x8000000100000001,0x8000000000000001,0x8000000000000001,(True,False,False,False))):
            s=self.run_op(op,left,right);self.assertEqual((s.registers[2],s.flags),(Value('constant',want),flags))
    def test_bics_width_mask_complement_and_clear_cv(self):
        for op,left,right,want,flags in ((OPS[1],0x1ffffffff,0x80000001,0x7ffffffe,(False,False,False,False)),(OPS[1],7,7,0,(False,True,False,False)),(OPS[3],0xffffffffffffffff,0x7ffffffffffffffe,0x8000000000000001,(True,False,False,False))):
            s=self.run_op(op,left,right);self.assertEqual((s.registers[2],s.flags),(Value('constant',want),flags))
    def test_lsl_before_and_or_complement(self):
        for op,want in ((0x6a010402,6),(0x6a210402,0xfffffff9),(0xea010402,6),(0xea210402,0xfffffffffffffff9)):
            s=self.run_op(op,0xffffffffffffffff,3);self.assertEqual(s.registers[2],Value('constant',want))
    def test_lsr_complement_follows_shift(self):
        for op,want in ((0x6a410402,1),(0x6a610402,0xfffffffe),(0xea410402,1),(0xea610402,0xfffffffffffffffe)):
            s=self.run_op(op,0xffffffffffffffff,3);self.assertEqual(s.registers[2],Value('constant',want))
    def test_asr_width_sign_and_complement_after_shift(self):
        for op,right,want in ((0x6a810402,0x180000000,0xc0000000),(0x6aa10402,0x180000000,0x3fffffff),(0xea810402,0x8000000000000000,0xc000000000000000),(0xeaa10402,0x8000000000000000,0x3fffffffffffffff)):
            s=self.run_op(op,0xffffffffffffffff,right);self.assertEqual(s.registers[2],Value('constant',want))
    def test_ror_wraps_low_bit_and_complement_follows_rotation(self):
        for op,want in ((0x6ac10402,0x80000001),(0x6ae10402,0x7ffffffe),(0xeac10402,0x8000000000000001),(0xeae10402,0x7ffffffffffffffe)):
            s=self.run_op(op,0xffffffffffffffff,3);self.assertEqual(s.registers[2],Value('constant',want))
    def test_zero_and_maximum_amount_every_shift_width_and_family(self):
        for op,right,amount,wants,zero in ((OPS[0],0x80000001,31,(0x80000000,1,0xffffffff,3),0x80000001),(OPS[1],0x80000001,31,(0x7fffffff,0xfffffffe,0,0xfffffffc),0x7ffffffe),(OPS[2],0x8000000000000001,63,(0x8000000000000000,1,0xffffffffffffffff,3),0x8000000000000001),(OPS[3],0x8000000000000001,63,(0x7fffffffffffffff,0xfffffffffffffffe,0,0xfffffffffffffffc),0x7ffffffffffffffe)):
            for shift,want in enumerate(wants):
                s=self.run_op(op|(shift<<22)|(amount<<10),0xffffffffffffffff,right);self.assertEqual(s.registers[2],Value('constant',want));self.assertEqual(s.flags[2:],(False,False))
                s=self.run_op(op|(shift<<22),0xffffffffffffffff,right);self.assertEqual(s.registers[2],Value('constant',zero))
    def test_zr_sources_and_discard_destination_tst_alias(self):
        for op in OPS:
            s=self.run_op((op&~(31<<5))|(31<<5),7,3);self.assertEqual((s.registers[2],s.flags),(Value('constant',0),(False,True,False,False)))
            s=self.run_op((op&~(31<<16))|(31<<16),7,3);self.assertEqual(s.registers[2],Value('constant',7 if op in (OPS[1],OPS[3]) else 0))
            s=self.run_op((op&~31)|31,7,3);self.assertEqual(s.registers[0],Value('constant',7));self.assertEqual(s.flags[2:],(False,False))
    def test_overlap_reads_old_sources_and_original_identity_not_invented(self):
        for op in OPS:
            for rd in (0,1):
                s=self.run_op((op&~31)|rd,7,3);self.assertEqual(s.registers[rd],Value('constant',4 if op in (OPS[1],OPS[3]) else 3))
            s=PathState();s.apply(decode_instruction((op&~((31<<16)|(31<<5)|31))|(19<<16)|(19<<5)|19));self.assertFalse(s.registers[19].known);self.assertIsNone(s.flags)
    def test_unknown_operands_even_zero_mask_stay_unknown_and_kill_stale_flags(self):
        for op in OPS:
            for shift in range(4):
                for unknown in (0,1):
                    s=PathState(flags=(False,True,True,True));s.registers[1-unknown]=Value('constant',0)
                    s.apply(decode_instruction(op|(shift<<22)|((31 if op in OPS[:2] else 63)<<10)));self.assertFalse(s.registers[2].known);self.assertIsNone(s.flags)
            s=PathState();s.apply(decode_instruction((op&~(31<<16))|(31<<16)));self.assertFalse(s.registers[2].known);self.assertIsNone(s.flags)
    def test_stack_provenance_checked_before_logical_zero_or_truncation(self):
        for op in OPS:
            for shift in range(4):
                for reg in (0,1):
                    s=PathState(strict_call_state=True);s.registers[reg]=Value('stack');s.registers[1-reg]=Value('constant',0)
                    with self.assertRaises(ModelError):s.apply(decode_instruction(op|(shift<<22)|(1<<10)))
        for op in OPS[2:]:
            s=PathState();s.registers[1]=Value('stack')
            with self.assertRaises(ModelError):s.apply(decode_instruction(op))
    def test_invalid_w_amount_reserved_immediates_and_reserved_carry_decline(self):
        for op in OPS[:2]:
            for shift in range(4):
                for amount in (32,63):
                    with self.assertRaises(ModelError):decode_instruction(op|(shift<<22)|(amount<<10))
        for op in (0x72400002,0xf240fc02,0x0a018002,0x2a018002,0x4a018002,0xba010402,0xfa010402,0x7a410010):
            with self.assertRaises(ModelError):decode_instruction(op)
    def test_known_paths_and_unknown_forks_all_shifts_and_families(self):
        for op in OPS:
            for shift in range(4):
                logical=op|(shift<<22)|(1<<10)
                words=(0x92800000,0xd2800061,logical,0x54000061,NOP,0x14000002,NOP,RET)
                r=audit_current_function(*fixture(words,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertIn(0x1018,r.checked_pcs);self.assertNotIn(0x1010,r.checked_pcs)
                unknown=(0xd2800061,logical,0x54000061,NOP,0x14000002,NOP,RET)
                r=audit_current_function(*fixture(unknown,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_known_vs_possible_saved_pair_witness_all_shifts_and_families(self):
        for op in OPS:
            for shift in range(4):
                logical=op|(shift<<22)|(1<<10)
                known=(*PAIR_PRO,0x92800000,0xd2800061,logical,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
                self.assertEqual(check(known).verdict,'inconsistency')
                unknown=(*PAIR_PRO,0xd2800061,logical,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
                self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_unknown_fde_and_fresh_flags_keep_original_bl_scope(self):
        for op in OPS:
            words=(*PRO,CALL,op|(3<<22)|(1<<10),0x5400004c,NOP,*EPI)
            r=audit_current_function(*image_for(words,CFI));self.assertEqual((r.verdict,r.coverage,r.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(r.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
        words=(*PRO,CALL,0x92800000,0xd2800061,0xea010002,0x54000043,NOP,*EPI) # CC true after logical C=0.
        r=audit_current_function(*image_for(words,CFI));self.assertEqual(r.verdict,'agreement');self.assertTrue(any('1 terminal paths' in e.message for e in r.evidence))
    def test_frame_guard_dead_unsupported_immediate_path_cap_and_csel(self):
        for op in OPS:
            r=check((*PRO,(op&~31)|29,0x5400004c,CALL,*EPI));self.assertEqual(r.reason_codes,('cfg_frame_transition_not_modeled',))
        r=audit_current_function(*fixture((0x14000002,0xf240fc02,NOP,RET),0x02000000));self.assertEqual(r.verdict,'unresolved')
        r=audit_current_function(*fixture((OPS[0],0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(r.reason_codes,('cfg_path_limit',))
        s=self.run_op(OPS[0],1,2);s.apply(decode_instruction(0x1a810043));self.assertEqual(s.registers[3],Value('constant',0))
