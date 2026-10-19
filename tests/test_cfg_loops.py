"""Owned MacScope scalar-loop shape, adapted to existing CMP/B and W arithmetic.
Literal words are independent of the production decoder. Images are never run.
"""
from dataclasses import replace
import struct
import unittest
from airs import cfg
from airs.arm64 import Value
from airs.types import Limits
from airs.types import FunctionRange
from test_audit import BASE, NOP, RET, fixture

# MOV W0,#3; MOV W1,#0; CMP W0,#0; B.EQ exit;
# ADDS W1,W1,W0; SUBS W0,W0,#1; B.NE body; RET.
# MacScope control_flow.s _audit_loop_sum uses CBZ and X ADD; those two
# spellings are adapted to already-supported CMP/B.EQ and W ADDS.
SUM=(0x52800060,0x52800001,0x7100001f,0x54000080,
     0x2b000021,0x71000400,0x54ffffc1,RET)
# W MOVZ uses the existing decoder only if supported; use X MOVZ literals,
# whose later W reads project the same small constants.
SUM=(0xd2800060,0xd2800001,*SUM[2:])

def bne(source, target):
    return 0x54000001 | (((target-source)&0x7ffff)<<5)

SEQUENTIAL=(0xd2800040,0xf1000400,bne(2,1),
            0xd2800041,0xf1000421,bne(5,4),RET)

def check(words=SUM,encoding=0x02000000,limits=Limits(),calls=False):
    return cfg.audit_cfg_function(*fixture(words,encoding),limits=limits,allow_calls=calls)

def evidence(result,code):
    return [e for e in result.evidence if e.code==code]

def call_loop(words, *, owned_target=True, limits=Limits()):
    image,fn,entry=fixture(words,0x04000000)
    if owned_target:
        sink=FunctionRange(fn.end,fn.end+4,'owned_sink','lc_function_starts')
        image=replace(image,data=image.data+struct.pack('<I',RET),functions=(fn,sink),
                      sections=(replace(image.sections[0],size=fn.size+4),),slice_size=fn.size+4)
    return cfg.audit_cfg_function(image,fn,entry,limits=limits,allow_calls=True)

class LoopTests(unittest.TestCase):
    def test_macscope_counter_accumulator_known_zero_one_three(self):
        for count in (0,1,3):
            words=(0xd2800000|(count<<5),*SUM[1:])
            result=check(words)
            self.assertEqual(result.verdict,'agreement',result)
            self.assertTrue(evidence(result,'cfg_loop_checked'))
            self.assertEqual(result.scope,'modeled_leaf_body')
            if count==0:self.assertNotIn(BASE+16,result.checked_pcs)
            else:self.assertIn(BASE+24,result.checked_pcs)

    def test_unknown_counter_reaches_exact_full_state_fixed_point_and_exit(self):
        result=check((NOP,*SUM[1:]))
        self.assertEqual(result.verdict,'agreement',result)
        self.assertTrue(any('exact recurrent' in e.message for e in evidence(result,'cfg_loop_checked')))
        self.assertLess(result.cfg_steps,100)

    def test_snapshot_retains_register_sp_memory_words_flags_mode_and_certainty(self):
        baseline=cfg.PathState(); key=baseline.loop_key(True,0)
        mutations=(lambda s:s.registers.__setitem__(0,Value('constant',1)),
                   lambda s:setattr(s,'sp',Value('stack',0,-16)),
                   lambda s:s._store(-8,Value('constant',1)),
                   lambda s:s.words.__setitem__(-4,Value('constant',1)),
                   lambda s:setattr(s,'flags',(False,True,True,False)),
                   lambda s:setattr(s,'strict_call_state',True))
        for mutate in mutations:
            state=baseline.copy();mutate(state)
            self.assertNotEqual(key,state.loop_key(True,0))
        self.assertNotEqual(key,baseline.loop_key(False,0))
        self.assertNotEqual(key,baseline.loop_key(True,1))
        self.assertEqual(baseline.loop_key(True,1),baseline.loop_key(True,2))
        self.assertEqual(key,baseline.copy().loop_key(True,0))

    def test_changing_counter_never_closes_by_recovery_only_projection(self):
        result=check(limits=replace(Limits(),max_cfg_paths_per_function=1))
        self.assertEqual(result.verdict,'unresolved')
        self.assertEqual(result.reason_codes,('cfg_loop_state_limit',))

    def test_work_observation_and_path_budgets_still_decline(self):
        for limits in (replace(Limits(),max_cfg_steps_per_function=5),
                       replace(Limits(),max_observations_per_function=5),
                       replace(Limits(),max_cfg_paths_per_function=0)):
            self.assertEqual(check(limits=limits).verdict,'unresolved')
        self.assertEqual(check((NOP,*SUM[1:]),limits=replace(Limits(),max_cfg_paths_per_function=1)).verdict,'unresolved')

    def test_later_iteration_known_discrepancy_keeps_concrete_witness(self):
        # Save x19 in x9; counter2; first iteration sees original x19,
        # then x19=7. Restore before RET. Second header sees known mismatch.
        words=(0xaa1303e9,0xd2800040,0xd28000f3,0xf1000400,0x54ffffc1,0xaa0903f3,RET)
        result=check(words)
        self.assertEqual(result.verdict,'inconsistency',result)
        self.assertTrue(any(e.expected and e.observed for e in evidence(result,'caller_state_mismatch')))
        self.assertTrue(evidence(result,'cfg_loop_checked'))

    def test_possible_only_discrepancy_stays_unresolved(self):
        # Unknown condition enters loop through uncertain taken predecessor.
        words=(0xaa1303e9,0xf100001f,0x54000040,0x14000004,
               0xd28000f3,0xf1000400,0x54ffffc1,0xaa0903f3,RET)
        result=check(words)
        self.assertEqual(result.verdict,'unresolved',result)
        self.assertEqual(result.reason_codes,('cfg_path_feasibility_unknown',))

    def test_unknown_recovery_dominates_known_discrepancy(self):
        words=(0xaa1303e9,0xaa1403ea,0xd2800040,0xd28000f3,0x11000114,0xf1000400,0x54ffffa1,0xaa0903f3,0xaa0a03f4,RET)
        result=check(words)
        self.assertEqual(result.verdict,'unresolved')
        self.assertEqual(result.reason_codes,('unknown_recovery_value',))

    def test_bad_return_identity_is_not_hidden_by_fixed_point(self):
        self.assertEqual(check((0xd28000f3,*SUM[1:])).reason_codes,('unmodeled_return_state',))

    def test_irreducible_middle_entry_rejects(self):
        words=(0x54000040,NOP,NOP,0x54ffffc1,RET)
        self.assertEqual(check(words).reason_codes,('cfg_loop_shape_not_modeled',))

    def test_two_sequential_backedges_now_agree(self):
        words=(NOP,0x54ffffe1,NOP,0x54ffffe1,RET)
        result=check(words)
        self.assertEqual(result.verdict,'agreement',result)
        self.assertTrue(any('2 decoded natural loop(s)' in e.message for e in evidence(result,'cfg_loop_checked')))

    def test_two_sequential_natural_loops_retain_both_exits(self):
        result=check(SEQUENTIAL)
        self.assertEqual(result.verdict,'agreement',result)
        self.assertEqual(result.scope,'modeled_leaf_body')
        self.assertEqual(result.checked_pcs,tuple(BASE+4*i for i in range(6)))
        self.assertTrue(any('2 decoded natural loop(s)' in e.message for e in evidence(result,'cfg_loop_checked')))

    def test_second_header_never_reuses_first_header_snapshot(self):
        # Both loops have the same machine state at their headers. Header
        # identity must remain part of recurrence, or the second loop vanishes.
        words=(NOP,0xf100011f,bne(2,1),NOP,0xf100011f,bne(5,4),RET)
        result=check(words)
        self.assertEqual(result.verdict,'agreement',result)
        self.assertIn(BASE+20,result.checked_pcs)
        self.assertTrue(any('2 decoded natural loop(s)' in e.message for e in evidence(result,'cfg_loop_checked')))

    def test_nested_shared_header_and_middle_entry_still_decline(self):
        for words in ((NOP,NOP,bne(2,1),NOP,bne(4,0),RET),
                      (NOP,NOP,bne(2,0),NOP,bne(4,0),RET),
                      (NOP,bne(1,0),bne(2,0),RET)):
            with self.subTest(words=words):
                self.assertEqual(check(words).reason_codes,('cfg_loop_shape_not_modeled',))

    def test_second_loop_changing_state_exhausts_shared_budget(self):
        result=check(SEQUENTIAL,limits=replace(Limits(),max_cfg_paths_per_function=2))
        self.assertEqual(result.verdict,'unresolved')
        self.assertEqual(result.reason_codes,('cfg_loop_state_limit',))

    def test_unknown_recovery_in_second_loop_dominates_known_discrepancy(self):
        words=(0xaa1303e9,0xaa1403ea,0xd2800040,0xf1000400,bne(4,3),
               0xd2800041,0xd28000f3,0x11000114,0xf1000421,bne(9,6),
               0xaa0903f3,0xaa0a03f4,RET)
        result=check(words)
        self.assertEqual(result.verdict,'unresolved',result)
        self.assertEqual(result.reason_codes,('unknown_recovery_value',))

    def test_infinite_unconditional_and_self_cycle_reject(self):
        for words in ((NOP,0x17ffffff,RET),(0x14000000,NOP,RET),(0x54000000,RET)):
            self.assertEqual(check(words).verdict,'unresolved')

    def test_loop_stack_transition_and_unsupported_dead_word_reject(self):
        for words in ((0xd10043ff,0xd10043ff,0x54ffffe1,0x910083ff,RET),
                      (NOP,0xffffffff,0x54ffffe1,RET)):
            self.assertEqual(check(words).verdict,'unresolved')

    def test_owned_direct_call_in_loop_checks_original_bl_and_closes_recurrence(self):
        # BL targets the independently known sink immediately after this function.
        words=(0xa9bf7bfd,0x910003fd,NOP,0x94000004,0x54ffffc1,0xa8c17bfd,RET)
        result=call_loop(words)
        self.assertEqual(result.verdict,'agreement',result)
        self.assertEqual(result.scope,'synchronous_call_sites')
        self.assertEqual(result.checked_pcs,(BASE+12,))
        self.assertTrue(evidence(result,'cfg_loop_checked'))
        self.assertTrue(evidence(result,'cfg_call_site'))

    def test_call_loop_without_independent_target_remains_unresolved(self):
        words=(0xa9bf7bfd,0x910003fd,NOP,0x94000004,0x54ffffc1,0xa8c17bfd,RET)
        self.assertEqual(call_loop(words,owned_target=False).reason_codes,('cfg_call_target_not_modeled',))

    def test_call_loop_bad_compact_rule_has_known_reachable_recovery_witness(self):
        words=(0xa9be7bfd,0x910003fd,NOP,0x94000004,0x54ffffc1,0xa8c27bfd,RET)
        result=call_loop(words)
        self.assertEqual(result.verdict,'inconsistency',result)
        self.assertEqual(result.checked_pcs,(BASE+12,))
        self.assertTrue(any(e.expected=='entry SP' and e.observed=='entry SP-16'
                            for e in evidence(result,'caller_state_mismatch')))

    def test_call_loop_state_budget_does_not_invent_recovery(self):
        words=(0xa9bf7bfd,0x910003fd,NOP,0x94000004,0x54ffffc1,0xa8c17bfd,RET)
        result=call_loop(words,limits=replace(Limits(),max_cfg_paths_per_function=1))
        self.assertEqual(result.verdict,'unresolved')

    def test_owned_direct_calls_in_both_sequential_loops_retain_original_pcs(self):
        words=(0xa9bf7bfd,0x910003fd,NOP,0x94000009,0xf100011f,bne(5,2),
               NOP,0x94000005,0xf100011f,bne(9,6),0xa8c17bfd,RET)
        result=call_loop(words)
        self.assertEqual(result.verdict,'agreement',result)
        self.assertEqual(result.checked_pcs,(BASE+12,BASE+28))
        self.assertTrue(any('2 decoded natural loop(s)' in e.message for e in evidence(result,'cfg_loop_checked')))

    def test_recurrent_path_without_supported_return_cannot_agree(self):
        # Condition fixed true produces no RET path despite a syntactic exit.
        words=(0xd2800000,0xf100001f,0x54ffffe0,RET)
        result=check(words)
        self.assertEqual(result.verdict,'unresolved',result)
        self.assertEqual(result.reason_codes,('no_supported_observation',))

    def test_transient_mismatch_not_erased_by_later_exact_recurrence(self):
        words=(0xaa1303e9,0xd28000f3,0xaa0903f3,0xf100011f,0x54ffffc1,RET)
        result=check(words)
        self.assertEqual(result.verdict,'inconsistency',result)
        self.assertTrue(any(e.address==BASE+8 for e in evidence(result,'caller_state_mismatch')))
        self.assertTrue(any('exact recurrent' in e.message for e in evidence(result,'cfg_loop_checked')))

    def test_unknown_sibling_bad_exit_is_not_hidden_by_recurrent_path(self):
        words=(0xaa1303e9,0xf100011f,0x54000060,0xaa0903f3,RET,
               0xd28000f3,0xf100011f,0x54ffffc1,RET)
        result=check(words)
        self.assertEqual(result.verdict,'unresolved',result)
        self.assertEqual(result.reason_codes,('unmodeled_return_state',))

    def test_missing_metadata_and_wrong_subtype_boundaries_retained(self):
        image,fn,entry=fixture(SUM,0x02000000)
        self.assertEqual(cfg.audit_cfg_function(image,fn,None).coverage,'none')
        self.assertEqual(cfg.audit_cfg_function(replace(image,cpu_subtype=2),fn,entry).verdict,'unresolved')

if __name__=='__main__':unittest.main()
