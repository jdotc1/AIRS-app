"""Literal unshifted register flag producers and independent recovery witnesses."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI

# ADDS/SUBS W2 or X2, W0/X0, W1/X1. No encoder under test.
OPS=(0x2b010002,0x6b010002,0xab010002,0xeb010002)
class RegisterFlagTests(unittest.TestCase):
    def run_op(self,word,left,right):
        s=PathState();s.registers[0]=Value('constant',left);s.registers[1]=Value('constant',right)
        s.apply(decode_instruction(word));return s
    def test_w_adds_reads_both_registers_and_zero_extends(self):
        for a,b,result,flags in ((0xffffffff,1,0,(False,True,True,False)),(0x7ffffffe,2,0x80000000,(True,False,False,True)),(0x100000000,0x100000003,3,(False,False,False,False))):
            s=self.run_op(OPS[0],a,b);self.assertEqual((s.registers[2],s.flags),(Value('constant',result),flags))
    def test_w_subs_borrow_overflow_and_low32(self):
        for a,b,result,flags in ((0,2,0xfffffffe,(True,False,False,False)),(0x80000001,2,0x7fffffff,(False,False,True,True)),(0x100000003,0x100000003,0,(False,True,True,False))):
            s=self.run_op(OPS[1],a,b);self.assertEqual((s.registers[2],s.flags),(Value('constant',result),flags))
    def test_x_adds_full_width_carry_and_signed_overflow(self):
        for a,b,result,flags in ((0xffffffffffffffff,1,0,(False,True,True,False)),(0x7ffffffffffffffe,2,0x8000000000000000,(True,False,False,True)),(0xffffffff,2,0x100000001,(False,False,False,False))):
            s=self.run_op(OPS[2],a,b);self.assertEqual((s.registers[2],s.flags),(Value('constant',result),flags))
    def test_x_subs_full_width_borrow_and_signed_overflow(self):
        for a,b,result,flags in ((0,2,0xfffffffffffffffe,(True,False,False,False)),(0x8000000000000001,2,0x7fffffffffffffff,(False,False,True,True)),(0x100000003,2,0x100000001,(False,False,True,False))):
            s=self.run_op(OPS[3],a,b);self.assertEqual((s.registers[2],s.flags),(Value('constant',result),flags))
    def test_each_unknown_operand_kills_stale_flags_and_result(self):
        for op in OPS:
            for unknown in (0,1):
                s=PathState(flags=(False,True,True,False));s.registers[1-unknown]=Value('constant',7)
                s.apply(decode_instruction(op));self.assertIsNone(s.flags);self.assertFalse(s.registers[2].known)
    def test_rn_rm_and_rd31_are_zero_registers_not_sp(self):
        for op in OPS:
            base=op&~((31<<16)|(31<<5)|31)
            s=self.run_op(base|(1<<16)|(31<<5)|2,77,2)
            expected=2 if op in (OPS[0],OPS[2]) else (0xfffffffe if op==OPS[1] else 0xfffffffffffffffe)
            self.assertEqual(s.registers[2],Value('constant',expected))
            s=self.run_op(base|(31<<16)|2,7,99);self.assertEqual(s.registers[2],Value('constant',7))
            s=self.run_op(base|(1<<16)|31,7,2);self.assertEqual(s.registers[0],Value('constant',7));self.assertIsNotNone(s.flags)
    def test_original_operands_and_same_register_subtraction_remain_unknown(self):
        for op in OPS:
            s=PathState();s.apply(decode_instruction((op&~((31<<16)|(31<<5)|31))|(19<<16)|(19<<5)|19))
            self.assertFalse(s.registers[19].known);self.assertIsNone(s.flags)
    def test_stack_derived_either_operand_cannot_hide_call_escape(self):
        for op in OPS:
            for reg in (0,1):
                s=PathState(strict_call_state=True);s.registers[reg]=Value('stack');s.registers[1-reg]=Value('constant',0)
                with self.assertRaises(ModelError):s.apply(decode_instruction(op))
        for op in OPS[2:]:
            s=PathState();s.registers[1]=Value('stack')
            with self.assertRaises(ModelError):s.apply(decode_instruction(op))
    def test_reserved_shift_extended_logical_and_reserved_carry_forms_decline(self):
        for op in OPS:
            for bits in (3<<22,(1<<21)|(5<<10)):
                with self.subTest(op=hex(op|bits)),self.assertRaises(ModelError):decode_instruction(op|bits)
            if op in OPS[:2]:
                with self.assertRaises(ModelError):decode_instruction(op|(1<<15))
        for op in (0xba010402,0xfa010402,0xf240fc02,0x7a410010):
            with self.assertRaises(ModelError):decode_instruction(op)
    def test_known_cfg_paths_and_unknown_forks_each_family(self):
        for op in OPS:
            add=op in (OPS[0],OPS[2]);mov=0x92800000 if add else 0xd2800000;cond=2 if add else 3
            words=(mov,0xd2800021,op,0x54000060|cond,NOP,0x14000002,NOP,RET)
            r=audit_current_function(*fixture(words,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertIn(0x1018,r.checked_pcs);self.assertNotIn(0x1010,r.checked_pcs)
            unknown=(0xd2800021,op,0x54000060|cond,NOP,0x14000002,NOP,RET)
            r=audit_current_function(*fixture(unknown,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_known_vs_possible_only_saved_pair_mismatch_each_family(self):
        for op in OPS:
            add=op in (OPS[0],OPS[2]);mov=0x92800000 if add else 0xd2800000;cond=3 if add else 2
            known=(*PAIR_PRO,mov,0xd2800021,op,0x54000060|cond,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(known).verdict,'inconsistency')
            unknown=(*PAIR_PRO,0xd2800021,op,0x54000060|cond,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
    def test_fde_call_scope_postcall_unknown_and_fresh_concrete_flags(self):
        for op in OPS:
            words=(*PRO,CALL,op,0x5400004c,NOP,*EPI)
            r=audit_current_function(*image_for(words,CFI));self.assertEqual((r.verdict,r.coverage,r.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(r.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
        words=(*PRO,CALL,0xd2800000,0xd2800021,OPS[3],0x54000043,NOP,*EPI)
        r=audit_current_function(*image_for(words,CFI));self.assertEqual(r.verdict,'agreement');self.assertTrue(any('1 terminal paths' in e.message for e in r.evidence))
    def test_frame_pointer_destinations_and_dead_unsupported_shift_reject(self):
        for op in OPS:
            r=check((*PRO,(op&~31)|29,0x5400004c,CALL,*EPI))
            self.assertEqual(r.reason_codes,('cfg_frame_transition_not_modeled',))
        r=audit_current_function(*fixture((0x14000002,OPS[0]|(3<<22),NOP,RET),0x02000000));self.assertEqual(r.verdict,'unresolved')
    def test_path_budget_and_csel_consume_fresh_flags(self):
        words=(OPS[0],0x54000060,NOP,0x14000002,NOP,RET)
        r=audit_current_function(*fixture(words,0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(r.reason_codes,('cfg_path_limit',))
        s=self.run_op(OPS[0],0xffffffff,1);flags=s.flags
        s.apply(decode_instruction(0x1a810043)) # CSEL W3,W2,W1,EQ
        self.assertEqual(s.registers[3],Value('constant',0));self.assertEqual(s.flags,flags)
