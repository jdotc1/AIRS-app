"""Owned literal multiple-return CFGs, with no target execution."""
from dataclasses import replace
import unittest
from airs.cfg import audit_current_function
from airs.types import Limits
from test_cfg_calls import call_fixture, PRO, EPI, CALL
from test_dwarf_cfg import image_for, CFI
from test_audit import fixture, RET, NOP

# Unknown GT takes the second call/teardown/RET. Both epilogues are identical.
MULTI=(*PRO,0x71001c1f,0x5400008c,CALL,*EPI,CALL,*EPI)
LEAF=(0xd10083ff,0x71001c1f,0x5400008c,NOP,0x910083ff,RET,NOP,0x910083ff,RET)
def compact(words=MULTI):return audit_current_function(*call_fixture(words))
def dwarf(words=MULTI,program=CFI,limits=Limits()):return audit_current_function(*image_for(words,program),limits)

class ReturnCFGTests(unittest.TestCase):
    def test_two_call_returns_recover_and_restore_independent_paths(self):
        r=compact();self.assertEqual((r.verdict,r.scope),('agreement','synchronous_call_sites'))
        self.assertEqual(r.checked_pcs,(0x1010,0x101c));self.assertTrue(any(e.code=='cfg_returns_checked' for e in r.evidence))
    def test_allocated_leaf_excludes_both_teardowns(self):
        r=audit_current_function(*fixture(LEAF,0x02002000))
        self.assertEqual(r.verdict,'agreement');self.assertEqual(r.checked_pcs,(0x1004,0x1008,0x100c,0x1018))
    def test_dwarf_row_is_selected_separately_at_each_return_arm_call(self):
        self.assertEqual(dwarf().verdict,'agreement')
        r=dwarf(program=CFI+bytes.fromhex('54081e')) # row at second BL makes LR wrong only on possible path
        self.assertEqual((r.verdict,r.coverage,r.reason_codes),('unresolved','dwarf_evaluated',('cfg_path_feasibility_unknown',)))
    def test_missing_restore_and_middle_entry_decline(self):
        words=list(MULTI);words[8]=NOP
        self.assertEqual(compact(words).reason_codes,('unmodeled_return_state',))
        words=list(MULTI);words[3]=0x5400006c # target first RET skips LDP
        self.assertEqual(compact(words).reason_codes,('cfg_edge_not_modeled',))
    def test_bad_possible_return_invalidates_other_good_path(self):
        words=list(MULTI);words[7]=0xd28000f3 # x19 clobber in second body
        self.assertEqual(compact(words).reason_codes,('unmodeled_return_state',))
    def test_no_call_arm_and_unknown_recovery_keep_precedence(self):
        words=list(MULTI);words[7]=NOP
        self.assertEqual(compact(words).verdict,'agreement')
        r=dwarf(program=CFI+bytes.fromhex('081e0713'))
        self.assertEqual(r.reason_codes,('unknown_recovery_value',))
    def test_loop_unreachable_unknown_and_nonret_tail_decline(self):
        words=list(MULTI);words[3]=0x54ffffec
        # v28 admits this single stable loop before the existing call sites.
        result=compact(words)
        self.assertEqual(result.verdict,'agreement')
        self.assertTrue(any(e.code=='cfg_loop_checked' for e in result.evidence))
        self.assertEqual(compact((*MULTI,0xffffffff)).verdict,'unresolved')
        self.assertEqual(compact((*MULTI,NOP,0xd2800000)).reason_codes,('cfg_return_shape_not_modeled',))
    def test_path_visit_observation_and_evidence_caps(self):
        for changes in ({'max_cfg_paths_per_function':1},{'max_cfg_steps_per_function':2},{'max_observations_per_function':1},{'max_evidence_per_function':0}):
            with self.subTest(changes=changes):self.assertEqual(dwarf(limits=replace(Limits(),**changes)).verdict,'unresolved')
    def test_known_reachable_cfi_mismatch_retains_witness_with_one_evidence(self):
        words=(*PRO,0xd2800100,0x71001c1f,0x5400008d,CALL,*EPI,CALL,*EPI)
        r=dwarf(words,CFI+bytes.fromhex('4c081e'),replace(Limits(),max_evidence_per_function=1))
        self.assertEqual(r.verdict,'inconsistency');self.assertEqual(r.evidence[0].expected,'original x30')

    def test_zero_frame_leaf_can_target_empty_teardown_ret(self):
        words=(0x71001c1f,0x5400006c,NOP,RET,RET)
        r=audit_current_function(*fixture(words,0x02000000))
        self.assertEqual((r.verdict,r.checked_pcs),('agreement',(0x1000,0x1004,0x1008)))
    def test_dead_invalid_call_after_first_return_is_still_rejected(self):
        # First arm known taken to immediate first return; later BL is invalid.
        words=(*PRO,0xd2800100,0x71001c1f,0x5400008d,CALL,*EPI,0x94000000,*EPI)
        self.assertEqual(compact(words).reason_codes,('cfg_call_target_not_modeled',))

    def test_common_setup_is_classified_once_for_multiple_returns(self):
        from unittest.mock import patch
        from airs import cfg
        with patch('airs.cfg._body_window',wraps=cfg._body_window) as window:
            self.assertEqual(cfg.audit_cfg_calls_function(*call_fixture(MULTI)).verdict,'agreement')
        self.assertEqual(window.call_count,1)
