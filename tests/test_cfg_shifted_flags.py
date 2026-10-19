"""Literal shifted operands and concrete recovery witnesses, without target execution."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_register_flags import OPS
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI

class ShiftedFlagTests(unittest.TestCase):
    def run_op(self,word,left,right):
        s=PathState();s.registers[0]=Value('constant',left);s.registers[1]=Value('constant',right)
        s.apply(decode_instruction(word));return s
    def test_lsl_shifted_operand_sets_width_correct_add_sub_overflow(self):
        for op,left,want,flags in ((0x2b010402,0x7ffffffe,0x80000000,(True,False,False,True)),(0x6b010402,0x80000001,0x7fffffff,(False,False,True,True)),(0xab010402,0x7ffffffffffffffe,0x8000000000000000,(True,False,False,True)),(0xeb010402,0x8000000000000001,0x7fffffffffffffff,(False,False,True,True))):
            s=self.run_op(op,left,1);self.assertEqual((s.registers[2],s.flags),(Value('constant',want),flags))
    def test_lsr_shifted_operand_sets_arithmetic_carry_and_borrow(self):
        for op,left,want,flags in ((0x2b410402,0xffffffff,0,(False,True,True,False)),(0x6b410402,0,0xffffffff,(True,False,False,False)),(0xab410402,0xffffffffffffffff,0,(False,True,True,False)),(0xeb410402,0,0xffffffffffffffff,(True,False,False,False))):
            s=self.run_op(op,left,3);self.assertEqual((s.registers[2],s.flags),(Value('constant',want),flags))
    def test_asr_sign_extends_second_operand_before_arithmetic(self):
        for op,left,right,want,flags in ((0x2b810402,0x40000000,0x80000000,0,(False,True,True,False)),(0x6b810402,0,0x80000000,0x40000000,(False,False,False,False)),(0xab810402,0x4000000000000000,0x8000000000000000,0,(False,True,True,False)),(0xeb810402,0,0x8000000000000000,0x4000000000000000,(False,False,False,False))):
            s=self.run_op(op,left,right);self.assertEqual((s.registers[2],s.flags),(Value('constant',want),flags))
    def test_w_operand_is_truncated_before_lsr_and_asr(self):
        for op,want in ((0x2b410402,0x40000000),(0x2b810402,0xc0000000)):
            s=self.run_op(op,0,0x180000000);self.assertEqual(s.registers[2],Value('constant',want))
    def test_zero_amount_for_every_shift_and_arithmetic_family(self):
        for op in OPS:
            for shift in (0,1,2):
                s=self.run_op(op|(shift<<22),5,7)
                want=12 if op in (OPS[0],OPS[2]) else (0xfffffffe if op==OPS[1] else 0xfffffffffffffffe)
                self.assertEqual(s.registers[2],Value('constant',want))
    def test_maximum_shift_for_each_type_and_width(self):
        for base,right,amount,wants in ((0x2b010002,0x80000001,31,(0x80000000,1,0xffffffff)),(0xab010002,0x8000000000000001,63,(0x8000000000000000,1,0xffffffffffffffff))):
            for shift,want in enumerate(wants):
                s=self.run_op(base|(shift<<22)|(amount<<10),0,right);self.assertEqual(s.registers[2],Value('constant',want))
    def test_carry_is_from_arithmetic_not_shifted_out_bit(self):
        for op in OPS:
            for shift,right in ((1,1),(0,0x80000000 if op in OPS[:2] else 0x8000000000000000)):
                s=self.run_op(op|(shift<<22)|(1<<10),0,right)
                self.assertEqual((s.registers[2],s.flags),(Value('constant',0),(False,True,op in (OPS[1],OPS[3]),False)))
    def test_zr_aliases_and_destination_source_overlap(self):
        for op in OPS:
            for shift in (0,1,2):
                word=op|(shift<<22)|(1<<10)
                s=self.run_op((word&~(31<<16))|(31<<16),7,99);self.assertEqual(s.registers[2],Value('constant',7))
                s=self.run_op((word&~31)|31,7,2);self.assertEqual(s.registers[0],Value('constant',7));self.assertIsNotNone(s.flags)
                s=self.run_op((word&~31)|1,7,2);self.assertNotEqual(s.registers[1],Value('constant',2))
    def test_unknown_either_operand_at_max_shift_clears_stale_flags(self):
        for op in OPS:
            amount=31 if op in OPS[:2] else 63
            for shift in (0,1,2):
                for unknown in (0,1):
                    s=PathState(flags=(False,True,True,False));s.registers[1-unknown]=Value('constant',0)
                    s.apply(decode_instruction(op|(shift<<22)|(amount<<10)));self.assertFalse(s.registers[2].known);self.assertIsNone(s.flags)
    def test_stack_provenance_is_checked_before_shift_even_if_bits_disappear(self):
        for op in OPS:
            amount=31 if op in OPS[:2] else 63
            for shift in (0,1,2):
                for reg in (0,1):
                    s=PathState(strict_call_state=True);s.registers[reg]=Value('stack');s.registers[1-reg]=Value('constant',0)
                    with self.assertRaises(ModelError):s.apply(decode_instruction(op|(shift<<22)|(amount<<10)))
    def test_reserved_shift_w_out_of_range_extended_and_other_families_decline(self):
        for op in OPS:
            for bits in (3<<22,(1<<21)|(5<<10)):
                with self.assertRaises(ModelError):decode_instruction(op|bits)
        for op in OPS[:2]:
            for shift in (0,1,2):
                for amount in (32,63):
                    with self.assertRaises(ModelError):decode_instruction(op|(shift<<22)|(amount<<10))
        for op in (0xba010402,0xfa010402,0xf240fc02,0x7a410010):
            with self.assertRaises(ModelError):decode_instruction(op)
    def test_known_and_unknown_cfg_paths_for_all_shift_types(self):
        for op in OPS:
            for shift,movright in ((0,0xd2800021),(1,0xd2800081),(2,0xd2800081)):
                shifted=op|(shift<<22)|(1<<10)
                words=(0xd2800000,movright,shifted,0x54000061,NOP,0x14000002,NOP,RET) # NE always true for these concrete operands.
                r=audit_current_function(*fixture(words,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertIn(0x1018,r.checked_pcs);self.assertNotIn(0x1010,r.checked_pcs)
                unknown=(movright,shifted,0x54000061,NOP,0x14000002,NOP,RET)
                r=audit_current_function(*fixture(unknown,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_known_vs_possible_only_saved_pair_mismatch_each_shift_family(self):
        for op in OPS:
            for shift,right in ((0,0xd2800021),(1,0xd2800081),(2,0xd2800081)):
                shifted=op|(shift<<22)|(1<<10)
                known=(*PAIR_PRO,0xd2800000,right,shifted,0x54000060,0xd28000f3,CALL,*PAIR_EPI) # EQ false; concrete bad state reaches call.
                self.assertEqual(check(known).verdict,'inconsistency')
                unknown=(*PAIR_PRO,right,shifted,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
                self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
    def test_fde_postcall_unknown_shifts_retain_original_bl_scope(self):
        for op in OPS:
            for shift in (0,1,2):
                words=(*PRO,CALL,op|(shift<<22)|(1<<10),0x5400004c,NOP,*EPI)
                r=audit_current_function(*image_for(words,CFI));self.assertEqual((r.verdict,r.coverage,r.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(r.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_frame_guard_dead_reserved_encoding_and_path_cap(self):
        for op in OPS:
            for shift in (0,1,2):
                r=check((*PRO,(op&~31)|29|(shift<<22)|(1<<10),0x5400004c,CALL,*EPI));self.assertEqual(r.reason_codes,('cfg_frame_transition_not_modeled',))
        r=audit_current_function(*fixture((0x14000002,OPS[0]|(3<<22),NOP,RET),0x02000000));self.assertEqual(r.verdict,'unresolved')
        words=(0x2b410402,0x54000060,NOP,0x14000002,NOP,RET)
        r=audit_current_function(*fixture(words,0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(r.reason_codes,('cfg_path_limit',))
