"""Focused tests for the proposed X-only RBIT candidate.

These are NEW tests. They do not import or discover the accepted test suite.
Instruction bytes are interpreted as data; no target binary is executed.
The complete CTZ witness is retained at pinned tests/test_clz.py:35-42.
"""
from dataclasses import replace
import struct
import unittest

from airs.arm64 import ModelError, Value, original
from airs.cfg import PathState, audit_cfg_function, audit_current_function, decode_instruction
from airs.dwarf_cfi import CFITable, FDE, Row
from airs.types import FunctionRange, Limits, MachOImage, Section, UnwindEntry

BASE = 0x1000
NOP = 0xD503201F
RET = 0xD65F03C0
RBIT_X0_X1 = 0xDAC00020
RBIT_X0_X0 = 0xDAC00000
RBIT_X0_XZR = 0xDAC003E0
RBIT_XZR_X1 = 0xDAC0003F
RBIT_X19_X0 = 0xDAC00013
RBIT_X19_X19 = 0xDAC00273
RBIT_X29_X0 = 0xDAC0001D
CTZ_WITNESS = (0xDAC00008, 0xDAC01100, RET)
PRO = (0xA9BF7BFD, 0x910003FD)
EPI = (0xA8C17BFD, RET)
PAIR_PRO = (0xD10083FF, 0xA9004FF4, 0xA9017BFD, 0x910043FD)
PAIR_EPI = (0xA9417BFD, 0xA9404FF4, 0x910083FF, RET)
CALL = "owned-call"
MASK64 = (1 << 64) - 1


def fixture(words, encoding=0x02000000, with_callee=False):
    """Build a tiny typed input; identities are placeholders, not binary digests."""
    resolved = tuple(
        (0x94000000 | ((0x100 - index * 4) // 4)) if word == CALL else word
        for index, word in enumerate(words)
    )
    data = struct.pack("<" + "I" * len(resolved), *resolved)
    function = FunctionRange(BASE, BASE + len(data), "owned_rbit_candidate", "lc_function_starts")
    functions = (function,)
    if with_callee:
        if len(data) > 0x100:
            raise ValueError("Tiny call fixture exceeded its declared extent")
        data += bytes(0x100 - len(data)) + struct.pack("<II", NOP, RET)
        functions += (FunctionRange(BASE + 0x100, BASE + 0x108, "owned_sink", "lc_function_starts"),)
    image = MachOImage(
        data, "<synthetic-rbit-candidate>", "", "", 0, len(data), "arm64", 0,
        None, BASE, 6, (Section("__TEXT", "__text", BASE, len(data), 0),), functions,
    )
    return image, function, UnwindEntry(BASE, function.end, encoding, 0)


def call_result(words, encoding=0x04000000, limits=Limits()):
    return audit_current_function(*fixture(words, encoding, with_callee=True), limits)


def independent_reverse_oracle(value):
    """String-position oracle, independent of the candidate's shift/OR loop."""
    return int(format(value & MASK64, "064b")[::-1], 2)


class RBITXCandidateStateTests(unittest.TestCase):
    def decode_rbit(self, word=RBIT_X0_X1):
        try:
            instruction = decode_instruction(word, BASE)
        except ModelError as error:
            self.fail("Required X RBIT is not supported: " + error.code)
        self.assertEqual(instruction.kind, "xrbit")
        return instruction

    def test_literal_vectors_distinguish_bit_reversal_from_byte_reversal(self):
        instruction = self.decode_rbit()
        vectors = (
            (0, 0),
            (1, 0x8000000000000000),
            (0x8000000000000000, 1),
            (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
            (0xFFFFFFFF, 0xFFFFFFFF00000000),
            (0x80, 0x0100000000000000),
            (0x0123456789ABCDEF, 0xF7B3D591E6A2C480),
        )
        for value, expected in vectors:
            with self.subTest(value=hex(value)):
                state = PathState()
                state.registers[1] = Value("constant", value)
                state.apply(instruction)
                self.assertEqual(state.registers[0], Value("constant", expected))

    def test_every_single_bit_matches_an_independent_position_oracle(self):
        instruction = self.decode_rbit()
        values = [1 << bit for bit in range(64)]
        values += [0x13579BDF2468ACE0, 0xAAAAAAAAAAAAAAAA, 0x5555555555555555]
        for value in values:
            with self.subTest(value=hex(value)):
                state = PathState()
                state.registers[1] = Value("constant", value)
                state.apply(instruction)
                self.assertEqual(state.registers[0], Value("constant", independent_reverse_oracle(value)))

    def test_concrete_inputs_are_projected_to_exactly_64_bits(self):
        instruction = self.decode_rbit()
        for value, expected in ((-1, MASK64), (1 << 64, 0), ((1 << 64) | 1, 1 << 63), (-(1 << 64), 0)):
            with self.subTest(value=value):
                state = PathState()
                state.registers[1] = Value("constant", value)
                state.apply(instruction)
                self.assertEqual(state.registers[0], Value("constant", expected))

    def test_aliased_destination_reads_the_incoming_source(self):
        state = PathState()
        state.registers[0] = Value("constant", 0x0123456789ABCDEF)
        state.apply(self.decode_rbit(RBIT_X0_X0))
        self.assertEqual(state.registers[0], Value("constant", 0xF7B3D591E6A2C480))

    def test_zero_register_source_yields_zero_without_reading_sp(self):
        state = PathState(sp=Value("stack", displacement=-16))
        state.apply(self.decode_rbit(RBIT_X0_XZR))
        self.assertEqual(state.registers[0], Value("constant", 0))
        self.assertEqual(state.sp, Value("stack", displacement=-16))

    def test_discarded_destination_does_not_change_sp_or_registers(self):
        state = PathState(sp=Value("stack", displacement=-16))
        state.registers[1] = Value("constant", 1)
        before = state.registers.copy()
        state.apply(self.decode_rbit(RBIT_XZR_X1))
        self.assertEqual(state.registers, before)
        self.assertEqual(state.sp, Value("stack", displacement=-16))

    def test_raw_stack_source_declines_even_when_result_is_discarded(self):
        for strict in (False, True):
            for word in (RBIT_X0_X1, RBIT_XZR_X1):
                with self.subTest(strict=strict, word=hex(word)):
                    state = PathState(strict_call_state=strict)
                    state.registers[1] = Value("stack", displacement=-16)
                    with self.assertRaises(ModelError) as error:
                        state.apply(self.decode_rbit(word))
                    self.assertEqual(error.exception.code, "rbit_stack_address_not_modeled")

    def test_original_and_explicit_unknown_sources_stay_unknown(self):
        instruction = self.decode_rbit()
        for source in (original(1), Value("unknown", "call result")):
            with self.subTest(source=source):
                state = PathState()
                state.registers[1] = source
                state.apply(instruction)
                self.assertEqual(state.registers[0].kind, "unknown")
                self.assertNotEqual(state.registers[0], original(0))

    def test_nzcv_preservation_survives_a_condition_consumer(self):
        instruction = self.decode_rbit()
        for flags in (None, (False, True, True, False), (True, False, False, True)):
            with self.subTest(flags=flags):
                state = PathState(flags=flags)
                state.registers[1] = Value("constant", 1)
                previous_condition = state.condition(0)
                state.apply(instruction)
                self.assertEqual(state.flags, flags)
                self.assertEqual(state.condition(0), previous_condition)

    def test_memory_and_unrelated_register_identities_are_preserved(self):
        state = PathState(
            sp=Value("stack", displacement=-16),
            memory={-16: original(29), -8: original(30)},
            words={-16: Value("constant", 7)},
        )
        state.registers[1] = Value("constant", 1)
        registers, memory, words = state.registers.copy(), state.memory.copy(), state.words.copy()
        state.apply(self.decode_rbit())
        self.assertEqual(state.registers[1:], registers[1:])
        self.assertEqual(state.memory, memory)
        self.assertEqual(state.words, words)
        self.assertEqual(state.sp, Value("stack", displacement=-16))

    def test_w_rbit_and_other_unimplemented_families_stay_unsupported(self):
        # W RBIT is ISA-valid but deliberately outside this X-only candidate.
        words = (0x5AC00008, 0xDAC00408, 0xDAC00808, 0xDAC00C08, 0xDAC01408, 0x9AC10C00)
        for word in words:
            with self.subTest(word=hex(word)), self.assertRaises(ModelError):
                decode_instruction(word, BASE)

    def test_fixed_control_bit_changes_are_never_misdecoded_as_rbit(self):
        for bit in range(10, 32):
            word = RBIT_X0_X1 ^ (1 << bit)
            with self.subTest(bit=bit, word=hex(word)):
                try:
                    instruction = decode_instruction(word, BASE)
                except ModelError:
                    continue
                self.assertNotEqual(instruction.kind, "xrbit")
        # A nearby already-supported instruction must retain its own semantics.
        self.assertEqual(decode_instruction(0xDAC01020, BASE).kind, "xclz")


class RBITXCandidateRecoveryTests(unittest.TestCase):
    def test_complete_retained_ctz_sequence_has_bounded_leaf_agreement(self):
        result = audit_current_function(*fixture(CTZ_WITNESS))
        self.assertEqual((result.verdict, result.coverage, result.scope),
                         ("agreement", "compact", "modeled_leaf_body"))
        self.assertEqual(result.checked_pcs, (BASE, BASE + 4))
        self.assertEqual(result.instruction_count, 3)

    def test_nonrestoring_callee_saved_write_is_unresolved(self):
        result = audit_current_function(*fixture((RBIT_X19_X0, RET)))
        self.assertEqual((result.verdict, result.reason_codes),
                         ("unresolved", ("unmodeled_return_state",)))

    def test_body_write_to_x29_is_rejected_before_call_recovery(self):
        result = call_result((*PRO, RBIT_X29_X0, CALL, *EPI))
        self.assertEqual((result.verdict, result.reason_codes),
                         ("unresolved", ("cfg_frame_transition_not_modeled",)))

    def test_known_callee_saved_change_retains_a_concrete_call_witness(self):
        words = (*PAIR_PRO, 0xD2800020, RBIT_X19_X0, CALL, *PAIR_EPI)
        result = call_result(words, limits=replace(Limits(), max_evidence_per_function=1))
        self.assertEqual((result.verdict, result.scope),
                         ("inconsistency", "synchronous_call_sites"))
        self.assertEqual(result.checked_pcs, (BASE + 24,))
        self.assertTrue(any(item.expected == "original x19" and item.observed == "constant 0x8000000000000000"
                            for item in result.evidence))

    def test_matching_saved_pair_metadata_recovers_the_modified_register(self):
        words = (*PAIR_PRO, 0xD2800020, RBIT_X19_X0, CALL, *PAIR_EPI)
        result = call_result(words, encoding=0x04000001)
        self.assertEqual((result.verdict, result.scope),
                         ("agreement", "synchronous_call_sites"))
        self.assertEqual(result.checked_pcs, (BASE + 24,))

    def test_unknown_required_recovery_cannot_become_a_known_mismatch(self):
        result = call_result((*PAIR_PRO, RBIT_X19_X19, CALL, *PAIR_EPI))
        self.assertEqual((result.verdict, result.reason_codes),
                         ("unresolved", ("unknown_recovery_value",)))

    def test_possible_only_mismatch_keeps_path_feasibility_unknown(self):
        words = (*PAIR_PRO, 0x54000060, 0xD2800020, RBIT_X19_X0, CALL, *PAIR_EPI)
        result = call_result(words)
        self.assertEqual((result.verdict, result.reason_codes),
                         ("unresolved", ("cfg_path_feasibility_unknown",)))

    def test_later_unknown_recovery_overrides_an_earlier_known_witness(self):
        words = (*PAIR_PRO, 0xD2800020, RBIT_X19_X0, CALL, RBIT_X19_X0, CALL, *PAIR_EPI)
        result = call_result(words, limits=replace(Limits(), max_evidence_per_function=1))
        self.assertEqual((result.verdict, result.reason_codes),
                         ("unresolved", ("unknown_recovery_value",)))

    def test_cfi_recovery_keeps_original_bl_pc_scope(self):
        image, function, entry = fixture((*PRO, RBIT_X0_X0, CALL, *EPI), with_callee=True)
        initial_rules = {register: ("same", 0) for register in range(19, 31)}
        frame_rules = initial_rules.copy()
        frame_rules[29], frame_rules[30] = ("offset", -16), ("offset", -8)
        # Hand-derived canonical frame: after STP/MOV, CFA=FP+16;
        # old FP at CFA-16 and caller LR at CFA-8.
        rows = (Row(BASE, (31, 0), initial_rules), Row(BASE + 8, (29, 16), frame_rules))
        table = CFITable({4: FDE(4, 0, function.start, function.end, rows)}, frozenset())
        result = audit_current_function(image, function, replace(entry, encoding=0x03000004), cfi_table=table)
        self.assertEqual((result.verdict, result.coverage, result.scope),
                         ("agreement", "dwarf_evaluated", "synchronous_call_sites"))
        self.assertEqual(result.checked_pcs, (BASE + 12,))
        self.assertNotIn(BASE + 16, result.checked_pcs)

    def test_unreachable_unsupported_neighbor_still_invalidates_the_function(self):
        words = (0x14000002, 0xDAC01408, *CTZ_WITNESS)
        result = audit_current_function(*fixture(words))
        self.assertEqual(result.verdict, "unresolved")
        self.assertEqual(result.checked_pcs, ())

    def test_new_instruction_remains_subject_to_small_existing_limits(self):
        cases = (
            (replace(Limits(), max_cfg_steps_per_function=1), "cfg_work_limit"),
            (replace(Limits(), max_observations_per_function=1), "observation_limit"),
            (replace(Limits(), max_evidence_per_function=0), "evidence_limit"),
            (replace(Limits(), max_instructions_per_function=2), "function_instruction_limit"),
            (replace(Limits(), max_cfg_paths_per_function=0), "cfg_path_limit"),
        )
        for limits, reason in cases:
            with self.subTest(reason=reason):
                result = audit_cfg_function(*fixture(CTZ_WITNESS), limits)
                self.assertEqual((result.verdict, result.reason_codes), ("unresolved", (reason,)))
                self.assertEqual(result.checked_pcs, ())


if __name__ == "__main__":
    unittest.main()

