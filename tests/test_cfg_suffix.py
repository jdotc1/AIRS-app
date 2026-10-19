"""Owned literal shared suffixes; no target execution."""
from dataclasses import replace
import unittest
from airs.cfg import audit_current_function
from airs.types import Limits
from test_cfg_calls import PRO,CALL,call_fixture
from test_dwarf_cfg import image_for,CFI
from test_audit import fixture,RET,NOP
POP=0xa9407bfd
# One arm restores FP/LR then branches into the later arm's shared ADD SP/RET.
FRAME=(*PRO,0x71001c1f,0x5400008c,CALL,POP,0x14000003,CALL,POP,0x910043ff,RET)
LEAF=(0xd10083ff,0x71001c1f,0x5400008c,NOP,0x910043ff,0x14000003,NOP,0x910043ff,0x910043ff,RET)
def frame(words=FRAME):return audit_current_function(*call_fixture(words))
def dwarf(words=FRAME,program=CFI,limits=Limits()):return audit_current_function(*image_for(words,program),limits)
def leaf(words=LEAF):return audit_current_function(*fixture(words,0x02002000))

class SharedSuffixTests(unittest.TestCase):
    def test_frame_prefix_shares_later_add_ret_without_merging_states(self):
        r=frame();self.assertEqual((r.verdict,r.checked_pcs),('agreement',(0x1010,0x101c)))
        self.assertTrue(any(e.code=='cfg_shared_teardown' for e in r.evidence))
    def test_leaf_prefix_and_suffix_are_excluded_from_observations(self):
        r=leaf();self.assertEqual((r.verdict,r.checked_pcs),('agreement',(0x1004,0x1008,0x100c,0x1018)))
    def test_fde_rows_stay_at_each_original_bl_pc(self):
        r=dwarf(program=CFI+bytes.fromhex('540c1d10'))
        self.assertEqual((r.verdict,r.coverage),('agreement','dwarf_evaluated'))
        self.assertTrue(any(e.code=='dwarf_cfi_row' and 'row at 0x101c' in e.message for e in r.evidence))
    def test_body_cannot_target_interior_suffix_without_restore_prefix(self):
        words=list(FRAME);words[3]=0x540000cc # body B.GT directly to shared ADD
        self.assertEqual(frame(words).reason_codes,('cfg_edge_not_modeled',))
        words=list(LEAF);words[2]=0x540000cc
        self.assertEqual(leaf(words).reason_codes,('cfg_edge_not_modeled',))
    def test_bad_restore_on_possible_incoming_path_stays_unresolved(self):
        words=list(FRAME);words[5]=0xa94077fd
        self.assertEqual(frame(words).verdict,'unresolved')
    def test_wrong_total_alignment_and_freed_storage_remain_unresolved(self):
        for a,b in ((0x910023ff,0x910043ff),(0x910083ff,0x910043ff),(0x910023ff,0x910063ff)):
            words=list(LEAF);words[4]=a;words[8]=b
            with self.subTest(a=a,b=b):self.assertEqual(leaf(words).verdict,'unresolved')
        words=list(FRAME);words[5]=0x910043ff # missing restore then suffix overpop
        self.assertEqual(frame(words).verdict,'unresolved')
    def test_conditional_or_backward_teardown_transfer_not_admitted(self):
        words=list(FRAME);words[6]=0x5400006c
        self.assertEqual(frame(words).verdict,'unresolved')
        words=list(FRAME);words[6]=0x17ffffff
        self.assertEqual(frame(words).verdict,'unresolved')
    def test_prefix_cannot_jump_to_body_setup_or_outside(self):
        for edge in (0x14000001,0x17fffffa,0x14000040):
            words=list(FRAME);words[6]=edge
            with self.subTest(edge=edge):self.assertEqual(frame(words).verdict,'unresolved')
    def test_partial_final_leaf_suffix_with_two_forward_prefixes(self):
        # Both prefixes branch to a standalone ADD16 suffix; one B skips body padding.
        words=(0xd10083ff,0x71001c1f,0x5400008c,NOP,0x910043ff,0x14000005,NOP,0x910043ff,0x14000002,NOP,0x910043ff,RET)
        self.assertEqual(leaf(words).verdict,'agreement')
    def test_unknown_and_possible_only_mismatch_do_not_gain_supported_verdict(self):
        self.assertEqual(dwarf(program=CFI+bytes.fromhex('081e0713')).reason_codes,('unknown_recovery_value',))
        self.assertEqual(dwarf(program=CFI+bytes.fromhex('54081e')).reason_codes,('cfg_path_feasibility_unknown',))
    def test_known_cfi_witness_survives_tiny_evidence(self):
        words=(*PRO,0xd2800100,0x71001c1f,0x5400008d,CALL,POP,0x14000003,CALL,POP,0x910043ff,RET)
        r=dwarf(words,CFI+bytes.fromhex('4c081e'),replace(Limits(),max_evidence_per_function=1))
        self.assertEqual((r.verdict,r.evidence[0].expected),('inconsistency','original x30'))
    def test_caps_and_dead_invalid_calls_remain_enforced(self):
        for change in ({'max_cfg_steps_per_function':8},{'max_cfg_paths_per_function':1},{'max_observations_per_function':1}):
            with self.subTest(change=change):self.assertEqual(dwarf(limits=replace(Limits(),**change)).verdict,'unresolved')
        words=list(FRAME);words[7]=0x94000000
        self.assertEqual(frame(words).reason_codes,('cfg_call_target_not_modeled',))

    def test_forward_prefix_chain_keeps_partial_states_until_final_suffix(self):
        words=(0xd100c3ff,0x71001c1f,0x5400008c,NOP,0x910043ff,0x14000004,NOP,0x910043ff,0x14000001,0x910043ff,0x14000002,NOP,0x910043ff,RET)
        r=audit_current_function(*fixture(words,0x02003000))
        self.assertEqual(r.verdict,'agreement')
        self.assertTrue(any(e.code=='cfg_shared_teardown' and '3 forward' in e.message for e in r.evidence))
    def test_known_unreachable_supported_bad_pop_is_not_executed(self):
        # Known B.GT chooses later valid32-byte pop; first prefix would over-pop.
        words=(0xd10083ff,0xd2800100,0x71001c1f,0x5400008c,0x910083ff,0x14000003,NOP,0x910043ff,0x910043ff,RET)
        self.assertEqual(leaf(words).verdict,'agreement')

    def test_nop_only_prefix_does_not_authorize_interior_suffix_entry(self):
        words=list(FRAME);words[5]=NOP
        self.assertEqual(frame(words).reason_codes,('cfg_edge_not_modeled',))
