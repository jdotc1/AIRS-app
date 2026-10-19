"""High64 products of owned literal X-register instruction words."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI
BASES=(0x9b407c00,0x9bc07c00)
def word(base,rd=2,rn=0,rm=1):return base|(rm<<16)|(rn<<5)|rd
class HighMultiplyTests(unittest.TestCase):
    def op(self,base,left,right,flags=(False,True,True,False),rd=2,rn=0,rm=1):
        state=PathState(flags=flags);state.registers[0]=Value('constant',left);state.registers[1]=Value('constant',right)
        state.apply(decode_instruction(word(base,rd,rn,rm)));return state
    def test_negative_one_times_one_distinguishes_signed_unsigned(self):
        for base,want in zip(BASES,(0xffffffffffffffff,0)):
            self.assertEqual(self.op(base,0xffffffffffffffff,1).registers[2],Value('constant',want))
            self.assertEqual(self.op(base,1,0xffffffffffffffff).registers[2],Value('constant',want))
    def test_signed_minimum_squared_and_negative_product_boundaries(self):
        for base in BASES:self.assertEqual(self.op(base,0x8000000000000000,0x8000000000000000).registers[2],Value('constant',0x4000000000000000))
        for base,want in zip(BASES,(0,0x7fffffffffffffff)):
            self.assertEqual(self.op(base,0x8000000000000000,0xffffffffffffffff).registers[2],Value('constant',want))
    def test_low_product_is_not_returned_or_truncated_before_high_extract(self):
        for base in BASES:
            self.assertEqual(self.op(base,4,5).registers[2],Value('constant',0))
            self.assertEqual(self.op(base,0x100000000,0x100000000).registers[2],Value('constant',1))
    def test_maximum_unsigned_product_differs_from_signed_square(self):
        for base,want in zip(BASES,(0,0xfffffffffffffffe)):
            self.assertEqual(self.op(base,0xffffffffffffffff,0xffffffffffffffff).registers[2],Value('constant',want))
    def test_mixed_sign_floor_not_truncate_toward_zero(self):
        for base,want in zip(BASES,(0xfffffffffffffffe,1)):
            self.assertEqual(self.op(base,0x8000000000000000,3).registers[2],Value('constant',want))
        for base,want in zip(BASES,(0xffffffffffffffff,1)):
            self.assertEqual(self.op(base,0x8000000000000000,2).registers[2],Value('constant',want))
    def test_sources_normalize_full64_before_signedness(self):
        for base,want in zip(BASES,(0xffffffffffffffff,0)):
            self.assertEqual(self.op(base,0x1ffffffffffffffff,0x10000000000000001).registers[2],Value('constant',want))
            self.assertEqual(self.op(base,-1,1).registers[2],Value('constant',want))
    def test_zr_sources_and_discard(self):
        for base in BASES:
            for field in ('rn','rm'):self.assertEqual(self.op(base,4,5,**{field:31}).registers[2],Value('constant',0))
            state=self.op(base,4,5,rd=31);self.assertEqual(state.sp,Value('stack'));self.assertEqual(state.registers[0],Value('constant',4))
    def test_overlap_reads_both_old_sources(self):
        for base,want in zip(BASES,(0,0xfffffffffffffffe)):
            for rd in (0,1):self.assertEqual(self.op(base,0xffffffffffffffff,0xffffffffffffffff,rd=rd).registers[rd],Value('constant',want))
            self.assertEqual(self.op(base,0xffffffffffffffff,7,rd=0,rn=0,rm=0).registers[0],Value('constant',want))
    def test_unknown_either_source_even_with_other_zero(self):
        for base in BASES:
            for unknown in (0,1):
                state=PathState();state.registers[1-unknown]=Value('constant',0);state.apply(decode_instruction(word(base)));self.assertFalse(state.registers[2].known)
    def test_zero_product_does_not_infer_original_identity(self):
        for base in BASES:
            state=PathState();state.apply(decode_instruction(word(base,rd=19,rn=19,rm=31)));self.assertFalse(state.registers[19].known)
    def test_both_stack_operands_guarded_before_zero_or_discard(self):
        for base in BASES:
            for source in (0,1):
                for strict in (False,True):
                    state=PathState(strict_call_state=strict);state.registers[source]=Value('stack');state.registers[1-source]=Value('constant',0)
                    with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,rd=31)))
    def test_known_and_unknown_flags_preserved(self):
        for base in BASES:
            for flags in (None,(True,False,True,True),(False,True,False,False)):
                self.assertEqual(self.op(base,4,5,flags=flags).flags,flags)
                state=PathState(flags=flags);state.apply(decode_instruction(word(base)));self.assertEqual(state.flags,flags)
    def test_invalid_controls_width_and_noncanonical_ra_decline_even_dead(self):
        for base in BASES:
            for bit in (1<<31,1<<29,1<<30,1<<21,1<<15):
                with self.assertRaises(ModelError):decode_instruction(word(base)^bit)
            for ra in (0,1,30):
                with self.assertRaises(ModelError):decode_instruction(word((base&~0x7c00)|(ra<<10)))
        result=audit_current_function(*fixture((0x14000002,word(BASES[0])^(1<<31),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
    def test_unknown_output_keeps_known_cfg_path(self):
        for base in BASES:
            result=audit_current_function(*fixture((0xd2800020,0x7100041f,word(base,rn=9,rm=10),0x54000060,NOP,0x14000002,NOP,RET),0x02000000))
            self.assertEqual(result.verdict,'agreement');self.assertIn(0x1018,result.checked_pcs);self.assertNotIn(0x1010,result.checked_pcs)
    def test_known_mismatch_unknown_recovery_and_possible_only(self):
        for base in BASES:
            self.assertEqual(check((*PAIR_PRO,0xd2800080,0xd28000a1,word(base,rd=19),CALL,*PAIR_EPI)).verdict,'inconsistency')
            self.assertEqual(check((*PAIR_PRO,word(base,rd=19,rn=19),CALL,*PAIR_EPI)).reason_codes,('unknown_recovery_value',))
            self.assertEqual(check((*PAIR_PRO,0x54000080,0xd2800080,0xd28000a1,word(base,rd=19),CALL,*PAIR_EPI)).reason_codes,('cfg_path_feasibility_unknown',))
    def test_fde_postcall_scope_frame_path_cap_and_flag_consumers(self):
        for base in BASES:
            result=audit_current_function(*image_for((*PRO,CALL,word(base),0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
            self.assertEqual(check((*PRO,word(base,rd=29),0x54000040,CALL,*EPI)).reason_codes,('cfg_frame_transition_not_modeled',))
        result=audit_current_function(*fixture((word(BASES[0]),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
        state=self.op(BASES[0],4,5);state.registers[0]=Value('constant',2);state.registers[1]=Value('constant',3)
        state.apply(decode_instruction(0x9a010003));self.assertEqual(state.registers[3],Value('constant',6))
        state.apply(decode_instruction(0x9a810004));self.assertEqual(state.registers[4],Value('constant',2))
