"""Synthetic, owned function/rule comparisons; no target code is executed."""
from dataclasses import replace
import struct
import unittest

from airs.audit import (
    UNWIND_ARM64_FRAMELESS_STACK_SIZE_MASK, UNWIND_ARM64_MODE_DWARF,
    UNWIND_ARM64_MODE_FRAME, UNWIND_ARM64_MODE_FRAMELESS,
    UNWIND_ARM64_MODE_FRAME_PAUTH_LR, UNWIND_ARM64_MODE_MASK,
    audit_function, encoding_mode,
)
from airs.types import FunctionRange, Limits, MachOImage, Section, UnwindEntry


BASE = 0x1000
NOP, RET, BL = 0xD503201F, 0xD65F03C0, 0x94000400
FRAME = (0xA9BF7BFD, 0x910003FD, NOP, BL, 0xA8C17BFD, RET)
LEAF = (0xD10083FF, NOP, 0x910083FF, RET)
PAIR = (0xD10083FF, 0xA9004FF4, 0xA9017BFD, 0x910043FD,
        0xD28000F3, BL, 0xA9417BFD, 0xA9404FF4, 0x910083FF, RET)
SHIFTED = (0xA9BE7BFD, 0x910003FD, NOP, BL, 0xA8C27BFD, RET)


def fixture(words, encoding=0x04000000, *, boundary="lc_function_starts", arch="arm64"):
    data = struct.pack("<" + "I" * len(words), *words)
    function = FunctionRange(BASE, BASE + len(data), "owned_example", boundary)
    image = MachOImage(data, "<synthetic>", "", "", 0, len(data), arch, 0,
                       None, BASE, 6, (Section("__TEXT", "__text", BASE, len(data), 0),), (function,))
    entry = UnwindEntry(BASE, function.end, encoding, 0)
    return image, function, entry


def check(words=FRAME, encoding=0x04000000, **kwargs):
    return audit_function(*fixture(words, encoding, **kwargs))


class MetadataScopeTests(unittest.TestCase):
    def test_constants_match_real_arm64_encoding_fields(self):
        self.assertEqual(UNWIND_ARM64_MODE_MASK, 0x0F000000)
        self.assertEqual(UNWIND_ARM64_MODE_FRAMELESS, 0x02000000)
        self.assertEqual(UNWIND_ARM64_MODE_DWARF, 0x03000000)
        self.assertEqual(UNWIND_ARM64_MODE_FRAME, 0x04000000)
        self.assertEqual(UNWIND_ARM64_MODE_FRAME_PAUTH_LR, 0x05000000)
        self.assertEqual(UNWIND_ARM64_FRAMELESS_STACK_SIZE_MASK, 0x00FFF000)
        self.assertEqual(encoding_mode(0), "none")
        self.assertEqual(encoding_mode(0x05000000), "pauth_frame")

    def test_missing_and_explicit_empty_rules_are_distinct_unresolved_coverage(self):
        image, function, _ = fixture(FRAME)
        missing = audit_function(image, function, None)
        empty = check(FRAME, 0)
        self.assertEqual((missing.verdict, missing.coverage, missing.reason_codes),
                         ("unresolved", "none", ("missing_unwind_metadata",)))
        self.assertEqual((empty.verdict, empty.coverage, empty.reason_codes),
                         ("unresolved", "none", ("empty_unwind_rule",)))

    def test_entire_function_must_be_inside_one_metadata_range(self):
        image, function, entry = fixture(FRAME)
        for changed in (replace(entry, start=BASE + 4), replace(entry, end=function.end - 4)):
            result = audit_function(image, function, changed)
            self.assertEqual(result.reason_codes, ("metadata_range_incomplete",))
            self.assertEqual(result.verdict, "unresolved")

    def test_dwarf_pauth_simd_reserved_bits_and_frameless_pairs_are_unresolved(self):
        cases = ((0x03000000, "dwarf_cfi_unsupported", "dwarf_reference"),
                 (0x05000000, "pointer_authentication_not_modeled", "compact"),
                 (0x04000100, "simd_saved_pairs_not_modeled", "compact"),
                 (0x04000020, "unsupported_encoding_bits", "compact"),
                 (0x02000001, "frameless_saved_pairs_not_modeled", "compact"),
                 (0x01000000, "unsupported_unwind_mode", "compact"))
        for encoding, reason, coverage in cases:
            with self.subTest(encoding=hex(encoding)):
                result = check(FRAME, encoding)
                self.assertEqual((result.verdict, result.reason_codes, result.coverage),
                                 ("unresolved", (reason,), coverage))
                self.assertFalse(result.checked_pcs)

    def test_arm64e_and_weaker_function_boundaries_never_agree(self):
        self.assertEqual(check(arch="arm64e").verdict, "unresolved")
        for boundary in ("symbol_table", "lc_function_starts_with_embedded_data",
                         "lc_function_starts_with_relocations", "guessed"):
            with self.subTest(boundary=boundary):
                result = check(boundary=boundary)
                self.assertEqual(result.reason_codes, ("untrusted_function_boundary",))
                self.assertEqual(result.verdict, "unresolved")

    def test_common_flags_do_not_claim_personality_semantics(self):
        result = check(FRAME, 0x74000000)
        self.assertEqual(result.verdict, "agreement")
        self.assertTrue(any("personality" in item for item in result.limitations))


class SupportedRecoveryTests(unittest.TestCase):
    def test_frame_checked_at_call_after_setup_excludes_prologue_and_epilogue(self):
        result = check()
        self.assertEqual(result.verdict, "agreement")
        self.assertEqual(result.scope, "synchronous_call_sites")
        self.assertEqual(result.checked_pcs, (BASE + 12,))
        self.assertEqual(result.instruction_count, len(FRAME))

    def test_frameless_leaf_body_avoids_prologue_sp_false_positive(self):
        result = check(LEAF, 0x02002000)
        self.assertEqual(result.verdict, "agreement")
        self.assertEqual(result.scope, "modeled_leaf_body")
        self.assertEqual(result.checked_pcs, (BASE + 4,))
        self.assertTrue(any("asynchronous" in item for item in result.limitations))

    def test_frameless_stack_size_mismatch_is_supported_at_body_only(self):
        result = check(LEAF, 0x02004000)
        self.assertEqual(result.verdict, "inconsistency")
        self.assertEqual(result.checked_pcs, (BASE + 4,))
        self.assertEqual((result.evidence[0].expected, result.evidence[0].observed),
                         ("entry SP", "entry SP+32"))

    def test_correct_pair_uses_lower_register_at_higher_address(self):
        self.assertEqual(check(PAIR, 0x04000001).verdict, "agreement")

    def test_reversed_pair_memory_layout_is_supported_identity_mismatch(self):
        reversed_pair = list(PAIR)
        reversed_pair[1] = 0xA90053F3  # STP x19, x20, [SP].
        reversed_pair[7] = 0xA94053F3  # LDP x19, x20, [SP].
        result = check(reversed_pair, 0x04000001)
        self.assertEqual(result.verdict, "inconsistency")
        self.assertEqual({(e.expected, e.observed) for e in result.evidence},
                         {("original x19", "original x20"), ("original x20", "original x19")})

    def test_noncontiguous_pair_flags_pack_selected_pairs_without_holes(self):
        words = (0xD10083FF, 0xA90057F6, 0xA9017BFD, 0x910043FD,
                 0xD28000F5, BL, 0xA9417BFD, 0xA94057F6, 0x910083FF, RET)
        self.assertEqual(check(words, 0x04000002).verdict, "agreement")
        two_pairs = (0xD100C3FF, 0xA9005FF8, 0xA9014FF4, 0xA9027BFD,
                     0x910083FD, 0xD28000F3, 0xD2800137, BL,
                     0xA9427BFD, 0xA9414FF4, 0xA9405FF8, 0x9100C3FF, RET)
        self.assertEqual(check(two_pairs, 0x04000005).verdict, "agreement")

    def test_omitted_pair_is_mismatch_only_when_current_register_loses_identity(self):
        result = check(PAIR, 0x04000000)
        self.assertEqual(result.verdict, "inconsistency")
        self.assertEqual(len(result.evidence), 1)
        self.assertEqual(result.evidence[0].expected, "original x19")
        unchanged_pair = PAIR[:4] + (NOP,) + PAIR[5:]
        self.assertEqual(check(unchanged_pair, 0x04000000).verdict, "agreement")

    def test_known_wrong_frame_sp_is_distinct_from_unknown_memory(self):
        mismatch = check(SHIFTED)
        unknown = check(SHIFTED, 0x04000001)
        self.assertEqual(mismatch.verdict, "inconsistency")
        self.assertEqual((mismatch.evidence[0].expected, mismatch.evidence[0].observed),
                         ("entry SP", "entry SP-16"))
        self.assertEqual(unknown.verdict, "unresolved")
        self.assertEqual(unknown.reason_codes, ("unknown_recovery_value",))
        self.assertFalse(any(e.code == "caller_state_mismatch" for e in unknown.evidence))

    def test_frame_lr_rule_uses_the_saved_identity(self):
        # An owned unusual but explicitly restored function: actual original LR
        # is at SP+8, while the metadata's frame-record LR slot holds original x9.
        words = (0xD10083FF, 0xA9007BFF, 0xA90127FD, 0x910043FD,
                 BL, 0xA94127FD, 0xA9407BFF, 0x910083FF, RET)
        result = check(words)
        self.assertEqual(result.verdict, "inconsistency")
        self.assertEqual((result.evidence[0].expected, result.evidence[0].observed),
                         ("original x30", "original x9"))

    def test_unknown_fp_frame_record_is_not_a_known_mismatch(self):
        words = (0xA9BF7BFF, NOP, BL, 0xA8C17BFF, RET)
        result = check(words)
        self.assertEqual(result.verdict, "unresolved")
        self.assertEqual(result.reason_codes, ("unknown_recovery_value",))

    def test_nop_leaf_and_post_return_nop_padding(self):
        result = check((NOP, RET, NOP, NOP), 0x02000000)
        self.assertEqual(result.verdict, "agreement")
        self.assertEqual(result.checked_pcs, (BASE,))
        self.assertEqual(result.instruction_count, 4)


class ConservativeBoundaryTests(unittest.TestCase):
    def test_unsupported_anywhere_invalidates_semantics(self):
        for word in (0x00000000, 0x54000040, 0xD503237F, 0xD63F0100,
                     0xF90003F3, 0xADBF7BFD, 0xD503203F):
            for index in (2, 4):
                candidate = FRAME[:index] + (word,) + FRAME[index:]
                with self.subTest(word=hex(word), index=index):
                    result = check(candidate)
                    self.assertEqual(result.verdict, "unresolved")
                    self.assertFalse(result.checked_pcs)

    def test_extra_code_after_return_and_missing_return_are_unresolved(self):
        self.assertEqual(check(FRAME + (0,)).reason_codes, ("non_nop_after_return",))
        self.assertEqual(check(FRAME[:-1]).reason_codes, ("missing_supported_return",))

    def test_no_distinct_observation_is_unresolved(self):
        self.assertEqual(check((RET,), 0x02000000).verdict, "unresolved")
        self.assertEqual(check((0xD10083FF, 0x910083FF, RET), 0x02002000).verdict, "unresolved")
        frame_leaf = FRAME[:3] + FRAME[4:]
        self.assertEqual(check(frame_leaf).reason_codes, ("no_supported_observation",))

    def test_frameless_calls_are_not_leaves(self):
        result = check(FRAME, 0x02001000)
        self.assertEqual(result.verdict, "unresolved")
        self.assertEqual(result.reason_codes, ("frameless_nonleaf_not_modeled",))

    def test_intra_function_bl_is_not_an_external_call_summary(self):
        candidate = FRAME[:3] + (0x94000000,) + FRAME[4:]
        self.assertEqual(check(candidate).reason_codes, ("intra_function_call_not_modeled",))

    def test_nonrestoring_return_is_unresolved_function_shape(self):
        candidate = FRAME[:4] + (0x910043FF, RET)
        result = check(candidate)
        self.assertEqual(result.verdict, "unresolved")
        self.assertEqual(result.reason_codes, ("unmodeled_return_state",))

    def test_unknown_values_are_not_known_identity_mismatches(self):
        candidate = PAIR[:4] + (BL, 0xAA0003F3, BL) + PAIR[6:]
        result = check(candidate, 0x04000000)
        self.assertEqual(result.verdict, "unresolved")
        self.assertEqual(result.reason_codes, ("unknown_recovery_value",))

    def test_stack_address_escape_is_unresolved(self):
        candidate = FRAME[:3] + (0x910003E0,) + FRAME[3:]
        self.assertEqual(check(candidate).reason_codes, ("stack_address_escapes_call",))

    def test_frame_transition_in_body_is_unresolved(self):
        candidate = FRAME[:3] + (0xD28000E0, 0xD10043FF) + FRAME[3:4] + (0x910043FF,) + FRAME[4:]
        self.assertEqual(check(candidate).reason_codes, ("unmodeled_frame_transition",))

    def test_instruction_limit_is_checked_before_analysis(self):
        result = audit_function(*fixture(FRAME), limits=Limits(max_instructions_per_function=5))
        self.assertEqual(result.verdict, "unresolved")
        self.assertEqual(result.reason_codes, ("function_instruction_limit",))


class ResourceBoundaryTests(unittest.TestCase):
    def test_observation_cap_accepts_exact_limit_and_declines_next_state(self):
        cases = (
            (FRAME[:3] + (BL, BL) + FRAME[4:], 0x04000000, (BASE + 12, BASE + 16)),
            ((0xD10083FF, NOP, NOP, 0x910083FF, RET, NOP),
             0x02002000, (BASE + 4, BASE + 8)),
        )
        for words, encoding, expected_pcs in cases:
            with self.subTest(encoding=hex(encoding)):
                exact = audit_function(*fixture(words, encoding),
                                       limits=Limits(max_observations_per_function=2))
                limited = audit_function(*fixture(words, encoding),
                                         limits=Limits(max_observations_per_function=1))
                self.assertEqual((exact.verdict, exact.checked_pcs), ("agreement", expected_pcs))
                self.assertEqual((limited.verdict, limited.reason_codes),
                                 ("unresolved", ("observation_limit",)))
                self.assertFalse(limited.checked_pcs)

    def test_evidence_cap_retains_concrete_discrepancy_and_total(self):
        # x19 is a known constant at two calls; both requested live-register
        # recoveries differ, even when the report has room for one detail.
        words = PAIR[:6] + (BL,) + PAIR[6:]
        result = audit_function(*fixture(words, 0x04000000),
                                limits=Limits(max_evidence_per_function=1))
        self.assertEqual(result.verdict, "inconsistency")
        self.assertEqual(len(result.checked_pcs), 2)
        self.assertEqual(len(result.evidence), 1)
        self.assertEqual((result.evidence[0].code, result.evidence[0].expected,
                          result.evidence[0].observed),
                         ("caller_state_mismatch", "original x19", "constant 0x7"))
        self.assertTrue(any("retained 1 of 2" in note for note in result.limitations))

    def test_later_unknown_overrides_already_full_mismatch_display(self):
        # First call: x19 is constant 7. Second call: x19 came from volatile
        # x0 after the first call and is unknown. The epilogue restores x19.
        words = PAIR[:6] + (0xAA0003F3, BL) + PAIR[6:]
        result = audit_function(*fixture(words, 0x04000000),
                                limits=Limits(max_evidence_per_function=1))
        self.assertEqual((result.verdict, result.reason_codes),
                         ("unresolved", ("unknown_recovery_value",)))
        self.assertFalse(result.checked_pcs)
        self.assertEqual(len(result.evidence), 1)
        self.assertEqual(result.evidence[0].code, "unknown_recovery_value")
        self.assertTrue(any("retained 1 of 2" in note for note in result.limitations))

    def test_unknown_summary_uses_one_of_the_evidence_slots(self):
        # This frame allocates only FP/LR storage. Both pair-rule reads below
        # it are unknown: two recovery details plus one unresolved summary.
        result = audit_function(*fixture(FRAME, 0x04000001),
                                limits=Limits(max_evidence_per_function=2))
        self.assertEqual((result.verdict, result.reason_codes),
                         ("unresolved", ("unknown_recovery_value",)))
        self.assertEqual(len(result.evidence), 2)
        self.assertIsNone(result.evidence[0].expected)
        self.assertEqual(result.evidence[1].expected, "original x19")
        self.assertTrue(any("retained 2 of 3" in note for note in result.limitations))

    def test_zero_evidence_cap_cannot_support_a_verdict_or_erase_reason(self):
        limits = Limits(max_evidence_per_function=0)
        for words in (FRAME, PAIR):
            with self.subTest(words=words):
                result = audit_function(*fixture(words, 0x04000000), limits=limits)
                self.assertEqual((result.verdict, result.reason_codes),
                                 ("unresolved", ("evidence_limit",)))
                self.assertFalse(result.evidence)
                self.assertFalse(result.checked_pcs)
                self.assertTrue(any("retained 0 of " in note for note in result.limitations))
        image, function, _ = fixture(FRAME)
        missing = audit_function(image, function, None, limits=limits)
        self.assertEqual((missing.verdict, missing.coverage, missing.reason_codes),
                         ("unresolved", "none", ("missing_unwind_metadata",)))
        self.assertFalse(missing.evidence)


if __name__ == "__main__":
    unittest.main()
