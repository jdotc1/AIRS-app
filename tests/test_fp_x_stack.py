"""Focused X29-based X slots; tiny typed inputs, no prepared workload execution."""
from dataclasses import replace
import unittest
from airs.arm64 import ModelError, Value, original
from airs.cfg import PathState, decode_instruction
from airs.types import Limits
from test_rbit_x_candidate import BASE, PAIR_PRO, PAIR_EPI, CALL, call_result
from test_x_stack_slots import apply, xmem, wmem, SUB16, ADD16

MODEL='arm64-bounded-fp-x-stack-v36'
FRAME_WORDS=(*PAIR_PRO,0xf94003a0,0xf90003a0,0xf94007a1,0xf90007a1,CALL,*PAIR_EPI)


def fpstate(**kwargs):
    state=PathState(sp=Value('stack',displacement=-32),**kwargs)
    state.registers[29]=Value('stack',displacement=-24)
    return state


class FPXStackTests(unittest.TestCase):
    def test_exact_x29_decode_and_scaled_fields_keep_sp_admission(self):
        for load in (False,True):
            for offset in (0,8,32760):
                for base in (29,31):
                    ins=decode_instruction(xmem(load,19,offset,base),BASE)
                    self.assertEqual((ins.kind,ins.rn,ins.rd,ins.immediate),('xldr' if load else 'xstr',base,19,offset))
        for base in (0,28,30):
            with self.assertRaises(ModelError):decode_instruction(xmem(rn=base),BASE)
        for word in (0xb90003a0,0xb94003a0,0xf80003a0,0xf84003a0,0xf80087a0,0xf84087a0,0xf8206ba0):
            with self.subTest(word=hex(word)),self.assertRaises(ModelError):decode_instruction(word,BASE)

    def test_effective_address_uses_fp_not_sp_and_preserves_original_values(self):
        state=fpstate(memory={-32:Value('constant',7),-24:original(19),-8:original(30)})
        apply(state,xmem(True,0,0,29));self.assertEqual(state.registers[0],original(19))
        apply(state,xmem(True,1,16,29));self.assertEqual(state.registers[1],original(30))
        state.registers[2]=Value('constant',11);apply(state,xmem(False,2,8,29))
        self.assertEqual(state.memory[-16],Value('constant',11));self.assertEqual(state.memory[-32],Value('constant',7))

    def test_bad_fp_base_declines_even_if_offset_would_enter_frame(self):
        for base in (original(29),Value('unknown','FP unknown'),Value('constant',0),
                     Value('stack',displacement=-40),Value('stack',displacement=-28),Value('stack')):
            state=fpstate();state.registers[29]=base
            for load in (False,True):
                with self.subTest(base=base,load=load),self.assertRaises(ModelError):apply(state,xmem(load,31,16,29))

    def test_fp_access_requires_known_allocated_sp_and_full_effective_extent(self):
        for sp in (Value('unknown','SP unknown',-32),Value('original',31,-32),Value('stack')):
            state=fpstate();state.sp=sp
            with self.assertRaises(ModelError):apply(state,xmem(rt=31,rn=29))
        for offset in (24,32760):
            state=fpstate()
            with self.assertRaises(ModelError):apply(state,xmem(rt=31,offset=offset,rn=29))

    def test_zr_data_and_aliasing_fp_destination_capture_old_base(self):
        state=fpstate();apply(state,xmem(rt=31,rn=29));self.assertEqual(state.memory[-24],Value('constant',0))
        apply(state,xmem(True,31,0,29));self.assertEqual(state.registers[29],Value('stack',displacement=-24))
        state.memory[-24]=Value('constant',9);apply(state,xmem(True,29,0,29))
        self.assertEqual(state.registers[29],Value('constant',9))
        # Transfer-level alias semantics; framed body admission rejects this write.

    def test_missing_unknown_and_partial_slots_never_become_full_loads(self):
        for memory in ({},{-24:Value('unknown','saved unknown')}):
            state=fpstate(memory=memory)
            with self.assertRaises(ModelError):apply(state,xmem(True,31,0,29))
        for half in (8,12):
            state=fpstate();state.registers[0]=original(19);apply(state,xmem(rt=0,rn=29))
            apply(state,wmem(rt=31,offset=half))
            with self.assertRaises(ModelError):apply(state,xmem(True,19,0,29))

    def test_fp_store_invalidates_w_caches_and_sp_fp_views_share_slots(self):
        state=fpstate();state.registers[0]=Value('constant',7)
        apply(state,wmem(rt=0,offset=8));apply(state,wmem(rt=0,offset=12))
        state.registers[0]=Value('constant',0x1122334455667788);apply(state,xmem(rt=0,rn=29))
        self.assertEqual(state.words,{})
        for offset,want in ((8,0x55667788),(12,0x11223344)):
            apply(state,wmem(True,1,offset));self.assertEqual(state.registers[1],Value('constant',want))
        apply(state,xmem(True,2,8,31));self.assertEqual(state.registers[2],Value('constant',0x1122334455667788))

    def test_pair_fp_and_sp_slots_interoperate(self):
        state=fpstate();apply(state,0xa90053f3) # STP x19,x20,[SP]
        apply(state,xmem(True,0,0,29));self.assertEqual(state.registers[0],original(20))
        state.registers[1]=original(19);apply(state,xmem(rt=1,rn=29))
        apply(state,0xa94007e0) # LDP x0,x1,[SP]
        self.assertEqual((state.registers[0],state.registers[1]),(original(19),original(19)))

    def test_fp_stored_pointer_partial_and_full_overwrite_keep_escape_policy(self):
        for half in (8,12):
            state=fpstate(strict_call_state=True)
            apply(state,xmem(rt=29,rn=29))
            with self.assertRaises(ModelError) as error:apply(state,0x94000001)
            self.assertEqual(error.exception.code,'stack_address_escapes_call')
            with self.assertRaises(ModelError) as error:apply(state,wmem(rt=31,offset=half))
            self.assertEqual(error.exception.code,'partial_stack_address_not_modeled')
            apply(state,xmem(rt=31,rn=29));self.assertEqual(state._stack_pointer_slots,set())
            apply(state,0x94000001)

    def test_fp_load_preserves_pointer_tag_and_copy_recurrence_state(self):
        state=fpstate(strict_call_state=True);apply(state,xmem(rt=29,rn=29))
        copy=state.copy();apply(copy,xmem(True,0,0,29))
        self.assertEqual(copy.registers[0],Value('stack',displacement=-24))
        with self.assertRaises(ModelError):apply(copy,0x94000001)
        apply(copy,xmem(rt=31,rn=29));self.assertNotEqual(state.loop_key(True,0),copy.loop_key(True,0))
        self.assertEqual(state._stack_pointer_slots,{-24})

    def test_retired_fp_slots_do_not_resurrect_after_reallocation(self):
        state=fpstate();apply(state,xmem(rt=19,rn=29))
        apply(state,0x910083ff) # ADD SP,SP,32
        with self.assertRaises(ModelError):apply(state,xmem(True,19,0,29))
        apply(state,0xd10083ff) # SUB SP,SP,32, old slot remains absent
        with self.assertRaises(ModelError):apply(state,xmem(True,19,0,29))
        self.assertEqual((state.memory,state.words,state._stack_pointer_slots),({},{},set()))

    def test_known_unknown_flags_and_unrelated_registers_are_preserved(self):
        for flags in (None,(False,True,True,False)):
            state=fpstate(flags=flags);before=state.registers.copy()
            apply(state,xmem(rt=19,rn=29));apply(state,xmem(True,19,0,29))
            self.assertEqual(state.flags,flags);self.assertEqual(state.registers,before)


class FPXFrameTests(unittest.TestCase):
    def test_complete_fp_save_load_call_witness_has_original_bl_scope(self):
        result=call_result(FRAME_WORDS)
        self.assertEqual((result.verdict,result.scope),('agreement','synchronous_call_sites'))
        self.assertEqual(result.checked_pcs,(BASE+32,))

    def test_x29_load_body_refuses_while_store_keeps_pointer_escape(self):
        result=call_result((*PAIR_PRO,xmem(True,29,0,29),CALL,*PAIR_EPI))
        self.assertEqual(result.reason_codes,('cfg_frame_transition_not_modeled',))
        result=call_result((*PAIR_PRO,xmem(rt=29,rn=29),CALL,*PAIR_EPI))
        self.assertEqual(result.reason_codes,('stack_address_escapes_call',))

    def test_known_wrong_recovery_and_unknown_recovery_remain_distinct(self):
        wrong=call_result((*PAIR_PRO,xmem(True,19,0,29),CALL,*PAIR_EPI))
        self.assertEqual((wrong.verdict,wrong.scope),('inconsistency','synchronous_call_sites'))
        self.assertTrue(any(e.expected=='original x19' and e.observed=='original x29' for e in wrong.evidence))
        unknown=call_result((*PAIR_PRO,xmem(True,0,0,29),0x9ac10813,CALL,*PAIR_EPI))
        self.assertEqual((unknown.verdict,unknown.reason_codes),('unresolved',('unknown_recovery_value',)))

    def test_affected_work_budgets(self):
        for limits,reason in ((replace(Limits(),max_cfg_steps_per_function=3),'cfg_work_limit'),
                              (replace(Limits(),max_instructions_per_function=4),'function_instruction_limit')):
            result=call_result(FRAME_WORDS,limits=limits)
            self.assertEqual((result.verdict,result.reason_codes),('unresolved',(reason,)))
