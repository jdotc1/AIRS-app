import struct
import unittest
from airs.arm64 import Value, ModelError
from airs.cfg import PathState, decode_instruction, audit_cfg_function
from airs.types import Limits
from test_cfg import check


def clz(width=64,rd=0,rn=1):
    return (0xdac01000 if width == 64 else 0x5ac01000)|(rn<<5)|rd

class CLZTests(unittest.TestCase):
    def test_exact_width_zero_highbit_alias_and_zero_register(self):
        for width in (32,64):
            for value,expected in [(0,width),(1,width-1),(1<<(width-1),0),((1<<width)-1,0)]:
                state=PathState();state.registers[1]=Value('constant',value)
                state.apply(decode_instruction(clz(width,1,1)))
                self.assertEqual(state.read_register(1),Value('constant',expected))
            state=PathState();state.apply(decode_instruction(clz(width,0,31)))
            self.assertEqual(state.read_register(0),Value('constant',width))
            before=state.sp;state.apply(decode_instruction(clz(width,31,31)));self.assertEqual(state.sp,before)
        state=PathState();state.registers[1]=Value('constant',1<<40)
        state.apply(decode_instruction(clz(32)));self.assertEqual(state.read_register(0),Value('constant',32))
    def test_unknown_stack_provenance_and_flags_do_not_become_constants(self):
        for width in (32,64):
            state=PathState();state.apply(decode_instruction(clz(width)));self.assertEqual(state.read_register(0).kind,'unknown')
            state=PathState();state.registers[1]=Value('stack',0)
            with self.assertRaises(ModelError) as error:state.apply(decode_instruction(clz(width)))
            self.assertEqual(error.exception.code,'clz_stack_address_not_modeled')
            state=PathState();state.flags=(True,False,True,False);state.registers[1]=Value('constant',1)
            state.apply(decode_instruction(clz(width)));self.assertEqual(state.flags,(True,False,True,False))
    def test_neighbors_and_other_one_source_families_stay_unsupported(self):
        for word in [0xdac00000,0xdac01400,0x9ac10800,clz()^(1<<30),clz()^(1<<29),clz()^(1<<16),clz()^(1<<21)]:
            with self.assertRaises(ModelError):decode_instruction(word)
    def test_owned_compiler_bodies_gain_only_the_selected_family(self):
        # Apple llvm-objdump retained in AIRS-b6-owned-20261020. Literal complete
        # sequences are independent controls; no library is read or executed.
        for words,encoding in [([0xdac01000,0xd65f03c0],0x02000000),([0x5ac01000,0xd65f03c0],0x02000000),
                               ([0xd10043ff,0xb9000fe0,0xb9400fe8,0x5ac01100,0x910043ff,0xd65f03c0],0x02001000)]:
            outcome=check(words=words,encoding=encoding)
            self.assertEqual(outcome.verdict,'agreement');self.assertTrue(outcome.checked_pcs)
        self.assertEqual(check(words=[0xdac00008,0xdac01100,0xd65f03c0],encoding=0x02000000).verdict,'unresolved')
    def test_preserved_register_and_resource_boundaries(self):
        self.assertEqual(check(words=[clz(64,19,0),0xd65f03c0],encoding=0x02000000).verdict,'unresolved')
        self.assertEqual(check(words=[clz(),0xd65f03c0],encoding=0x02000000,limits=Limits(max_cfg_steps_per_function=0)).verdict,'unresolved')


class CLZBoundaryTests(unittest.TestCase):
    def test_negative_masking_discard_provenance_and_flag_consumers(self):
        for width in (32,64):
            state=PathState();state.registers[1]=Value('constant',-1);state.apply(decode_instruction(clz(width)));self.assertEqual(state.read_register(0),Value('constant',0))
            state=PathState();state.registers[1]=Value('stack',0)
            with self.assertRaises(ModelError):state.apply(decode_instruction(clz(width,31,1)))
        state=PathState();state.flags=(False,True,True,False);state.registers[1]=Value('constant',1)
        state.apply(decode_instruction(clz()));self.assertTrue(state.condition(0));self.assertFalse(state.condition(1))
    def test_frame_pointer_and_dead_unknown_opcode_never_become_supported(self):
        from test_audit import FRAME
        from airs.cfg import audit_cfg_function
        from test_audit import fixture
        from airs.types import Limits
        words=list(FRAME);words[2]=clz(64,29,0)
        result=audit_cfg_function(*fixture(words,0x04000000),limits=Limits(),allow_calls=True)
        self.assertEqual(result.verdict,'unresolved');self.assertIn('cfg_frame_transition_not_modeled',result.reason_codes)
        # Even an unreachable unsupported neighbor is not silently a no-op.
        result=check(words=[0x14000002,0xdac01400,0xd65f03c0],encoding=0x02000000)
        self.assertEqual(result.verdict,'unresolved')

class CLZCallWitnessTests(unittest.TestCase):
    def test_known_mismatch_unknown_recovery_possible_path_and_synchronous_scope(self):
        from test_cfg_calls import PAIR_PRO,PAIR_EPI,PRO,EPI,CALL,check as call_check
        from test_dwarf_cfg import image_for,CFI
        from airs.cfg import audit_current_function
        for width in (32,64):
            known=call_check((*PAIR_PRO,0xd2800080,clz(width,19,0),CALL,*PAIR_EPI))
            self.assertEqual((known.verdict,known.scope),('inconsistency','synchronous_call_sites'))
            self.assertEqual(call_check((*PAIR_PRO,clz(width,19,19),CALL,*PAIR_EPI)).reason_codes,('unknown_recovery_value',))
            self.assertEqual(call_check((*PAIR_PRO,0x54000060,0xd2800080,clz(width,19,0),CALL,*PAIR_EPI)).reason_codes,('cfg_path_feasibility_unknown',))
            result=audit_current_function(*image_for((*PRO,CALL,clz(width),0x54000040,0xd503201f,*EPI),CFI))
            self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'))
            self.assertEqual(result.checked_pcs,(0x1008,))

if __name__=='__main__':unittest.main()
