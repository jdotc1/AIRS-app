"""Fixed NZCV truth rows and small owned condition-code inputs."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_conditional import FRAME,LEAF,dwarf,frame,leaf

# NZCV index bits 8/4/2/1. Literal expected true condition numbers, independently
# transcribed from the architectural condition table, including impossible flags.
TRUE_ROWS=(
 (1,3,5,7,9,10,12),(1,3,5,6,9,11,13),(1,2,5,7,8,10,12),(1,2,5,6,8,11,13),
 (0,3,5,7,9,10,13),(0,3,5,6,9,11,13),(0,2,5,7,9,10,13),(0,2,5,6,9,11,13),
 (1,3,4,7,9,11,13),(1,3,4,6,9,10,12),(1,2,4,7,8,11,13),(1,2,4,6,8,10,12),
 (0,3,4,7,9,11,13),(0,3,4,6,9,10,13),(0,2,4,7,9,11,13),(0,2,4,6,9,10,13))
CSEL=0x1a820020 # CSEL W0,W1,W2,condition

class ConditionCodeTests(unittest.TestCase):
    def test_all_fixed_nzcv_truth_rows_and_complements(self):
        for bits,truth in enumerate(TRUE_ROWS):
            state=PathState(flags=tuple(bool(bits&bit) for bit in (8,4,2,1)))
            for condition in range(14):
                with self.subTest(bits=bits,condition=condition):self.assertEqual(state.condition(condition),condition in truth)
    def test_branch_and_w_csel_decode_all_fourteen_but_not_al_nv(self):
        for condition in range(14):
            self.assertEqual(decode_instruction(0x54000060|condition).addressing,str(condition))
            self.assertEqual(decode_instruction(CSEL|(condition<<12)).addressing,str(condition))
        for condition in (14,15):
            for word in (0x54000060|condition,CSEL|(condition<<12)):
                with self.subTest(word=word),self.assertRaises(ModelError):decode_instruction(word)
            with self.assertRaises(ModelError):PathState(flags=(False,False,False,False)).condition(condition)
    def test_w_subs_carry_no_borrow_and_signed_overflow_edges(self):
        cases=((0,(True,False,False,False)),(1,(False,True,True,False)),
               (0x80000000,(False,False,True,True)),(0xffffffff,(True,False,True,False)),
               (0x100000000,(True,False,False,False)))
        for source,flags in cases:
            state=PathState();state.registers[0]=Value('constant',source)
            state.apply(decode_instruction(0x7100041f)) # CMP W0,#1
            self.assertEqual(state.flags,flags)
            expected=TRUE_ROWS[sum(bit for bit,flag in zip((8,4,2,1),flags) if flag)]
            for condition in range(14):self.assertEqual(state.condition(condition),condition in expected)
    def test_unknown_entry_subtraction_and_postcall_flags_remain_unknown(self):
        state=PathState()
        for condition in range(14):self.assertIsNone(state.condition(condition))
        state.flags=(False,False,True,False);state.apply(decode_instruction(0x7100041f))
        self.assertIsNone(state.flags)
        state.flags=(False,False,True,False);state.resume_after_call()
        for condition in range(14):self.assertIsNone(state.condition(condition))
    def test_csel_all_conditions_select_and_zero_extend_preserving_flags(self):
        for bits,truth in enumerate(TRUE_ROWS):
            for condition in range(14):
                state=PathState(flags=tuple(bool(bits&bit) for bit in (8,4,2,1)))
                state.registers[1]=Value('constant',0x100000007);state.registers[2]=Value('constant',9)
                flags=state.flags;state.apply(decode_instruction(CSEL|(condition<<12)))
                self.assertEqual(state.registers[0],Value('constant',7 if condition in truth else 9));self.assertEqual(state.flags,flags)
    def test_unknown_csel_equal_alternatives_and_original_x_identity_boundary(self):
        for condition in range(14):
            state=PathState();state.registers[1]=state.registers[2]=Value('constant',7)
            state.apply(decode_instruction(CSEL|(condition<<12)));self.assertEqual(state.registers[0],Value('constant',7))
            state.registers[2]=Value('constant',9);state.apply(decode_instruction(CSEL|(condition<<12)));self.assertFalse(state.registers[0].known)
        state=PathState(flags=(False,True,True,False));state.apply(decode_instruction(0x1a930273)) # CSEL W19,W19,W19,EQ
        self.assertFalse(state.registers[19].known)
    def test_known_body_conditions_choose_exact_pc_path(self):
        for condition in range(14):
            words=(0xd2800100,0x71001c1f,0x54000060|condition,NOP,0x14000002,NOP,RET)
            r=audit_current_function(*fixture(words,0x02000000))
            self.assertEqual(r.verdict,'agreement')
            self.assertEqual(0x1014 in r.checked_pcs,condition in TRUE_ROWS[2])
            self.assertEqual(0x100c in r.checked_pcs,condition not in TRUE_ROWS[2])
    def test_entry_unknown_branches_fork_for_each_new_family(self):
        for condition in range(12):
            words=(0x54000060|condition,NOP,0x14000002,NOP,RET)
            r=audit_current_function(*fixture(words,0x02000000));self.assertEqual(r.verdict,'agreement')
            self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_teardown_transfers_support_each_condition_after_call_clobber(self):
        for condition in range(14):
            words=list(FRAME);words[4]=0x54000060|condition
            r=frame(words);self.assertEqual(r.verdict,'agreement')
            self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_fde_scope_and_known_witness_precede_unknown_new_condition(self):
        words=list(FRAME);words[4]=0x54000062 # CS
        r=dwarf(words);self.assertEqual((r.verdict,r.coverage),('agreement','dwarf_evaluated'))
        from test_dwarf_cfg import CFI
        r=dwarf(words,CFI+bytes.fromhex('081e'),replace(Limits(),max_evidence_per_function=1))
        self.assertEqual((r.verdict,r.evidence[0].expected),('inconsistency','original x30'))
    def test_unknown_bad_return_and_fork_budget_cannot_be_pruned(self):
        words=list(FRAME);words[4]=0x54000060;words[7]=0x910083ff
        self.assertEqual(frame(words).verdict,'unresolved')
        words=list(FRAME);words[4]=0x54000068
        self.assertEqual(dwarf(words,limits=replace(Limits(),max_cfg_paths_per_function=1)).reason_codes,('cfg_path_limit',))
    def test_dead_unsupported_al_nv_and_other_flag_producers_stay_unknown(self):
        for condition in (14,15):
            words=(0x14000002,0x54000060|condition,NOP,RET)
            self.assertEqual(audit_current_function(*fixture(words,0x02000000)).verdict,'unresolved')
        for word in (0xabc10000,0xebc1001f,0x2bc10000): # Reserved-shift register producers remain unsupported
            with self.assertRaises(ModelError):decode_instruction(word)

    def test_new_conditions_require_known_reachability_for_saved_pair_witness(self):
        from test_cfg_calls import PAIR_BAD,PAIR_PRO,PAIR_EPI,CALL,check
        for condition in range(12):
            words=list(PAIR_BAD);words[6]=0x54000060|condition
            r=check(words)
            if condition in TRUE_ROWS[2]:self.assertEqual(r.reason_codes,('no_supported_observation',))
            else:self.assertEqual(r.verdict,'inconsistency')
            uncertain=(*PAIR_PRO,0x71001c1f,0x54000060|condition,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(uncertain).reason_codes,('cfg_path_feasibility_unknown',))
