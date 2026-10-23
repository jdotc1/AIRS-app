"""Bounded X UDIV: retained bytes and independent arithmetic/recovery controls."""
from dataclasses import replace
import unittest
from airs import ANALYSIS_MODEL_VERSION
from airs.arm64 import ModelError, Value, original
from airs.cfg import PathState, audit_current_function, decode_instruction
from airs.report import validate_report
from airs.types import InputError, Limits
from test_rbit_x_candidate import fixture, call_result, BASE, RET, PRO, EPI, PAIR_PRO, PAIR_EPI, CALL
from test_report_v32_admission_candidate import synthetic_report

MASK = (1 << 64) - 1
WITNESS = (0x9ac10800, RET)  # retained O2 0x3b8..0x3c0, compact 0x02000000


def word(rd=0, rn=1, rm=2):
    return 0x9ac00800 | (rm << 16) | (rn << 5) | rd


def quotient_oracle(n, d):
    """64 fixed long-division steps; no host divide or candidate helper."""
    n, d = n & MASK, d & MASK
    if d == 0:
        return 0
    q = r = 0
    for bit in range(63, -1, -1):
        r = (r << 1) | ((n >> bit) & 1)
        if r >= d:
            r -= d
            q |= 1 << bit
    return q


class UDIVXTests(unittest.TestCase):
    def instruction(self, rd=0, rn=1, rm=2):
        ins = decode_instruction(word(rd, rn, rm), BASE)
        self.assertEqual((ins.kind, ins.rd, ins.rn, ins.rt2), ('xudiv', rd, rn, rm))
        return ins

    def test_unsigned_edges_and_independent_long_division(self):
        ins = self.instruction()
        values = ((0,0,0), (19,0,0), (0,9,0), (7,1,7), (2,3,0), (9,9,1), (19,3,6),
                  (MASK,1,MASK), (MASK,2,0x7fffffffffffffff), (1<<63,3,0x2aaaaaaaaaaaaaaa),
                  (MASK,MASK,1), (-1,2,0x7fffffffffffffff), (1<<64,2,0), (19,(1<<64)+3,6))
        for a,b,expected in values:
            with self.subTest(a=a,b=b):
                self.assertEqual(quotient_oracle(a,b), expected)
                state = PathState()
                state.registers[1],state.registers[2] = Value('constant',a),Value('constant',b)
                state.apply(ins)
                self.assertEqual(state.registers[0],Value('constant',expected))
        # Small, fixed edge set; no random sweep or real-binary corpus.
        for a,b in ((0x123456789abcdef0,17),(MASK,0x8000000000000001),(1<<63,1<<32)):
            state=PathState();state.registers[1]=Value('constant',a);state.registers[2]=Value('constant',b)
            state.apply(ins)
            self.assertEqual(state.registers[0],Value('constant',quotient_oracle(a,b)))

    def test_aliases_capture_both_old_operands(self):
        for rd,rn,rm,a,b,expected in ((1,1,2,19,3,6),(2,1,2,19,3,6),(1,1,1,9,9,1),(1,1,1,0,0,0)):
            state=PathState();state.registers[rn]=Value('constant',a);state.registers[rm]=Value('constant',b)
            state.apply(self.instruction(rd,rn,rm))
            self.assertEqual(state.registers[rd],Value('constant',expected))

    def test_zero_register_positions_and_discard_preserve_unrelated_state(self):
        for rd,rn,rm in ((0,31,2),(0,1,31),(31,1,2),(31,31,31)):
            state=PathState(sp=Value('stack',displacement=-16),memory={-16:original(29)})
            state.registers[1]=Value('constant',19);state.registers[2]=Value('constant',3)
            before=state.registers.copy();memory=state.memory.copy()
            state.apply(self.instruction(rd,rn,rm))
            if rd==31:self.assertEqual(state.registers,before)
            else:self.assertEqual(state.registers[rd],Value('constant',0))
            self.assertEqual(state.sp,Value('stack',displacement=-16));self.assertEqual(state.memory,memory)

    def test_either_raw_stack_source_declines_before_zero_or_discard(self):
        for strict in (False,True):
            for source in (1,2):
                for rd in (0,31):
                    state=PathState(strict_call_state=strict)
                    state.registers[1]=state.registers[2]=Value('constant',0)
                    state.registers[source]=Value('stack',displacement=0)
                    with self.assertRaises(ModelError) as error:state.apply(self.instruction(rd))
                    self.assertEqual(error.exception.code,'udiv_stack_address_not_modeled')

    def test_unknown_and_original_do_not_simplify_even_with_zero(self):
        for source in (1,2):
            for raw in (original(source),Value('unknown','unknown input')):
                state=PathState();state.registers[1]=state.registers[2]=Value('constant',0)
                state.registers[source]=raw;state.apply(self.instruction())
                self.assertEqual(state.registers[0].kind,'unknown')
        state=PathState();state.apply(self.instruction(0,1,1))
        self.assertEqual(state.registers[0].kind,'unknown')

    def test_known_and_unknown_flags_survive_condition_consumers(self):
        for flags in (None,(False,True,True,False),(True,False,False,True)):
            state=PathState(flags=flags);state.registers[1]=Value('constant',19);state.registers[2]=Value('constant',3)
            conditions=tuple(state.condition(c) for c in range(14))
            state.apply(self.instruction())
            self.assertEqual(state.flags,flags)
            self.assertEqual(tuple(state.condition(c) for c in range(14)),conditions)

    def test_exact_fixed_controls_and_w_signed_neighbors(self):
        self.instruction()
        for bit in tuple(range(10,16))+tuple(range(21,32)):
            try:ins=decode_instruction(word() ^ (1<<bit),BASE)
            except ModelError:continue
            self.assertNotEqual(ins.kind,'xudiv')
        for neighbor in (0x1ac10800,0x1ac10c00):
            with self.assertRaises(ModelError):decode_instruction(neighbor,BASE)

    def test_complete_retained_function_has_bounded_leaf_agreement(self):
        result=audit_current_function(*fixture(WITNESS))
        self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','compact','modeled_leaf_body'))
        self.assertEqual(result.checked_pcs,(BASE,));self.assertEqual(result.instruction_count,2)
        for neighbor in (0x1ac10800,0x1ac10c00):
            result=audit_current_function(*fixture((neighbor,RET)))
            self.assertEqual(result.verdict,'unresolved');self.assertEqual(result.checked_pcs,())

    def test_frame_and_unrestored_callee_saved_writes_decline(self):
        result=call_result((*PRO,word(29,0,1),CALL,*EPI))
        self.assertEqual(result.reason_codes,('cfg_frame_transition_not_modeled',))
        result=audit_current_function(*fixture((word(19,0,1),RET)))
        self.assertEqual((result.verdict,result.reason_codes),('unresolved',('unmodeled_return_state',)))

    def test_call_recovery_known_correct_wrong_and_unknown(self):
        words=(*PAIR_PRO,0xd2800260,0xd2800061,word(19,0,1),CALL,*PAIR_EPI)
        correct=call_result(words,encoding=0x04000001)
        self.assertEqual((correct.verdict,correct.scope),('agreement','synchronous_call_sites'))
        wrong=call_result(words,encoding=0x04000000)
        self.assertEqual((wrong.verdict,wrong.scope),('inconsistency','synchronous_call_sites'))
        self.assertEqual(wrong.checked_pcs,(BASE+28,))
        self.assertTrue(any(e.observed=='constant 0x6' for e in wrong.evidence))
        unknown=call_result((*PAIR_PRO,word(19,19,0),CALL,*PAIR_EPI),encoding=0x04000000)
        self.assertEqual((unknown.verdict,unknown.reason_codes),('unresolved',('unknown_recovery_value',)))

    def test_possible_only_and_later_unknown_keep_unresolved_precedence(self):
        concrete=(0xd2800260,0xd2800061,word(19,0,1))
        possible=call_result((*PAIR_PRO,0x54000080,*concrete,CALL,*PAIR_EPI),encoding=0x04000000)
        self.assertEqual((possible.verdict,possible.reason_codes),('unresolved',('cfg_path_feasibility_unknown',)))
        later=call_result((*PAIR_PRO,*concrete,CALL,word(19,0,1),CALL,*PAIR_EPI),encoding=0x04000000,
                          limits=replace(Limits(),max_evidence_per_function=1))
        self.assertEqual((later.verdict,later.reason_codes),('unresolved',('unknown_recovery_value',)))

    def test_v34_identity_and_exact_import_admission(self):
        self.assertEqual(ANALYSIS_MODEL_VERSION,'arm64-bounded-equivalent-compact-v39')
        for model in ('arm64-bounded-udiv-v34','arm64-bounded-rbit-v33','arm64-bounded-clz-v32'):
            report=synthetic_report(model);report['image']['cpu_subtype']=0x80000000
            with self.assertRaises(InputError):validate_report(report)
        future=synthetic_report('arm64-bounded-udiv-v34-future');future['image']['cpu_subtype']=0x80000000
        self.assertIs(validate_report(future),future)


class UDIVBoundaryTests(unittest.TestCase):
    def test_cfi_recovery_retains_original_call_pc(self):
        from airs.dwarf_cfi import CFITable, FDE, Row
        image,function,entry=fixture((*PRO,word(0,0,1),CALL,*EPI),with_callee=True)
        rules={r:('same',0) for r in range(19,31)}
        framed=rules.copy();framed[29],framed[30]=('offset',-16),('offset',-8)
        rows=(Row(BASE,(31,0),rules),Row(BASE+8,(29,16),framed))
        table=CFITable({4:FDE(4,0,function.start,function.end,rows)},frozenset())
        result=audit_current_function(image,function,replace(entry,encoding=0x03000004),cfi_table=table)
        self.assertEqual((result.verdict,result.coverage,result.scope),('agreement','dwarf_evaluated','synchronous_call_sites'))
        self.assertEqual(result.checked_pcs,(BASE+12,))

    def test_unreachable_unsupported_and_small_work_limits_stay_unresolved(self):
        result=audit_current_function(*fixture((0x14000002,0x1ac10c00,*WITNESS)))
        self.assertEqual(result.verdict,'unresolved');self.assertEqual(result.checked_pcs,())
        for limits,reason in ((replace(Limits(),max_cfg_steps_per_function=0),'cfg_work_limit'),
                              (replace(Limits(),max_instructions_per_function=1),'function_instruction_limit')):
            result=audit_current_function(*fixture(WITNESS),limits)
            self.assertEqual((result.verdict,result.reason_codes),('unresolved',(reason,)))
            self.assertEqual(result.checked_pcs,())
