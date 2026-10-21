"""Instruction-level FP effects must agree with decoded writes and body admission."""
import unittest
from airs.arm64 import Instruction, Value, original
from airs.cfg import PathState, decode_instruction
from test_rbit_x_candidate import call_result, PAIR_PRO, PAIR_EPI, CALL


# Independent literal words, each with destination X29/W29. These name different
# arithmetic/bit/width/memory families; stores below only read the data register.
WRITERS=(0xdac0003d,0xdac0103d,0x5ac0103d,0x9ac2083d,
         0x1100043d,0xb100043d,0x6b02003d,0xab02003d,
         0x9a02003d,0x6a02003d,0xea02003d,0xf94003fd,0xb94003fd)


class FrameEffectTests(unittest.TestCase):
    def test_cfg_writers_report_fp_effect_and_really_write_fp(self):
        for word in WRITERS:
            with self.subTest(word=hex(word)):
                ins=decode_instruction(word,0x1000)
                self.assertTrue(ins.changes_fp)
                state=PathState(sp=Value('stack',displacement=-16),memory={-16:Value('constant',7)})
                state.registers[1]=Value('constant',19);state.registers[2]=Value('constant',3)
                state.apply(ins)
                self.assertNotEqual(state.registers[29],original(29))

    def test_same_decodes_to_other_destination_do_not_report_fp_effect(self):
        for word in WRITERS:
            ins=decode_instruction((word&~31)|19,0x1000)
            self.assertFalse(ins.changes_fp)

    def test_store_data_register_and_compare_discard_are_not_fp_writes(self):
        for word in (0xf90003fd,0xb90003fd,0xa9007bfd,0xf100003f,0x7100003f,0xea01003f):
            with self.subTest(word=hex(word)):
                ins=decode_instruction(word,0x1000)
                self.assertFalse(ins.changes_fp)
                state=PathState(sp=Value('stack',displacement=-16))
                state.apply(ins)
                self.assertEqual(state.registers[29],original(29))

    def test_pair_and_base_writeback_keep_their_existing_distinct_effects(self):
        for word,fp,sp in ((0xa9007bfd,False,False),(0xa9407bfd,True,False),
                           (0xa9bf7bfd,False,True),(0xa8c17bfd,True,True),
                           (0x910003fd,True,False),(0xd10043ff,False,True)):
            ins=decode_instruction(word,0x1000)
            self.assertEqual((ins.changes_fp,ins.changes_sp),(fp,sp))
        # Existing pair-base writeback policy also covers FP as base independent
        # of the pair's data register fields; this is effect metadata, not admission.
        for kind in ('stp','ldp'):
            self.assertTrue(Instruction(0,0,kind,19,29,20,addressing='pre').changes_fp)
            self.assertFalse(Instruction(0,0,kind,19,29,20,addressing='offset').changes_fp)

    def test_shared_effect_classification_drives_frame_body_refusal(self):
        for word in WRITERS:
            with self.subTest(word=hex(word)):
                result=call_result((*PAIR_PRO,word,CALL,*PAIR_EPI))
                self.assertEqual((result.verdict,result.reason_codes),('unresolved',('cfg_frame_transition_not_modeled',)))
                self.assertEqual(result.checked_pcs,())
