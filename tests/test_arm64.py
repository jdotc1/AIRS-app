"""Owned ARM64 instruction words; these fixtures are never executed."""
import struct
import unittest

from airs.arm64 import (
    ENTRY_SP, MASK64, NOP, RET_X30, MachineState, ModelError, Value,
    decode_function, decode_instruction, original,
)


def words(*values):
    return struct.pack("<" + "I" * len(values), *values)


class DecoderTests(unittest.TestCase):
    def test_real_frame_pair_encodings(self):
        push = decode_instruction(0xA9BF7BFD, 0x1000)
        pop = decode_instruction(0xA8C17BFD, 0x1010)
        self.assertEqual((push.kind, push.rd, push.rt2, push.rn, push.immediate, push.addressing),
                         ("stp", 29, 30, 31, -16, "pre"))
        self.assertEqual((pop.kind, pop.rd, pop.rt2, pop.rn, pop.immediate, pop.addressing),
                         ("ldp", 29, 30, 31, 16, "post"))

    def test_real_reversed_number_pair_store(self):
        store = decode_instruction(0xA9004FF4)
        self.assertEqual((store.kind, store.rd, store.rt2, store.rn, store.immediate),
                         ("stp", 20, 19, 31, 0))

    def test_frame_and_stack_immediates(self):
        fp = decode_instruction(0x910003FD)
        sub = decode_instruction(0xD10083FF)
        shifted = decode_instruction(0x914007FF)
        self.assertEqual((fp.kind, fp.rd, fp.rn, fp.immediate), ("add", 29, 31, 0))
        self.assertEqual((sub.kind, sub.rd, sub.rn, sub.immediate), ("sub", 31, 31, 32))
        self.assertEqual(shifted.immediate, 4096)

    def test_mov_alias_is_exact(self):
        move = decode_instruction(0xAA1403F3)
        self.assertEqual((move.kind, move.rd, move.rn), ("mov", 19, 20))
        with self.assertRaises(ModelError):
            decode_instruction(0xAA1407F3)  # ORR with a shift is not MOV.

    def test_direct_bl_sign_extension(self):
        self.assertEqual(decode_instruction(0x94000400, 0x1000).immediate, 4096)
        self.assertEqual(decode_instruction(0x97FFFFFF, 0x1000).immediate, -4)

    def test_only_explicit_supported_words_decode(self):
        excluded = (0xD503203F, 0x00000000, 0xB10003FF, 0x52800013,
                    0xADBF7BFD, 0xA8007BFD, 0xF90003F3, 0xF28000F3,
                    0xD63F0100, 0xD65F0120, 0x14000000, 0x54000040,
                    0xB4000040, 0x36000040)
        for word in excluded:
            with self.subTest(word=hex(word)), self.assertRaises(ModelError):
                decode_instruction(word)

    def test_known_pauth_never_becomes_a_nop(self):
        for word in (0xD503233F, 0xD503237F, 0xD50323BF, 0xD50323FF, 0xD65F0BFF):
            with self.subTest(word=hex(word)):
                with self.assertRaises(ModelError) as caught:
                    decode_instruction(word)
                self.assertEqual(caught.exception.code, "unsupported_pauth")

    def test_ambiguous_pair_and_unmodeled_base_rejected(self):
        for word in (0xA9404FF3, 0xA9FF77BD, 0xA9004C14):
            with self.subTest(word=hex(word)), self.assertRaises(ModelError):
                decode_instruction(word)

    def test_complete_function_and_nop_padding(self):
        instructions = decode_function(words(NOP, RET_X30, NOP, NOP), 0x1000, 4)
        self.assertEqual([i.kind for i in instructions], ["nop", "ret", "nop", "nop"])
        for code, start, limit, reason in (
            (words(NOP), 0x1000, 1, "missing_supported_return"),
            (words(RET_X30, 0), 0x1000, 2, "non_nop_after_return"),
            (words(RET_X30, RET_X30), 0x1000, 2, "non_nop_after_return"),
            (words(NOP, RET_X30), 0x1000, 1, "function_instruction_limit"),
            (words(RET_X30) + b"x", 0x1000, 2, "unaligned_function_range"),
            (words(RET_X30), 0x1001, 2, "unaligned_function_range"),
        ):
            with self.subTest(reason=reason), self.assertRaises(ModelError) as caught:
                decode_function(code, start, limit)
            self.assertEqual(caught.exception.code, reason)


class SymbolicStateTests(unittest.TestCase):
    def apply_words(self, state, values):
        for index, word in enumerate(values):
            state.apply(decode_instruction(word, 0x1000 + index * 4))

    def test_bl_clobbers_lr_and_volatile_registers_before_snapshot(self):
        state = MachineState()
        self.apply_words(state, (0xA9BF7BFD, 0x910003FD, 0x94000400))
        self.assertEqual(state.registers[30], Value("constant", 0x100C))
        self.assertTrue(all(not state.registers[r].known for r in range(19)))
        self.assertEqual(state.registers[19], original(19))
        self.assertEqual(state.registers[29], ENTRY_SP.add(-16))
        self.assertEqual(state.memory[-8], original(30))
        state.resume_after_call()
        self.assertFalse(state.registers[30].known)

    def test_load_store_order_and_writeback(self):
        state = MachineState()
        self.apply_words(state, (0xA9BF7BFD,))
        self.assertEqual(state.sp, ENTRY_SP.add(-16))
        self.assertEqual(state.memory, {-16: original(29), -8: original(30)})
        self.apply_words(state, (0xA8C17BFD,))
        self.assertEqual(state.sp, ENTRY_SP)
        self.assertEqual(state.memory, {})
        self.assertEqual(state.registers[29:31], [original(29), original(30)])

    def test_movz_movn_and_zero_register(self):
        state = MachineState()
        self.apply_words(state, (0xD28000F3, 0x92800009, 0xAA1F03F4))
        self.assertEqual(state.registers[19], Value("constant", 7))
        self.assertEqual(state.registers[9], Value("constant", MASK64))
        self.assertEqual(state.registers[20], Value("constant", 0))

    def test_unknown_read_and_unknown_fp_alias_are_rejected(self):
        for values, reason in (
            ((0xD10083FF, 0xA9404FF4), "unknown_stack_read"),
            ((0xA94053B3,), "unknown_memory_address"),
        ):
            with self.subTest(reason=reason), self.assertRaises(ModelError) as caught:
                self.apply_words(MachineState(), values)
            self.assertEqual(caught.exception.code, reason)

    def test_deallocation_does_not_revalidate_old_saved_bytes(self):
        state = MachineState()
        self.apply_words(state, (0xA9BF7BFD, 0xA8C17BFD, 0xD10043FF))
        with self.assertRaises(ModelError) as caught:
            self.apply_words(state, (0xA9407BFD,))
        self.assertEqual(caught.exception.code, "unknown_stack_read")

    def test_stack_escape_and_bad_sp_alignment_are_unresolved_effects(self):
        for values, reason in (
            ((0xA9BF7BFD, 0x910003E0, 0x94000400), "stack_address_escapes_call"),
            ((0xD10023FF,), "unmodeled_stack_alignment"),
            ((0x910043FF,), "unmodeled_stack_alignment"),
        ):
            with self.subTest(reason=reason), self.assertRaises(ModelError) as caught:
                self.apply_words(MachineState(), values)
            self.assertEqual(caught.exception.code, reason)


if __name__ == "__main__":
    unittest.main()
