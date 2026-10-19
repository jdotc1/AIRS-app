"""Bounded nonflag register logic preserves flags without inventing identities."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI

BASES=(0x0a000000,0x0a200000,0x2a000000,0x2a200000,0x4a000000,0x4a200000,
       0x8a000000,0x8a200000,0xaa000000,0xaa200000,0xca000000,0xca200000)
def word(base,rd=2,rn=0,rm=1,shift=0,amount=0):
    return base|(shift<<22)|(rm<<16)|(amount<<10)|(rn<<5)|rd
class NonflagRegisterTests(unittest.TestCase):
    def op(self,base,left,right,shift=0,amount=0,flags=(True,False,True,True),rd=2):
        state=PathState(flags=flags);state.registers[0]=Value('constant',left);state.registers[1]=Value('constant',right)
        state.apply(decode_instruction(word(base,rd=rd,shift=shift,amount=amount)));return state
    def test_six_operations_width_wrap_and_zero_extension(self):
        # low32 left A, right C: AND8 BIC2 ORRE ORN...FB EOR6 EON...F9.
        wants=(8,2,14,0xfffffffb,6,0xfffffff9,8,2,14,0xfffffffffffffffb,6,0xfffffffffffffff9)
        for i,base in enumerate(BASES):
            left=0x10000000a if i<6 else 10
            self.assertEqual(self.op(base,left,12).registers[2],Value('constant',wants[i]))
    def test_all_shifts_complement_after_shift(self):
        # right=0x80000001; shift1 -> 2,40000000,c0000000,c0000000.
        for base in BASES[:6]:
            expected={BASES[0]:(2,0x40000000,0xc0000000,0xc0000000),BASES[1]:(0xfffffffd,0xbfffffff,0x3fffffff,0x3fffffff),BASES[2]:(0xffffffff,)*4,BASES[3]:(0xffffffff,)*4,BASES[4]:(0xfffffffd,0xbfffffff,0x3fffffff,0x3fffffff),BASES[5]:(2,0x40000000,0xc0000000,0xc0000000)}[base]
            for shift,want in enumerate(expected):self.assertEqual(self.op(base,0xffffffff,0x80000001,shift,1).registers[2],Value('constant',want))
        for shift,want in enumerate((2,0x4000000000000000,0xc000000000000000,0xc000000000000000)):
            self.assertEqual(self.op(BASES[6],0xffffffffffffffff,0x8000000000000001,shift,1).registers[2],Value('constant',want))
        for base,wants in ((BASES[7],(0xfffffffffffffffd,0xbfffffffffffffff,0x3fffffffffffffff,0x3fffffffffffffff)),(BASES[8],(0xffffffffffffffff,)*4),(BASES[9],(0xffffffffffffffff,)*4),(BASES[10],(0xfffffffffffffffd,0xbfffffffffffffff,0x3fffffffffffffff,0x3fffffffffffffff)),(BASES[11],(2,0x4000000000000000,0xc000000000000000,0xc000000000000000))):
            for shift,want in enumerate(wants):self.assertEqual(self.op(base,0xffffffffffffffff,0x8000000000000001,shift,1).registers[2],Value('constant',want))
    def test_zero_and_max_shift_width_boundaries(self):
        for base in BASES:
            width=32 if base<0x80000000 else 64
            for shift in range(4):
                state=self.op(base,0,1,shift,0);self.assertEqual(state.flags,(True,False,True,True))
            self.assertEqual(self.op(BASES[2 if width==32 else 8],0,1,0,width-1).registers[2],Value('constant',1<<(width-1)))
            self.assertEqual(self.op(BASES[2 if width==32 else 8],0,1,3,width-1).registers[2],Value('constant',2))
    def test_reserved_w_shift32_and63_for_all_operations(self):
        for base in BASES[:6]:
            for shift in range(4):
                for amount in (32,63):
                    with self.assertRaises(ModelError):decode_instruction(word(base,shift=shift,amount=amount))
    def test_known_and_unknown_nzcv_preserved_on_concrete_results(self):
        for base in BASES:
            for flags in (None,(False,False,True,False),(True,True,False,True)):
                self.assertEqual(self.op(base,0,1,flags=flags).flags,flags)
    def test_unknown_either_source_preserves_flags_and_loses_identity(self):
        for base in BASES:
            for unknown in (0,1):
                state=PathState(flags=(False,True,True,False));state.registers[1-unknown]=Value('constant',0)
                state.apply(decode_instruction(word(base,rd=19)))
                self.assertFalse(state.registers[19].known);self.assertEqual(state.flags,(False,True,True,False))
    def test_zr_sources_destination_and_mvn_alias(self):
        for base in BASES:
            state=PathState();state.apply(decode_instruction(word(base,rn=31,rm=31,rd=31)))
            self.assertEqual(state.sp,Value('stack'));self.assertIsNone(state.flags)
        for base,want in ((BASES[3],0xfffffffe),(BASES[9],0xfffffffffffffffe)):
            state=PathState();state.registers[1]=Value('constant',1);state.apply(decode_instruction(word(base,rn=31)))
            self.assertEqual(state.registers[2],Value('constant',want))
    def test_existing_exact_x_mov_preserves_original_and_stack_identity(self):
        for value in (Value('original',19),Value('stack',displacement=-16)):
            state=PathState(flags=(True,False,True,False));state.registers[1]=value
            ins=decode_instruction(word(BASES[8],rn=31));self.assertEqual(ins.kind,'mov');state.apply(ins)
            self.assertEqual(state.registers[2],value);self.assertEqual(state.flags,(True,False,True,False))
        state=PathState();state.apply(decode_instruction(word(BASES[2],rn=31,rm=19)))
        self.assertFalse(state.registers[2].known)
        for shift,amount in ((0,1),(1,0),(2,0),(3,0)):
            state=PathState();state.apply(decode_instruction(word(BASES[8],rn=31,rm=19,shift=shift,amount=amount)))
            self.assertFalse(state.registers[2].known)
    def test_source_overlap_uses_both_old_values(self):
        for rd in (0,1):
            self.assertEqual(self.op(BASES[10],10,12,rd=rd).registers[rd],Value('constant',6))
    def test_provenance_checked_for_each_source_before_bit_operation(self):
        for base in BASES:
            for source in (0,1):
                state=PathState(strict_call_state=True);state.registers[source]=Value('stack')
                with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,rd=31)))
    def test_known_cmp_flags_drive_branch_and_csel_after_unknown_result(self):
        for base in BASES:
            words=(0xd2800100,0x71001c1f,word(base,rm=9),0x1a8003e3,0x54000062,NOP,0x14000002,NOP,RET)
            result=audit_current_function(*fixture(words,0x02000000));self.assertEqual(result.verdict,'agreement');self.assertIn(0x101c,result.checked_pcs);self.assertNotIn(0x1014,result.checked_pcs)
    def test_unknown_entry_flags_fork_despite_concrete_zero_result(self):
        for base in BASES:
            result=audit_current_function(*fixture((word(base,rn=31,rm=31),0x54000060,NOP,0x14000002,NOP,RET),0x02000000))
            self.assertEqual(result.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
    def test_known_and_possible_only_discrepancy_witnesses(self):
        for base in BASES:
            op=word(base,rm=9)
            self.assertEqual(check((*PAIR_PRO,0xd2800100,0x71001c1f,op,0x54000060,0xd28000f3,CALL,*PAIR_EPI)).verdict,'inconsistency')
            self.assertEqual(check((*PAIR_PRO,op,0x54000060,0xd28000f3,CALL,*PAIR_EPI)).reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_flags_remain_unknown_and_fde_scope_stays_at_bl(self):
        for base in BASES:
            result=audit_current_function(*image_for((*PRO,CALL,word(base,rn=31,rm=31),0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
    def test_frame_guard_dead_reserved_word_and_caps(self):
        for base in BASES:
            self.assertEqual(check((*PRO,word(base,rd=29),0x54000040,CALL,*EPI)).reason_codes,('cfg_frame_transition_not_modeled',))
        result=audit_current_function(*fixture((0x14000002,word(BASES[0],amount=32),NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
        result=audit_current_function(*fixture((word(BASES[0],rn=31,rm=31),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
