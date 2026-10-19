"""Literal instruction/state/path cases; inspected images never execute."""
from dataclasses import replace
import struct
import unittest

from airs import cfg
from airs.arm64 import ENTRY_SP, ModelError, Value, original
from airs.types import Limits
from test_audit import fixture, BASE, NOP, RET, FRAME

# Literal words from retained Apple disassembly; no production encoder used.
O0=(0xd10043ff,0xb9000be0,0xb9400be8,0x71001d08,0x540000cd,
    0x14000001,0xb9400be8,0x11000d08,0xb9000fe8,0x14000005,
    0xb9400be8,0x531f7908,0xb9000fe8,0x14000001,0xb9400fe0,0x910043ff,RET)
O2=(0x11000c08,0x531f7809,0x71001c1f,0x1a89c100,RET)


def apply(state,word):
    state.apply(cfg.decode_instruction(word,BASE))


def check(words=O0,encoding=0x02001000,limits=Limits(),**kwargs):
    return cfg.audit_cfg_function(*fixture(words,encoding,**kwargs),limits=limits)


class WInstructionTests(unittest.TestCase):
    def test_add_wrap_and_shift_zero_extend_without_inventing_full_identity(self):
        state=cfg.PathState();state.registers[0]=Value('constant',0xffffffff)
        apply(state,0x11000c08);self.assertEqual(state.registers[8],Value('constant',2))
        apply(state,0x531f7809);self.assertEqual(state.registers[9],Value('constant',0xfffffffe))
        state=cfg.PathState();apply(state,0x11000013)  # ADD W19,W0,#0
        self.assertFalse(state.registers[19].known)
        self.assertNotEqual(state.registers[19],original(19))

    def test_subs_signed_flags_and_csel_use_true_and_false_operands(self):
        for value,want in ((8,11),(7,14),(0x80000000,0)):
            with self.subTest(value=value):
                state=cfg.PathState();state.registers[0]=Value('constant',value)
                for word in O2[:-1]:apply(state,word)
                self.assertEqual(state.registers[0],Value('constant',want))
        state=cfg.PathState();apply(state,0x71001c1f)
        self.assertIsNone(state.condition(12));self.assertIsNone(state.condition(13))
        for word in O2[:-1]:apply(state,word)
        self.assertFalse(state.registers[0].known)

    def test_unknown_csel_preserves_equal_constants_but_not_distinct_alternatives(self):
        state=cfg.PathState();state.registers[8]=state.registers[9]=Value('constant',5)
        apply(state,0x1a89c100);self.assertEqual(state.registers[0],Value('constant',5))
        state.registers[9]=Value('constant',6);apply(state,0x1a89c100)
        self.assertFalse(state.registers[0].known)

    def test_sp_zr_reserved_shift_and_unsupported_conditions_decline(self):
        for word in (0x1100001f,0x110003e0,0x710003e0,0x53400000,0x1a89e100,0x540000ce,0x540000cf):
            with self.subTest(word=hex(word)),self.assertRaises(ModelError):cfg.decode_instruction(word,BASE)

    def test_word_stack_roundtrip_masks_and_zero_extends(self):
        state=cfg.PathState();apply(state,0xd10043ff)
        state.registers[0]=Value('constant',0x12345678ffffffff)
        apply(state,0xb9000be0);apply(state,0xb9400be8)
        self.assertEqual(state.registers[8],Value('constant',0xffffffff))
        with self.assertRaises(ModelError):apply(cfg.PathState(),0xb9000be0)
        with self.assertRaises(ModelError):apply(state,0xb94003e8) # uninitialized SP+0
        for word in (0xb9000ba0,0xb9800be8,0xb8000be0):
            with self.subTest(word=hex(word)),self.assertRaises(ModelError):cfg.decode_instruction(word,BASE)

    def test_word_store_invalidates_low_and_high_halves_of_saved_identity(self):
        for word in (0xb90003e0,0xb90007e0): # SP+0 or SP+4 overlaps saved X29
            with self.subTest(word=hex(word)):
                state=cfg.PathState();apply(state,0xa9bf7bfd)
                apply(state,word)
                self.assertFalse(state.memory[-16].known)
                self.assertEqual(state.memory[-8],original(30))
                with self.assertRaises(ModelError):apply(state,0xa8c17bfd)

    def test_full_store_and_deallocation_invalidate_word_cache_and_copies_are_independent(self):
        state=cfg.PathState();apply(state,0xd10043ff)
        state.registers[0]=Value('constant',5);apply(state,0xb90003e0)
        other=state.copy();other.registers[0]=Value('constant',9);apply(other,0xb90003e0)
        apply(state,0xb94003e8);self.assertEqual(state.registers[8],Value('constant',5))
        # STP X29,X30,[SP] replaces cached W; lower bits of original X29 unknown.
        apply(state,0xa9007bfd);apply(state,0xb94003e8);self.assertFalse(state.registers[8].known)
        apply(state,0x910043ff);apply(state,0xd10043ff)
        with self.assertRaises(ModelError):apply(state,0xb94003e8)


class CFGRecoveryTests(unittest.TestCase):
    def test_owned_forward_paths_and_conditional_select_recover_caller(self):
        result=check();self.assertEqual(result.verdict,'agreement')
        self.assertEqual(result.scope,'modeled_leaf_body');self.assertEqual(result.coverage,'compact')
        self.assertIn(BASE+40,result.checked_pcs);self.assertIn(BASE+24,result.checked_pcs)
        self.assertNotIn(BASE,result.checked_pcs);self.assertNotIn(BASE+60,result.checked_pcs)
        self.assertTrue(any('2 terminal paths' in e.message for e in result.evidence))
        self.assertEqual(check(O2,0x02000000).verdict,'agreement')

    def test_backward_self_outside_tail_and_unsupported_dead_code_decline(self):
        for words in ((0x14000000,NOP,RET),(0x17ffffff,NOP,RET),(0x14000003,NOP,RET),
                      (0x14000002,0xffffffff,RET),(NOP,RET,0x11000c08)):
            with self.subTest(words=words):self.assertEqual(check(words,0x02000000).verdict,'unresolved')

        # v6 permits multiple zero-frame RET terminals with empty teardowns.
        self.assertEqual(check((0x14000001,RET,RET),0x02000000).verdict,'agreement')

    def test_branch_cannot_skip_allocation_or_shared_teardown(self):
        for word in (0x14000010,0x17ffffff):
            words=list(O0);words[4]=word
            self.assertEqual(check(tuple(words)).verdict,'unresolved')
        words=list(O0);words[7]=0x910043ff
        self.assertEqual(check(tuple(words)).verdict,'unresolved')

    def test_unknown_branch_bad_path_is_unresolved_not_supported_defect(self):
        # GT skips wrong caller LR body assignment; branch input is unknown.
        words=(0x71001c1f,0x5400004c,0xd280001e,0xaa1e03e9,RET)
        result=check(words,0x02000000)
        # Return cannot restore LR; no proof even if one branch avoids assignment.
        self.assertEqual(result.verdict,'unresolved')

    def test_known_reachable_recovery_mismatch_keeps_expected_observed(self):
        # Frame16, metadata stack32: every body state recovers wrong SP, return restored.
        words=(0xd10043ff,0xd2800100,0x71001c1f,0x5400004c,NOP,0x910043ff,RET)
        result=check(words,0x02002000)
        self.assertEqual(result.verdict,'inconsistency')
        self.assertTrue(any(e.expected=='entry SP' and e.observed=='entry SP+16' for e in result.evidence))

    def test_divergent_unknown_return_or_saved_word_alias_overrides_mismatch(self):
        words=list(O0);words[7]=0x11000d13 # W19 write on one path destroys X19
        self.assertEqual(check(tuple(words),0x02002000).verdict,'unresolved')
        words=(0xd10043ff,0xa9007bfd,0xb90007e0,0xa9407bfd,0x910043ff,RET)
        self.assertEqual(check(words,0x02002000).verdict,'unresolved')

    def test_cfg_limits_preserve_unresolved_and_do_not_drop_path(self):
        for changes in ({'max_cfg_steps_per_function':1},{'max_cfg_paths_per_function':1},
                        {'max_observations_per_function':2},{'max_evidence_per_function':0}):
            with self.subTest(changes=changes):
                self.assertEqual(check(limits=replace(Limits(),**changes)).verdict,'unresolved')

    def test_compact_leaf_only_and_exact_arch_boundary_remain_gates(self):
        for changes in ({'arch':'arm64e'},{'boundary':'symbol_table'}):
            self.assertEqual(check(**changes).verdict,'unresolved')
        self.assertEqual(check(FRAME,0x04000000).verdict,'unresolved')
        self.assertEqual(check(O2,0x03000000).verdict,'unresolved')
        self.assertEqual(check(O2,0x02000001).verdict,'unresolved')

class CFGPathBoundaryTests(unittest.TestCase):
    def test_possible_only_mismatch_stays_unresolved_at_reconvergence(self):
        words=(0xaa1303e9,0x71001c1f,0x5400004c,0xd2800013,NOP,0xaa0903f3,NOP,RET)
        result=check(words,0x02000000)
        self.assertEqual(result.verdict,'unresolved')
        self.assertEqual(result.reason_codes,('cfg_path_feasibility_unknown',))

    def test_known_branch_prunes_bad_path_or_retains_concrete_mismatch(self):
        tail=(0xaa1303e9,0x71001c1f,0x5400004c,0xd2800013,NOP,0xaa0903f3,NOP,RET)
        good=check((0xd2800100,*tail),0x02000000) # input8, GT true skips bad W19
        self.assertEqual(good.verdict,'agreement')
        self.assertNotIn(BASE+16,good.checked_pcs)
        bad=check((0xd2800000,*tail),0x02000000) # input0, GT false executes bad path
        self.assertEqual(bad.verdict,'inconsistency')
        self.assertTrue(any(e.expected=='original x19' and e.observed=='constant 0x0' for e in bad.evidence))

    def test_empty_metadata_retains_none_coverage_and_zero_path_budget_declines(self):
        result=check(O2,0)
        self.assertEqual((result.coverage,result.reason_codes),('none',('empty_unwind_rule',)))
        self.assertEqual(check(O2,0x02000000,limits=replace(Limits(),max_cfg_paths_per_function=0)).verdict,'unresolved')

    def test_unknown_callee_saved_recovery_dominates_known_mismatch_with_one_evidence_slot(self):
        # Preserve original X19 in X9, write unknown W19, restore it at return.
        words=(0xd10043ff,0xaa1303e9,0x11000013,NOP,0xaa0903f3,0x910043ff,RET)
        result=check(words,0x02002000,limits=replace(Limits(),max_evidence_per_function=1))
        self.assertEqual((result.verdict,result.reason_codes),('unresolved',('unknown_recovery_value',)))
