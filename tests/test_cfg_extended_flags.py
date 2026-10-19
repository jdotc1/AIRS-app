"""Bounded extensions use literal low-bit expectations and recovery witnesses."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI

# ADDS/SUBS W2 or X2, W0/X0, W1/X1 extended; option and shift set by each case.
OPS=(0x2b210002,0x6b210002,0xab210002,0xeb210002)
class ExtendedFlagTests(unittest.TestCase):
    def run_op(self,word,left,right):
        s=PathState();s.registers[0]=Value('constant',left);s.registers[1]=Value('constant',right)
        s.apply(decode_instruction(word));return s
    def test_unsigned_byte_halfword_word_and_x_extensions(self):
        for base,wants in ((OPS[0],(0x80,0x8080,0x80008080)),(OPS[2],(0x80,0x8080,0x80008080,0x8000800080008080))):
            for option,want in enumerate(wants):
                s=self.run_op(base|(option<<13),0,0x8000800080008080);self.assertEqual(s.registers[2],Value('constant',want))
    def test_signed_byte_halfword_word_and_x_extensions(self):
        for base,wants in ((OPS[0],(0xffffff80,0xffff8080,0x80008080)),(OPS[2],(0xffffffffffffff80,0xffffffffffff8080,0xffffffff80008080,0x8000800080008080))):
            for option,want in enumerate(wants,4):
                s=self.run_op(base|(option<<13),0,0x8000800080008080);self.assertEqual(s.registers[2],Value('constant',want))
    def test_w_add_sub_signed_extension_overflow_and_zero_extension(self):
        for op,left,want,flags in ((0x2b218002,0x80000000,0x7fffffff,(False,False,True,True)),(0x6b218002,0x7fffffff,0x80000000,(True,False,False,True))):
            s=self.run_op(op,left,0xff);self.assertEqual((s.registers[2],s.flags),(Value('constant',want),flags))
    def test_x_add_sub_signed_extension_overflow(self):
        for op,left,want,flags in ((0xab218002,0x8000000000000000,0x7fffffffffffffff,(False,False,True,True)),(0xeb218002,0x7fffffffffffffff,0x8000000000000000,(True,False,False,True))):
            s=self.run_op(op,left,0xff);self.assertEqual((s.registers[2],s.flags),(Value('constant',want),flags))
    def test_extension_precedes_maximum_shift_and_arithmetic_carry(self):
        for op,want in ((0x2b219002,0xfffff800),(0xab219002,0xfffffffffffff800)):
            s=self.run_op(op,0,0x80);self.assertEqual(s.registers[2],Value('constant',want))
        for op in (0x2b219002,0xab219002):
            s=self.run_op(op,16,0xff);self.assertEqual((s.registers[2],s.flags),(Value('constant',0),(False,True,True,False)))
    def test_unsigned_extended_shift_carry_and_subtraction_borrow(self):
        for op,left,want,flags in ((0x2b211002,0xfffff0f0,0,(False,True,True,False)),(0x6b211002,0,0xfffff0f0,(True,False,False,False)),(0xab211002,0xfffffffffffff0f0,0,(False,True,True,False)),(0xeb211002,0,0xfffffffffffff0f0,(True,False,False,False))):
            s=self.run_op(op,left,0xf1);self.assertEqual((s.registers[2],s.flags),(Value('constant',want),flags))
    def test_rm31_zero_and_rd31_aliases_preserve_other_registers(self):
        for base in OPS:
            for option in ((0,1,2,4,5,6) if base in OPS[:2] else range(8)):
                word=base|(option<<13)|(4<<10)
                s=self.run_op((word&~(31<<16))|(31<<16),7,0xff);self.assertEqual(s.registers[2],Value('constant',7))
                s=self.run_op((word&~31)|31,7,0xff);self.assertEqual(s.registers[0],Value('constant',7));self.assertIsNotNone(s.flags)
    def test_sp_source_rejected_even_cmp_cmn_aliases_and_reserved_controls(self):
        for op in OPS:
            for rd in (2,31):
                with self.assertRaises(ModelError):decode_instruction((op&~((31<<5)|31))|(31<<5)|rd)
            for amount in (5,6,7):
                with self.assertRaises(ModelError):decode_instruction(op|(amount<<10))
            for bits in (1<<22,1<<23):
                with self.assertRaises(ModelError):decode_instruction(op|bits)
        for op in OPS[:2]:
            for option in (3,7):
                with self.assertRaises(ModelError):decode_instruction(op|(option<<13)) # Explicit bounded exclusion, not an invalid-ISA claim.
    def test_unknown_each_operand_extension_and_shift_kills_stale_flags(self):
        for op in OPS:
            for option in ((0,1,2,4,5,6) if op in OPS[:2] else range(8)):
                for unknown in (0,1):
                    s=PathState(flags=(False,True,True,False));s.registers[1-unknown]=Value('constant',0)
                    s.apply(decode_instruction(op|(option<<13)|(4<<10)));self.assertFalse(s.registers[2].known);self.assertIsNone(s.flags)
    def test_stack_provenance_either_source_precedes_narrow_extension(self):
        for op in OPS:
            for option in (0,4):
                for reg in (0,1):
                    s=PathState(strict_call_state=True);s.registers[reg]=Value('stack');s.registers[1-reg]=Value('constant',0)
                    with self.assertRaises(ModelError):s.apply(decode_instruction(op|(option<<13)|(4<<10)))
        for op in OPS[2:]:
            s=PathState();s.registers[1]=Value('stack')
            with self.assertRaises(ModelError):s.apply(decode_instruction(op))
    def test_original_identity_not_invented_and_destination_overlap_reads_old_value(self):
        for op in OPS:
            s=PathState();s.apply(decode_instruction((op&~((31<<5)|31))|(19<<5)|19));self.assertFalse(s.registers[19].known);self.assertIsNone(s.flags)
        for op,want in ((0x2b218001,5),(0x6b218001,9),(0xab218001,5),(0xeb218001,9)):
            s=self.run_op(op,7,0xfe);self.assertEqual(s.registers[1],Value('constant',want))
    def test_known_cfg_and_unknown_forks_each_extension_family(self):
        for op in OPS:
            for option in ((0,1,2,4,5,6) if op in OPS[:2] else range(8)):
                extended=op|(option<<13)|(4<<10)
                words=(0xd2800000,0xd2801fe1,extended,0x54000061,NOP,0x14000002,NOP,RET)
                r=audit_current_function(*fixture(words,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertIn(0x1018,r.checked_pcs);self.assertNotIn(0x1010,r.checked_pcs)
                unknown=(0xd2801fe1,extended,0x54000061,NOP,0x14000002,NOP,RET)
                r=audit_current_function(*fixture(unknown,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_known_vs_possible_only_saved_pair_witness_each_extension(self):
        for op in OPS:
            for option in ((0,1,2,4,5,6) if op in OPS[:2] else range(8)):
                extended=op|(option<<13)|(4<<10)
                known=(*PAIR_PRO,0xd2800000,0xd2801fe1,extended,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
                self.assertEqual(check(known).verdict,'inconsistency')
                unknown=(*PAIR_PRO,0xd2801fe1,extended,0x54000060,0xd28000f3,CALL,*PAIR_EPI)
                self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_fde_unknown_extension_and_fresh_flags_retain_scope(self):
        for op in OPS:
            words=(*PRO,CALL,op|(4<<13)|(4<<10),0x5400004c,NOP,*EPI)
            r=audit_current_function(*image_for(words,CFI));self.assertEqual((r.verdict,r.coverage,r.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(r.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
        words=(*PRO,CALL,0xd2800000,0xd2801fe1,0xab218002,0x54000041,NOP,*EPI)
        r=audit_current_function(*image_for(words,CFI));self.assertEqual(r.verdict,'agreement');self.assertTrue(any('1 terminal paths' in e.message for e in r.evidence))
    def test_frame_guard_dead_invalid_shift_and_path_caps(self):
        for op in OPS:
            r=check((*PRO,(op&~31)|29,0x5400004c,CALL,*EPI));self.assertEqual(r.reason_codes,('cfg_frame_transition_not_modeled',))
        r=audit_current_function(*fixture((0x14000002,OPS[0]|(5<<10),NOP,RET),0x02000000));self.assertEqual(r.verdict,'unresolved')
        r=audit_current_function(*fixture((OPS[0],0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(r.reason_codes,('cfg_path_limit',))
