"""Small literal arithmetic flag producers; no inspected image execution."""
from dataclasses import replace
import unittest
from airs.cfg import PathState,decode_instruction,audit_current_function
from airs.arm64 import Value,ModelError
from airs.types import Limits
from test_audit import fixture,RET,NOP
from test_cfg_calls import call_fixture,PRO,EPI,CALL
from test_dwarf_cfg import image_for,CFI

class FlagProducerTests(unittest.TestCase):
    def run_op(self,word,source):
        state=PathState();state.registers[0]=Value('constant',source)
        state.apply(decode_instruction(word));return state
    def test_w_adds_carry_overflow_and_zero_extension(self):
        for source,result,flags in ((0xffffffff,0,(False,True,True,False)),(0x7fffffff,0x80000000,(True,False,False,True)),(0x100000000,1,(False,False,False,False))):
            s=self.run_op(0x31000401,source);self.assertEqual((s.registers[1],s.flags),(Value('constant',result),flags))
    def test_x_adds_full_width_carry_and_signed_overflow(self):
        for source,result,flags in ((0xffffffffffffffff,0,(False,True,True,False)),(0x7fffffffffffffff,0x8000000000000000,(True,False,False,True)),(0xffffffff,0x100000000,(False,False,False,False))):
            s=self.run_op(0xb1000401,source);self.assertEqual((s.registers[1],s.flags),(Value('constant',result),flags))
    def test_x_subs_borrow_overflow_and_width(self):
        for source,result,flags in ((0,0xffffffffffffffff,(True,False,False,False)),(0x8000000000000000,0x7fffffffffffffff,(False,False,True,True)),(0x100000000,0xffffffff,(False,False,True,False))):
            s=self.run_op(0xf1000401,source);self.assertEqual((s.registers[1],s.flags),(Value('constant',result),flags))
    def test_unknown_each_family_kills_stale_flags_and_result(self):
        for word in (0x31000401,0xb1000401,0xf1000401):
            s=PathState(flags=(False,True,True,False));s.apply(decode_instruction(word))
            self.assertIsNone(s.flags);self.assertFalse(s.registers[1].known)
    def test_cmn_cmp_discard_destination_and_immediate_shift12(self):
        for word in (0x3100041f,0xb100041f,0xf100041f):
            s=self.run_op(word,0);self.assertEqual(s.registers[0],Value('constant',0));self.assertIsNotNone(s.flags)
        for word in (0x31400401,0xb1400401,0xf1400401):
            s=self.run_op(word,4096);self.assertEqual(s.registers[1],Value('constant',0 if word==0xf1400401 else 8192))
    def test_sp_source_reserved_bit_shifted_and_logical_forms_decline(self):
        for word in (0x310007e1,0xb10007e1,0xf10007ff,0x31800401,0xb1800401,0xf1800401,0x2bc10001,0xabc10001,0xebc1001f,0xf240fc1f):
            with self.subTest(word=hex(word)),self.assertRaises(ModelError):decode_instruction(word)
    def test_x_stack_derived_source_and_w_projection_reject_provenance_loss(self):
        for word in (0xb1000001,0xf1000001):
            s=PathState(strict_call_state=True);s.registers[0]=Value('stack')
            with self.assertRaises(ModelError):s.apply(decode_instruction(word))
        s=PathState(strict_call_state=True);s.registers[0]=Value('stack')
        with self.assertRaises(ModelError):s.apply(decode_instruction(0x31000401))
    def test_original_x_plus_zero_is_not_invented_identity(self):
        s=PathState();s.apply(decode_instruction(0xb1000273)) # ADDS X19,X19,#0
        self.assertFalse(s.registers[19].known);self.assertIsNone(s.flags)
    def test_each_family_drives_known_and_unknown_forward_cfg(self):
        for mov,op,condition in ((0x92800000,0x31000401,2),(0x92800000,0xb1000401,2),(0xd2800000,0xf1000401,3)):
            words=(mov,op,0x54000060|condition,NOP,0x14000002,NOP,RET)
            r=audit_current_function(*fixture(words,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertIn(0x1014,r.checked_pcs)
            words=(op,0x54000060|condition,NOP,0x14000002,NOP,RET)
            r=audit_current_function(*fixture(words,0x02000000));self.assertEqual(r.verdict,'agreement');self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_frame_pointer_destinations_stay_outside_body_subset(self):
        for op in (0x3100041d,0xb100041d,0xf100041d):
            r=audit_current_function(*call_fixture((*PRO,op,0x5400004c,CALL,*EPI)))
            self.assertEqual(r.reason_codes,('cfg_frame_transition_not_modeled',))
    def test_postcall_unknown_and_fresh_known_flags_preserve_fde_scope(self):
        words=(*PRO,CALL,0xb1000401,0x5400004c,NOP,*EPI)
        r=audit_current_function(*image_for(words,CFI));self.assertEqual((r.verdict,r.coverage,r.scope),('agreement','dwarf_evaluated','synchronous_call_sites'))
        self.assertTrue(any('2 terminal paths' in e.message for e in r.evidence))
    def test_caps_and_unsupported_dead_producer_are_not_hidden(self):
        words=(0x31000401,0x54000060,NOP,0x14000002,NOP,RET)
        r=audit_current_function(*fixture(words,0x02000000),replace(Limits(),max_cfg_paths_per_function=1));self.assertEqual(r.reason_codes,('cfg_path_limit',))
        words=(0x14000002,0xabc10001,NOP,RET)
        self.assertEqual(audit_current_function(*fixture(words,0x02000000)).verdict,'unresolved')

    def test_new_producers_require_known_reachability_for_mismatch(self):
        from test_cfg_calls import PAIR_PRO,PAIR_EPI,check
        for mov,op,condition in ((0x92800000,0x31000401,3),(0x92800000,0xb1000401,3),(0xd2800000,0xf1000401,2)):
            known=(*PAIR_PRO,mov,op,0x54000060|condition,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(known).verdict,'inconsistency')
            unknown=(*PAIR_PRO,op,0x54000060|condition,0xd28000f3,CALL,*PAIR_EPI)
            self.assertEqual(check(unknown).reason_codes,('cfg_path_feasibility_unknown',))
