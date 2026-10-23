"""Focused W RBIT semantics; tiny typed data only, no compiled workload."""
from dataclasses import replace
import unittest
from airs import ANALYSIS_MODEL_VERSION
from airs.arm64 import ModelError, Value, original
from airs.cfg import PathState, decode_instruction, audit_current_function
from airs.report import validate_report
from airs.types import InputError, Limits
from test_rbit_x_candidate import fixture, call_result, PRO, EPI, PAIR_PRO, PAIR_EPI, CALL, RET
from test_rbit_v33_integration import report_for
from test_report_v32_admission_candidate import synthetic_report

MODEL='arm64-bounded-w-rbit-v38'
def rbit(rd=0,rn=1): return 0x5ac00000 | (rn<<5) | rd

class RBITWTests(unittest.TestCase):
    def test_literal_width_projection_and_independent_bit_positions(self):
        vectors=[(0,0),(1,0x80000000),(0x80000000,1),(-1,0xffffffff),
                 (0x01234567,0xe6a2c480),(1<<32,0),((1<<40)|1,0x80000000)]
        vectors += [(1<<bit,1<<(31-bit)) for bit in range(32)]
        for value,expected in vectors:
            state=PathState();state.registers[1]=Value('constant',value)
            instruction=decode_instruction(rbit());self.assertEqual(instruction.kind,'wrbit')
            state.apply(instruction);self.assertEqual(state.read_register(0),Value('constant',expected))
    def test_alias_reads_old_source_and_zeros_upper_half(self):
        state=PathState();state.registers[0]=Value('constant',0xffff000000000001)
        state.apply(decode_instruction(rbit(0,0)))
        self.assertEqual(state.read_register(0),Value('constant',0x80000000))
    def test_zr_discard_flags_and_unrelated_state(self):
        state=PathState(sp=Value('stack',displacement=-16),memory={-16:original(19)},words={-8:Value('constant',7)},flags=(False,True,True,False))
        before=state.copy();state.apply(decode_instruction(rbit(31,1)))
        self.assertEqual(state.loop_key(True,0),before.loop_key(True,0))
        state.apply(decode_instruction(rbit(0,31)))
        self.assertEqual(state.read_register(0),Value('constant',0))
        self.assertEqual(state.sp,before.sp);self.assertEqual(state.memory,before.memory)
        self.assertEqual(state.words,before.words);self.assertEqual(state.flags,before.flags)
        self.assertTrue(state.condition(0))
    def test_symbolic_input_never_recovers_identity(self):
        for source in (original(1),Value('unknown','call result')):
            state=PathState();state.registers[1]=source
            state.apply(decode_instruction(rbit()));state.apply(decode_instruction(rbit(0,0)))
            self.assertEqual(state.read_register(0).kind,'unknown')
    def test_raw_stack_refused_before_projection_even_if_discarded(self):
        for strict in (False,True):
            for rd in (0,31):
                state=PathState(strict_call_state=strict);state.registers[1]=Value('stack',displacement=-16)
                with self.assertRaises(ModelError) as error:state.apply(decode_instruction(rbit(rd)))
                self.assertEqual(error.exception.code,'rbit_stack_address_not_modeled')
    def test_fixed_bit_neighbors_and_x_form(self):
        self.assertEqual(decode_instruction(0xdac00020).kind,'xrbit')
        for bit in range(10,31):
            try:instruction=decode_instruction(rbit()^(1<<bit))
            except ModelError:continue
            self.assertNotEqual(instruction.kind,'wrbit')
        for word in (0x5ac00420,0x5ac00820,0x5ac01420,0x93000000):
            with self.assertRaises(ModelError):decode_instruction(word)
    def test_prepared_body_sequences_as_typed_data(self):
        for words in ((0xd2800020,0x5ac00000,RET),(0x5ac00008,0x5ac01100,RET),(0x5ac003e0,RET),(0xdac00008,0xdac01100,RET)):
            result=audit_current_function(*fixture(words))
            self.assertEqual((result.verdict,result.scope),('agreement','modeled_leaf_body'))
            self.assertEqual(result.checked_pcs,tuple(0x1000+4*i for i in range(len(words)-1)))
    def test_nonrestoring_callee_saved_and_fp_writes_decline(self):
        result=audit_current_function(*fixture((rbit(19,0),RET)))
        self.assertEqual(result.verdict,'unresolved')
        result=call_result((*PRO,rbit(29,0),CALL,*EPI))
        self.assertEqual(result.reason_codes,('cfg_frame_transition_not_modeled',))
    def test_call_witness_has_zero_extended_concrete_value(self):
        result=call_result((*PAIR_PRO,0xd2800020,rbit(19,0),CALL,*PAIR_EPI))
        self.assertEqual((result.verdict,result.scope),('inconsistency','synchronous_call_sites'))
        self.assertEqual(result.checked_pcs,(0x1018,))
        self.assertTrue(any(item.observed=='constant 0x80000000' for item in result.evidence))
    def test_unknown_required_recovery_and_budget_remain_unresolved(self):
        result=call_result((*PAIR_PRO,rbit(19,0),CALL,*PAIR_EPI))
        self.assertEqual(result.verdict,'unresolved')
        result=audit_current_function(*fixture((rbit(),RET)),replace(Limits(),max_cfg_steps_per_function=0))
        self.assertEqual(result.verdict,'unresolved')
    def test_emitted_report_and_exact_new_model_admission(self):
        report=report_for((0x5ac00008,0x5ac01100,RET))
        self.assertEqual(report['generator']['analysis_model_version'],ANALYSIS_MODEL_VERSION)
        self.assertEqual(report['findings'][0]['verdict'],'agreement')
        self.assertIs(validate_report(report),report)
        for model in (MODEL,'arm64-bounded-sdiv-v37'):
            report=synthetic_report(model);report['image']['cpu_subtype']=0x80000000
            with self.assertRaises(InputError):validate_report(report)
        report=synthetic_report(MODEL+'-future');report['image']['cpu_subtype']=0x80000000
        self.assertIs(validate_report(report),report)

    def test_known_model_scope_boundary_recovery_and_dwarf_admission(self):
        for fault in ('boundary','scope','encoding','dwarf'):
            report=synthetic_report(MODEL);finding=report['findings'][0]
            if fault=='boundary':finding['function']['boundary_source']='compact_unwind'
            elif fault=='scope':finding['scope']='modeled_leaf_body'
            elif fault=='encoding':finding['encoding']='0x04000100'
            else:finding.update(mode='dwarf',coverage='dwarf_reference',encoding='0x03000004')
            with self.subTest(fault=fault),self.assertRaises(InputError):validate_report(report)
