"""Differing disjoint return teardowns as owned literal instructions."""
from dataclasses import replace
import unittest
from airs.cfg import audit_current_function
from airs.types import Limits
from test_cfg_calls import PRO,EPI,CALL,call_fixture,PAIR_PRO
from test_dwarf_cfg import image_for,CFI
from test_audit import fixture,RET,NOP

OFFSET_POP=(0xa9407bfd,0x910043ff,RET)
FRAME=(*PRO,0x71001c1f,0x5400008c,CALL,*EPI,CALL,*OFFSET_POP)
LEAF=(0xd10083ff,0x71001c1f,0x5400008c,NOP,0x910083ff,RET,NOP,0x910043ff,0x910043ff,RET)
def frame(words=FRAME):return audit_current_function(*call_fixture(words))
def dwarf(words=FRAME,program=CFI,limits=Limits()):return audit_current_function(*image_for(words,program),limits)
def leaf(words=LEAF):return audit_current_function(*fixture(words,0x02002000))

class TeardownCFGTests(unittest.TestCase):
    def test_frame_offset_load_and_separate_pop_agree(self):
        r=frame();self.assertEqual((r.verdict,r.checked_pcs),('agreement',(0x1010,0x101c)))
        self.assertTrue(any(e.code=='cfg_returns_checked' and '2 distinct' in e.message for e in r.evidence))
    def test_split_leaf_pop_excludes_each_teardown_instruction(self):
        r=leaf();self.assertEqual((r.verdict,r.checked_pcs),('agreement',(0x1004,0x1008,0x100c,0x1018)))
    def test_fde_rows_join_each_physical_call_before_differing_teardowns(self):
        r=dwarf(program=CFI+bytes.fromhex('540c1d10'))
        self.assertEqual((r.verdict,r.coverage),('agreement','dwarf_evaluated'))
        self.assertTrue(any(e.code=='dwarf_cfi_row' and 'row at 0x101c' in e.message for e in r.evidence))
    def test_mid_split_pop_or_middle_offset_epilogue_targets_decline(self):
        words=list(LEAF);words[2]=0x540000cc # target second ADD at index8
        self.assertEqual(leaf(words).reason_codes,('cfg_edge_not_modeled',))
        words=list(FRAME);words[3]=0x540000cc # target ADD at index9
        self.assertEqual(frame(words).reason_codes,('cfg_edge_not_modeled',))
    def test_wrong_leaf_total_and_unaligned_intermediate_pop_decline(self):
        words=list(LEAF);words[8]=0x910083ff
        self.assertEqual(leaf(words).reason_codes,('cfg_return_shape_not_modeled',))
        words=list(LEAF);words[7]=0x910023ff;words[8]=0x910063ff # 8+24 totals32 but misaligned
        self.assertEqual(leaf(words).reason_codes,('unmodeled_stack_alignment',))
    def test_possible_wrong_frame_restore_dominates_good_call(self):
        words=list(FRAME);words[8]=0xa94077fd # LDP x29,x29 instead of x29,x30
        self.assertEqual(frame(words).verdict,'unresolved')
    def test_deallocated_slot_is_not_recovered_after_early_pop(self):
        words=(*PRO,0x71001c1f,0x5400008c,CALL,*EPI,CALL,0x910043ff,0xa97f7bfd,RET)
        self.assertEqual(frame(words).verdict,'unresolved')
    def test_body_frame_transition_declines_but_forward_restore_transfer_is_supported(self):
        words=list(FRAME);words[7]=0x910043ff
        self.assertEqual(frame(words).verdict,'unresolved')
        words=(*PRO,0x71001c1f,0x5400008c,CALL,*EPI,CALL,0xa9407bfd,0x14000001,0x910043ff,RET)
        self.assertEqual(frame(words).verdict,'agreement')
    def test_unknown_precedence_and_possible_only_discrepancy(self):
        self.assertEqual(dwarf(program=CFI+bytes.fromhex('081e0713')).reason_codes,('unknown_recovery_value',))
        self.assertEqual(dwarf(program=CFI+bytes.fromhex('54081e')).reason_codes,('cfg_path_feasibility_unknown',))
    def test_known_cfi_mismatch_keeps_witness_under_one_evidence(self):
        words=(*PRO,0xd2800100,0x71001c1f,0x5400008d,CALL,*EPI,CALL,*OFFSET_POP)
        r=dwarf(words,CFI+bytes.fromhex('4c081e'),replace(Limits(),max_evidence_per_function=1))
        self.assertEqual(r.verdict,'inconsistency');self.assertEqual(r.evidence[0].expected,'original x30')
    def test_limits_do_not_reset_between_differing_return_arms(self):
        for changes in ({'max_cfg_steps_per_function':8},{'max_cfg_paths_per_function':1},{'max_observations_per_function':1}):
            with self.subTest(changes=changes):self.assertEqual(dwarf(limits=replace(Limits(),**changes)).verdict,'unresolved')
    def test_dead_invalid_target_and_unsupported_tail_still_decline(self):
        words=list(FRAME);words[7]=0x94000000
        self.assertEqual(frame(words).reason_codes,('cfg_call_target_not_modeled',))
        self.assertEqual(frame((*FRAME,0xffffffff)).verdict,'unresolved')
