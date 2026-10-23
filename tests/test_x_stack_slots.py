"""New SP-relative X memory semantics; retained owned words are data only."""
from dataclasses import replace
import unittest
from airs.arm64 import ModelError, Value, original
from airs.cfg import PathState, audit_current_function, decode_instruction
from airs.report import validate_report
from airs.types import InputError, Limits
from test_report_v32_admission_candidate import synthetic_report
from test_rbit_x_candidate import fixture, call_result, BASE, RET, PRO, EPI, PAIR_PRO, PAIR_EPI, CALL

SUB16=0xd10043ff
ADD16=0x910043ff
O0_CLZ=(SUB16,0xf90007e0,0xf94007e8,0xdac01108,0xaa0803e0,ADD16,RET)
O0_CTZ=(SUB16,0xf90007e0,0xf94007e8,0xdac00108,0xdac01108,0xaa0803e0,ADD16,RET)
O0_UDIV=(SUB16,0xf90007e0,0xf90003e1,0xf94007e8,0xf94003e9,0x9ac90900,ADD16,RET)


def xmem(load=False, rt=0, offset=0, rn=31):
    assert offset%8==0 and 0<=offset<=32760
    return (0xf9400000 if load else 0xf9000000) | ((offset//8)<<10) | (rn<<5) | rt


def wmem(load=False, rt=0, offset=0):
    return (0xb9400000 if load else 0xb9000000) | ((offset//4)<<10) | (31<<5) | rt


def apply(state, word):
    ins=decode_instruction(word,BASE)
    state.apply(ins)
    return ins


class XStackSlotTests(unittest.TestCase):
    def test_store_load_first_last_and_full_saved_identities(self):
        for reg in (0,19,29,30):
            for offset in (0,24):
                state=PathState(sp=Value('stack',displacement=-32))
                apply(state,xmem(rt=reg,offset=offset))
                state.registers[reg]=Value('constant',123)
                apply(state,xmem(True,reg,offset))
                self.assertEqual(state.registers[reg],original(reg))
                self.assertEqual(state.memory[-32+offset],original(reg))

    def test_exact_decode_scaled_fields_and_neighbor_forms(self):
        for load in (False,True):
            for offset in (0,8,32760):
                ins=decode_instruction(xmem(load,30,offset),BASE)
                self.assertEqual((ins.kind,ins.rd,ins.rn,ins.immediate),('xldr' if load else 'xstr',30,31,offset))
            for bit in range(23,32):
                try:ins=decode_instruction(xmem(load)^1<<bit,BASE)
                except ModelError:continue
                self.assertNotIn(ins.kind,('xstr','xldr'))
        for word in (xmem(rn=0),xmem(True,rn=28),0xf80003e0,0xf84003e0,0xf80087e0,0xf84087e0,
                     0xf8206be0,0x390003e0,0x794003e0,0xfd0003e0):
            with self.subTest(word=hex(word)),self.assertRaises(ModelError):decode_instruction(word,BASE)
        self.assertEqual(decode_instruction(wmem()).kind,'wstr')

    def test_frame_bounds_unknown_sp_and_discarded_bad_reads_decline(self):
        for load in (False,True):
            for sp,offset in ((Value('stack'),0),(Value('stack',displacement=-16),16),
                              (Value('stack',displacement=-16),32760),(Value('unknown','base'),0),
                              (Value('stack',displacement=-15),0)):
                state=PathState(sp=sp)
                with self.subTest(load=load,sp=sp,offset=offset),self.assertRaises(ModelError):apply(state,xmem(load,31,offset))

    def test_zr_zero_store_and_discarded_load_require_known_whole_slot(self):
        state=PathState(sp=Value('stack',displacement=-16))
        with self.assertRaises(ModelError):apply(state,xmem(True,31))
        apply(state,xmem(rt=31));self.assertEqual(state.memory[-16],Value('constant',0))
        before=state.registers.copy();apply(state,xmem(True,31))
        self.assertEqual(state.registers,before);self.assertEqual(state.sp,Value('stack',displacement=-16))
        state.registers[0]=Value('unknown','unknown saved');apply(state,xmem())
        with self.assertRaises(ModelError):apply(state,xmem(True,31))

    def test_x_overwrite_invalidates_both_w_caches_without_touching_neighbor(self):
        state=PathState(sp=Value('stack',displacement=-32))
        state.registers[0]=Value('constant',0xdeadbeef)
        for offset in (0,4,8):apply(state,wmem(rt=0,offset=offset))
        state.registers[0]=Value('constant',0x1122334455667788);apply(state,xmem())
        self.assertEqual(state.words,{ -24:Value('constant',0xdeadbeef) })
        for offset,expected in ((0,0x55667788),(4,0x11223344),(8,0xdeadbeef)):
            apply(state,wmem(True,1,offset));self.assertEqual(state.registers[1],Value('constant',expected))

    def test_either_w_half_invalidates_x_identity_and_pair_read(self):
        for half in (0,4):
            state=PathState(sp=Value('stack',displacement=-16))
            apply(state,xmem(rt=19));apply(state,xmem(rt=20,offset=8));apply(state,wmem(rt=0,offset=half))
            self.assertEqual(state.memory[-16].kind,'unknown')
            with self.assertRaises(ModelError):apply(state,xmem(True,19))
            with self.assertRaises(ModelError):apply(state,0xa94053f3) # LDP x19,x20,[SP]

    def test_two_w_halves_never_synthesize_full_saved_identity(self):
        state=PathState(sp=Value('stack',displacement=-16))
        apply(state,wmem(rt=19));apply(state,wmem(rt=19,offset=4))
        with self.assertRaises(ModelError):apply(state,xmem(True,19))

    def test_pair_and_x_slots_interoperate_in_both_directions(self):
        state=PathState(sp=Value('stack',displacement=-16))
        apply(state,0xa90053f3) # STP x19,x20,[SP]
        apply(state,xmem(True,0));apply(state,xmem(True,1,8))
        self.assertEqual((state.registers[0],state.registers[1]),(original(19),original(20)))
        other=PathState(sp=Value('stack',displacement=-16))
        apply(other,xmem(rt=19));apply(other,xmem(rt=20,offset=8))
        apply(other,0xa94007e0) # LDP x0,x1,[SP]
        self.assertEqual((other.registers[0],other.registers[1]),(original(19),original(20)))

    def test_pointer_slot_escape_full_overwrite_and_partial_write_guards(self):
        for half in (0,4):
            state=PathState(sp=Value('stack',displacement=-16),strict_call_state=True)
            state.registers[0]=Value('stack',displacement=-16);apply(state,xmem())
            state.registers[0]=Value('constant',0)
            with self.assertRaises(ModelError) as error:apply(state,0x94000001)
            self.assertEqual(error.exception.code,'stack_address_escapes_call')
            with self.assertRaises(ModelError) as error:apply(state,wmem(rt=31,offset=half))
            self.assertEqual(error.exception.code,'partial_stack_address_not_modeled')
            apply(state,xmem(rt=31));self.assertEqual(state._stack_pointer_slots,set())
            apply(state,0x94000001) # Full overwrite removed the actual pointer.

    def test_pointer_load_retains_escape_and_w_projection_guard(self):
        state=PathState(sp=Value('stack',displacement=-16),strict_call_state=True)
        state.registers[0]=Value('stack',displacement=-16);apply(state,xmem());state.registers[0]=Value('constant',0)
        apply(state,xmem(True,1));self.assertEqual(state.registers[1],Value('stack',displacement=-16))
        with self.assertRaises(ModelError):apply(state,wmem(True,31))
        with self.assertRaises(ModelError):apply(state,0x94000001)

    def test_deallocate_reallocate_cannot_resurrect_x_w_or_pointer_slots(self):
        state=PathState(sp=Value('stack',displacement=-16),strict_call_state=True)
        state.registers[0]=Value('stack',displacement=-16);apply(state,xmem())
        state.registers[0]=Value('constant',9);apply(state,wmem(rt=0,offset=8))
        apply(state,ADD16);apply(state,SUB16)
        self.assertEqual((state.memory,state.words,state._stack_pointer_slots),({},{},set()))
        for word in (xmem(True,19),wmem(True,1,8)):
            with self.assertRaises(ModelError):apply(state,word)

    def test_copy_loop_key_flags_and_neighbor_memory_preserve_distinct_states(self):
        state=PathState(sp=Value('stack',displacement=-16),flags=(False,True,True,False))
        apply(state,xmem(rt=19));copy=state.copy();before=state.loop_key(True,0)
        apply(copy,xmem(rt=31));self.assertNotEqual(before,copy.loop_key(True,0))
        self.assertEqual(state.memory[-16],original(19));self.assertEqual(state.flags,(False,True,True,False))
        apply(copy,wmem(rt=31,offset=8));self.assertNotEqual(copy.loop_key(True,0),state.loop_key(True,0))
        self.assertEqual(state.words,{})


class XStackRecoveryTests(unittest.TestCase):
    def test_complete_retained_o0_bodies_gain_only_bounded_leaf_scope(self):
        for words in (O0_CLZ,O0_CTZ,O0_UDIV):
            with self.subTest(words=words):
                result=audit_current_function(*fixture(words,0x02001000))
                self.assertEqual((result.verdict,result.scope),('agreement','modeled_leaf_body'))
                self.assertEqual(result.checked_pcs,tuple(BASE+i*4 for i in range(1,len(words)-2)))
                self.assertEqual(result.instruction_count,len(words))

    def test_x29_load_is_frame_effect_but_x29_store_is_not(self):
        load=call_result((*PAIR_PRO,xmem(True,29,16),CALL,*PAIR_EPI))
        self.assertEqual((load.verdict,load.reason_codes),('unresolved',('cfg_frame_transition_not_modeled',)))
        store=call_result((*PAIR_PRO,xmem(rt=29),xmem(rt=20),CALL,*PAIR_EPI),encoding=0x04000001)
        self.assertEqual((store.verdict,store.scope),('agreement','synchronous_call_sites'))

    def test_full_save_modify_restore_and_wrong_recovery_witness(self):
        words=(*PAIR_PRO,xmem(rt=19,offset=8),0xd28000d3,xmem(True,19,8),CALL,*PAIR_EPI)
        result=call_result(words,encoding=0x04000000)
        self.assertEqual((result.verdict,result.scope),('agreement','synchronous_call_sites'))
        wrong=call_result((*PAIR_PRO,xmem(rt=19,offset=8),0xd28000d3,CALL,*PAIR_EPI),encoding=0x04000000)
        self.assertEqual((wrong.verdict,wrong.scope),('inconsistency','synchronous_call_sites'))
        self.assertTrue(any(e.expected=='original x19' and e.observed=='constant 0x6' for e in wrong.evidence))
        unknown=call_result((*PAIR_PRO,xmem(rt=19,offset=8),0x9ac00a73,CALL,*PAIR_EPI),encoding=0x04000000)
        self.assertEqual((unknown.verdict,unknown.reason_codes),('unresolved',('unknown_recovery_value',)))

    def test_new_memory_operations_remain_bounded_and_bad_reads_unresolved(self):
        for limits,reason in ((replace(Limits(),max_cfg_steps_per_function=1),'cfg_work_limit'),
                              (replace(Limits(),max_instructions_per_function=3),'function_instruction_limit'),
                              (replace(Limits(),max_observations_per_function=1),'observation_limit')):
            result=audit_current_function(*fixture(O0_CLZ,0x02001000),limits)
            self.assertEqual((result.verdict,result.reason_codes),('unresolved',(reason,)))
        result=audit_current_function(*fixture((SUB16,xmem(True,31),ADD16,RET),0x02001000))
        self.assertEqual((result.verdict,result.reason_codes),('unresolved',('unknown_stack_read',)))

    def test_v35_memory_model_retains_exact_import_admission(self):
        report=synthetic_report('arm64-bounded-x-stack-v35')
        self.assertIs(validate_report(report),report)
        report['image']['cpu_subtype']=0x80000000
        with self.assertRaises(InputError):validate_report(report)


class XStackFlowTests(unittest.TestCase):
    def test_counted_loop_carries_x_slot_state_to_exit(self):
        # SUB SP16; MOV X0,2; STR; loop:LDR; SUBS X0,1; STR;
        # B.NE loop; ADD SP16; RET. Literal backward branch -12 bytes.
        words=(SUB16,0xd2800040,0xf90003e0,0xf94003e0,0xf1000400,0xf90003e0,0x54ffffa1,ADD16,RET)
        result=audit_current_function(*fixture(words,0x02001000))
        self.assertEqual((result.verdict,result.scope),('agreement','modeled_leaf_body'))
        self.assertTrue(any(e.code=='cfg_loop_checked' for e in result.evidence))
        limited=audit_current_function(*fixture(words,0x02001000),replace(Limits(),max_cfg_steps_per_function=5))
        self.assertEqual((limited.verdict,limited.reason_codes),('unresolved',('cfg_work_limit',)))

    def test_unknown_branch_distinct_local_slot_keeps_possible_mismatch_unresolved(self):
        # A 48-byte frame leaves SP+16 local. Pair saves remain untouched on
        # both paths, so an uncertain local quotient cannot be hidden by return failure.
        pro=(0xd100c3ff,0xa9004ff4,0xa9027bfd,0x910083fd)
        epi=(0xa9427bfd,0xa9404ff4,0x9100c3ff,RET)
        words=(*pro,xmem(rt=19,offset=16),0x54000060,0xd28000c0,xmem(rt=0,offset=16),xmem(True,19,16),CALL,*epi)
        result=call_result(words,encoding=0x04000000)
        self.assertEqual((result.verdict,result.reason_codes),('unresolved',('cfg_path_feasibility_unknown',)))
        self.assertEqual(result.checked_pcs,())

    def test_function_call_pointer_store_partial_and_full_overwrite(self):
        setup=(*PAIR_PRO,0x910003e0,xmem(rt=0),0xd2800000)
        escaped=call_result((*setup,CALL,*PAIR_EPI),encoding=0x04000001)
        self.assertEqual(escaped.reason_codes,('stack_address_escapes_call',))
        partial=call_result((*setup,wmem(rt=31),CALL,*PAIR_EPI),encoding=0x04000001)
        self.assertEqual(partial.reason_codes,('partial_stack_address_not_modeled',))
        restored=call_result((*setup,xmem(rt=20),CALL,*PAIR_EPI),encoding=0x04000001)
        self.assertEqual((restored.verdict,restored.scope),('agreement','synchronous_call_sites'))
