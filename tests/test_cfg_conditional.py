"""Owned literal conditional restore transfers, no target execution."""
from dataclasses import replace
import unittest
from airs.cfg import audit_current_function
from airs.types import Limits
from test_cfg_calls import PRO,CALL,call_fixture
from test_dwarf_cfg import image_for,CFI
from test_audit import fixture,RET,NOP
POP=0xa9407bfd
ADD16=0x910043ff
FRAME=(*PRO,CALL,POP,0x5400006c,ADD16,RET,ADD16,RET)
LEAF=(0xd10083ff,0x71001c1f,NOP,ADD16,0x5400006c,ADD16,RET,ADD16,RET)
def frame(words=FRAME):return audit_current_function(*call_fixture(words))
def dwarf(words=FRAME,program=CFI,limits=Limits()):return audit_current_function(*image_for(words,program),limits)
def leaf(words=LEAF):return audit_current_function(*fixture(words,0x02002000))

class ConditionalTeardownTests(unittest.TestCase):
    def test_frame_both_teardown_successors_restore_without_merging(self):
        r=frame();self.assertEqual((r.verdict,r.checked_pcs),('agreement',(0x1008,)))
        self.assertTrue(any(e.code=='cfg_conditional_teardown' for e in r.evidence))
        self.assertTrue(any(e.code=='cfg_paths_checked' and '2 terminal paths' in e.message for e in r.evidence))
    def test_leaf_excludes_prefix_conditional_and_both_suffixes(self):
        r=leaf();self.assertEqual((r.verdict,r.checked_pcs),('agreement',(0x1004,0x1008)))
    def test_postcall_flags_are_unknown_even_after_known_pre_call_compare(self):
        words=(*PRO,0xd2800100,0x71001c1f,CALL,POP,0x5400006c,ADD16,RET,ADD16,RET)
        r=frame(words);self.assertEqual(r.verdict,'agreement')
        self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_known_leaf_gt_and_le_conditions_choose_one_terminal(self):
        for condition in (0x5400006c,0x5400006d):
            words=(0xd10083ff,0xd2800100,0x71001c1f,NOP,ADD16,condition,ADD16,RET,ADD16,RET)
            r=leaf(words);self.assertEqual(r.verdict,'agreement')
            self.assertTrue(any('1 terminal paths' in e.message for e in r.evidence))
    def test_fde_recovers_original_bl_pc_before_teardown_fork(self):
        r=dwarf();self.assertEqual((r.verdict,r.coverage,r.scope),('agreement','dwarf_evaluated','synchronous_call_sites'))
        self.assertTrue(any(e.code=='dwarf_cfi_row' and e.address==0x1008 for e in r.evidence))
    def test_possible_bad_return_overrides_known_recovery_mismatch(self):
        words=list(FRAME);words[7]=0x910083ff
        r=dwarf(words,CFI+bytes.fromhex('081e'))
        self.assertEqual((r.verdict,r.reason_codes),('unresolved',('unmodeled_stack_alignment',)))
    def test_leaf_different_successor_totals_cannot_be_accepted(self):
        words=list(LEAF);words[7]=0x910083ff
        self.assertEqual(leaf(words).verdict,'unresolved')
        # Ordinary branch entry must require full deallocation on BOTH successors.
        words=(0xd10083ff,0x14000002,NOP,ADD16,0x5400006c,ADD16,RET,0x910083ff,RET)
        self.assertEqual(leaf(words).reason_codes,('cfg_edge_not_modeled',))
    def test_one_successor_body_or_outside_or_setup_is_not_teardown_transfer(self):
        words=list(FRAME);words[5]=0xd2800000
        self.assertEqual(frame(words).verdict,'unresolved')
        for branch in (0x54ffff8c,0x540000ac,0x5400080c):
            words=list(FRAME);words[4]=branch
            with self.subTest(branch=branch):self.assertEqual(frame(words).verdict,'unresolved')
    def test_nop_only_prefix_and_body_interior_entry_do_not_gain_permission(self):
        words=list(FRAME);words[3]=NOP
        self.assertEqual(frame(words).verdict,'unresolved')
        words=(*PRO,0x71001c1f,0x540000ec,CALL,POP,0x5400006c,ADD16,RET,ADD16,RET)
        self.assertEqual(frame(words).reason_codes,('cfg_edge_not_modeled',))
    def test_known_condition_does_not_hide_invalid_dead_target(self):
        words=(0xd10083ff,0xd2800100,0x71001c1f,NOP,ADD16,0x5400080c,ADD16,RET,ADD16,RET)
        self.assertEqual(leaf(words).verdict,'unresolved')
    def test_unknown_recovery_dominates_and_known_cfi_witness_survives_cap(self):
        self.assertEqual(dwarf(program=CFI+bytes.fromhex('081e0713')).reason_codes,('unknown_recovery_value',))
        r=dwarf(program=CFI+bytes.fromhex('081e'),limits=replace(Limits(),max_evidence_per_function=1))
        self.assertEqual((r.verdict,r.evidence[0].expected),('inconsistency','original x30'))
    def test_fork_consumes_path_and_visit_limits(self):
        for change in ({'max_cfg_paths_per_function':1},{'max_cfg_steps_per_function':7},{'max_evidence_per_function':0}):
            with self.subTest(change=change):self.assertEqual(dwarf(limits=replace(Limits(),**change)).verdict,'unresolved')
    def test_unsupported_condition_and_dead_instruction_stay_unknown(self):
        words=list(FRAME);words[4]=0x5400006e # AL remains outside the condition subset
        self.assertEqual(frame(words).verdict,'unresolved')
        self.assertEqual(frame((*FRAME,0xffffffff)).verdict,'unresolved')

    def test_chained_conditional_prefixes_keep_conservative_paths_bounded(self):
        words=(*PRO,CALL,POP,0x540000ac,0x910003ff,0x5400006c,ADD16,RET,ADD16,RET)
        r=frame(words);self.assertEqual(r.verdict,'agreement')
        self.assertTrue(any(e.code=='cfg_conditional_teardown' and '2 EQ–LE' in e.message for e in r.evidence))
        self.assertTrue(any('3 terminal paths' in e.message for e in r.evidence))

    def test_known_leaf_condition_may_skip_recognized_bad_pop_after_fallthrough_entry(self):
        # The ordinary body falls through to the restore prefix. Known GT skips
        # a recognized but over-popping suffix; no branch enters the partial root.
        words=(0xd10083ff,0xd2800100,0x71001c1f,NOP,ADD16,0x5400006c,0x910083ff,RET,ADD16,RET)
        self.assertEqual(leaf(words).verdict,'agreement')
