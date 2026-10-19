"""Bounded bitfield aliases, destination merges, sign fill and recovery limits."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import PRO,EPI,CALL,PAIR_PRO,PAIR_EPI,check
from test_dwarf_cfg import image_for,CFI
BASES=(0x13000000,0x33000000,0x53000000,0x93400000,0xb3400000,0xd3400000)
def word(base,r=4,s=7,rd=2,rn=0):return base|(r<<16)|(s<<10)|(rn<<5)|rd
class BitfieldTests(unittest.TestCase):
    def op(self,base,source,destination=0,r=4,s=7,flags=(True,False,True,True),rd=2):
        state=PathState(flags=flags);state.registers[0]=Value('constant',source)
        if 0<rd<31: state.registers[rd]=Value('constant',destination)
        state.apply(decode_instruction(word(base,r,s,rd)));return state
    def test_unsigned_nonwrap_and_wrap_extract_zero_fill(self):
        for base,r in ((BASES[2],28),(BASES[5],60)):
            self.assertEqual(self.op(base,0xabcd,r=4,s=11).registers[2],Value('constant',0xbc))
            self.assertEqual(self.op(base,0xb,r=r,s=3).registers[2],Value('constant',0xb0))
    def test_signed_nonwrap_and_wrap_sign_fill(self):
        for base,r,negative in ((BASES[0],28,0xffffffb0),(BASES[3],60,0xffffffffffffffb0)):
            self.assertEqual(self.op(base,0xb,r=r,s=3).registers[2],Value('constant',negative))
            self.assertEqual(self.op(base,0x70,r=4,s=7).registers[2],Value('constant',7))
            self.assertEqual(self.op(base,0x80,r=4,s=7).registers[2],Value('constant',0xfffffff8 if r==28 else 0xfffffffffffffff8))
    def test_bfm_extract_insert_low_and_wrap_preserve_old_destination(self):
        for base,r in ((BASES[1],28),(BASES[4],60)):
            self.assertEqual(self.op(base,0xabcd,0x12345678).registers[2],Value('constant',0x1234567c))
            self.assertEqual(self.op(base,0xb,0x12345678,r=r,s=3).registers[2],Value('constant',0x123456b8))
        self.assertEqual(self.op(BASES[4],0xb,0xabcdef0012345678,r=60,s=3).registers[2],Value('constant',0xabcdef00123456b8))
    def test_lsr_asr_lsl_aliases_and_legacy_w_lsl(self):
        for unsigned,signed,bits in ((BASES[2],BASES[0],32),(BASES[5],BASES[3],64)):
            self.assertEqual(self.op(unsigned,1<<(bits-1),r=bits-1,s=bits-1).registers[2],Value('constant',1))
            self.assertEqual(self.op(signed,1<<(bits-1),r=bits-1,s=bits-1).registers[2],Value('constant',(1<<bits)-1))
            self.assertEqual(self.op(unsigned,(1<<(bits-1))|1,r=bits-1,s=bits-2).registers[2],Value('constant',2))
        self.assertEqual(decode_instruction(word(BASES[2],31,30)).kind,'wlsl')
    def test_sign_and_zero_extension_aliases(self):
        for base,source,s,want in ((BASES[0],0x80,7,0xffffff80),(BASES[0],0x8000,15,0xffff8000),(BASES[3],0x80,7,0xffffffffffffff80),(BASES[3],0x8000,15,0xffffffffffff8000),(BASES[3],0x80000000,31,0xffffffff80000000),(BASES[2],0x1ff,7,0xff),(BASES[5],0x1ffff,15,0xffff)):
            self.assertEqual(self.op(base,source,r=0,s=s).registers[2],Value('constant',want))
    def test_single_bit_full_width_and_width_normalization(self):
        for base in BASES:
            bits=32 if base in BASES[:3] else 64
            self.assertEqual(self.op(base,1<<(bits+1),7,r=0,s=bits-1).registers[2],Value('constant',0))
        for base,want in ((BASES[0],0xffffffff),(BASES[2],1),(BASES[3],0xffffffffffffffff),(BASES[5],1)):
            self.assertEqual(self.op(base,1,r=0,s=0).registers[2],Value('constant',want))
    def test_unknown_source_and_bfm_old_destination_never_invent_identity(self):
        for base in BASES:
            state=PathState();state.apply(decode_instruction(word(base,r=0,s=31 if base in BASES[:3] else 63,rd=19,rn=19)))
            self.assertFalse(state.registers[19].known)
        for base in (BASES[1],BASES[4]):
            state=PathState();state.registers[0]=Value('constant',1);state.apply(decode_instruction(word(base,r=0,s=31 if base==BASES[1] else 63)))
            self.assertFalse(state.registers[2].known)
    def test_all_forms_preserve_known_and_unknown_nzcv(self):
        for base in BASES:
            for flags in (None,(True,True,False,True),(False,False,True,False)):
                self.assertEqual(self.op(base,0xab,3,flags=flags).flags,flags)
                state=PathState(flags=flags);state.apply(decode_instruction(word(base)));self.assertEqual(state.flags,flags)
    def test_zr_source_bfc_and_destination_discard(self):
        for base in BASES:
            state=PathState();state.registers[2]=Value('constant',0xff);state.apply(decode_instruction(word(base,r=28 if base in BASES[:3] else 60,s=3,rn=31)))
            self.assertEqual(state.registers[2],Value('constant',0xf if base in (BASES[1],BASES[4]) else 0))
            state=self.op(base,0xab,rd=31);self.assertEqual(state.sp,Value('stack'));self.assertEqual(state.registers[0],Value('constant',0xab))
    def test_overlap_reads_source_and_destination_before_write(self):
        for base in (BASES[1],BASES[4]):
            self.assertEqual(self.op(base,0xabcd,rd=0).registers[0],Value('constant',0xabcc))
        for base in (BASES[0],BASES[2],BASES[3],BASES[5]):
            self.assertEqual(self.op(base,0x70,rd=0).registers[0],Value('constant',7))
    def test_source_and_bfm_destination_provenance_before_projection_or_discard(self):
        for base in BASES:
            state=PathState(strict_call_state=True);state.registers[0]=Value('stack')
            with self.assertRaises(ModelError):state.apply(decode_instruction(word(base,rd=31)))
        for base in (BASES[1],BASES[4]):
            state=PathState(strict_call_state=True);state.registers[0]=Value('constant',0);state.registers[2]=Value('stack')
            with self.assertRaises(ModelError):state.apply(decode_instruction(word(base)))
    def test_illegal_n_width_immediates_opc_and_dead_encoding_decline(self):
        for base in BASES:
            with self.assertRaises(ModelError):decode_instruction(word(base)^(1<<22))
            with self.assertRaises(ModelError):decode_instruction(word(base)^((1<<23)|(1<<21)))
        for base in BASES[:3]:
            for r,s in ((32,0),(0,32),(63,63)):
                with self.assertRaises(ModelError):decode_instruction(word(base,r,s))
        for op in (0x73000002,0xf3400002):
            with self.assertRaises(ModelError):decode_instruction(op)
        result=audit_current_function(*fixture((0x14000002,0x53400002,NOP,RET),0x02000000));self.assertEqual(result.verdict,'unresolved')
    def test_known_flags_and_unknown_bitfield_result_select_exact_path(self):
        for base in BASES:
            result=audit_current_function(*fixture((0xd2800020,0x7100041f,word(base,rn=9),0x54000060,NOP,0x14000002,NOP,RET),0x02000000))
            self.assertEqual(result.verdict,'agreement');self.assertIn(0x1018,result.checked_pcs);self.assertNotIn(0x1010,result.checked_pcs)
    def test_known_mismatch_unknown_recovery_and_possible_only_witness(self):
        for base in BASES:
            known=check((*PAIR_PRO,0xd2800020,0xd2800033,word(base,r=0,s=0,rd=19),CALL,*PAIR_EPI));self.assertEqual(known.verdict,'inconsistency')
            unknown=check((*PAIR_PRO,word(base,rd=19,rn=19),CALL,*PAIR_EPI));self.assertEqual(unknown.reason_codes,('unknown_recovery_value',))
            possible=check((*PAIR_PRO,0x54000080,0xd2800020,0xd2800033,word(base,r=0,s=0,rd=19),CALL,*PAIR_EPI));self.assertEqual(possible.reason_codes,('cfg_path_feasibility_unknown',))
    def test_postcall_unknown_flags_fde_scope_and_frame_guard(self):
        for base in BASES:
            result=audit_current_function(*image_for((*PRO,CALL,word(base),0x54000040,NOP,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'));self.assertEqual(result.checked_pcs,(0x1008,));self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
            self.assertEqual(check((*PRO,word(base,rd=29),0x54000040,CALL,*EPI)).reason_codes,('cfg_frame_transition_not_modeled',))
    def test_path_budget_and_flag_consumers_remain_bounded(self):
        result=audit_current_function(*fixture((word(BASES[5]),0x54000060,NOP,0x14000002,NOP,RET),0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(result.reason_codes,('cfg_path_limit',))
        state=self.op(BASES[5],0x80,flags=(False,True,True,False));state.registers[0]=Value('constant',2);state.registers[1]=Value('constant',3)
        state.apply(decode_instruction(0x9a010003));self.assertEqual(state.registers[3],Value('constant',6))
        state.apply(decode_instruction(0x9a810004));self.assertEqual(state.registers[4],Value('constant',2))
