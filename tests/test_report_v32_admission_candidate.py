"""NEW Python v32 report-admission tests; no accepted fixture is read or changed.

These synthetic objects test structural admission, never analysis truth.
Digest-shaped fields are explicit placeholders, not newly computed receipts.
Unknown model IDs retain the existing generic navigation/import contract.
"""
from copy import deepcopy
import unittest

from airs.report import validate_report
from airs.types import InputError


V32 = "arm64-bounded-clz-v32"


def synthetic_report(model=V32):
    return {
        "schema_version": 1,
        "report_kind": "airs.audit",
        "generator": {"name": "AIRS", "version": "0.2.0", "analysis_model_version": model},
        "image": {
            "display_name": "synthetic-admission-control",
            "path": None,
            "architecture": "arm64",
            "file_type": "dylib",
            "uuid": None,
            "container_sha256": "1" * 64,
            "slice_sha256": "2" * 64,
            "cpu_subtype": 0,
            "slice_offset": 0,
            "slice_size": 16,
            "preferred_base": "0x1000",
        },
        "findings": [{
            "id": "airsf-" + "a" * 64,
            "function": {
                "name": "synthetic_function",
                "boundary_source": "lc_function_starts",
                "address": "0x1000",
                "end_address": "0x1010",
                "image_offset": "0x0",
                "size": 16,
            },
            "verdict": "agreement",
            "coverage": "compact",
            "mode": "frame",
            "scope": "synchronous_call_sites",
            "encoding": "0x4000000",
            "checked_pcs": ["0x1008"],
            "instruction_count": 4,
            "reason_codes": ["supported_model_agreement"],
            "limitations": ["Synthetic admission test; no binary analyzed"],
            "evidence": [],
        }],
        "metadata_ranges": [{"start": "0x1000", "end": "0x1010", "encoding": "0x4000000", "mode": "frame"}],
        "issues": [],
        "limitations": [],
        "summary": {
            "function_count": 1,
            "agreement_count": 1,
            "inconsistency_count": 0,
            "unresolved_count": 0,
            "metadata_entry_count": 1,
            "checked_pc_count": 1,
        },
    }


def replace_mode(report, *, mode, scope, encoding, coverage="compact"):
    report["findings"][0].update(mode=mode, scope=scope, encoding=encoding, coverage=coverage)
    report["metadata_ranges"][0].update(mode=mode, encoding=encoding or "0x0")


def make_unresolved(report):
    report["findings"][0].update(
        verdict="unresolved", scope="metadata_only", checked_pcs=[],
        coverage="unavailable", mode="unknown", encoding=None,
        reason_codes=["synthetic_unknown_model"],
    )
    report["summary"].update(agreement_count=0, unresolved_count=1, checked_pc_count=0)


class V32AdmissionCandidateTests(unittest.TestCase):
    def assert_rejected(self, report):
        with self.assertRaises(InputError) as error:
            validate_report(report)
        self.assertEqual(error.exception.code, "invalid_report")

    def test_valid_v32_frame_findings_accept_exact_ordinary_subtypes(self):
        for subtype in (0, 1):
            for verdict in ("agreement", "inconsistency"):
                with self.subTest(subtype=subtype, verdict=verdict):
                    report = synthetic_report()
                    report["image"]["cpu_subtype"] = subtype
                    report["findings"][0]["verdict"] = verdict
                    report["summary"].update(agreement_count=int(verdict == "agreement"),
                                              inconsistency_count=int(verdict == "inconsistency"))
                    self.assertIs(validate_report(report), report)

    def test_valid_v32_frameless_finding_keeps_leaf_scope(self):
        report = synthetic_report()
        replace_mode(report, mode="frameless", scope="modeled_leaf_body", encoding="0x2001000")
        self.assertIs(validate_report(report), report)

    def test_valid_v32_dwarf_finding_keeps_evaluated_coverage(self):
        report = synthetic_report()
        replace_mode(report, mode="dwarf", scope="synchronous_call_sites", encoding="0x3000004", coverage="dwarf_evaluated")
        self.assertIs(validate_report(report), report)

    def test_v32_supported_arm64e_claim_is_rejected(self):
        report = synthetic_report()
        report["image"].update(architecture="arm64e", cpu_subtype=2)
        self.assert_rejected(report)

    def test_v32_nonordinary_low_subtype_is_rejected(self):
        for subtype in (2, 4, 0x00FFFFFF):
            with self.subTest(subtype=subtype):
                report = synthetic_report()
                report["image"]["cpu_subtype"] = subtype
                self.assert_rejected(report)

    def test_v32_capability_bits_do_not_pass_the_masked_subtype_check(self):
        for subtype in (0x80000000, 0x80000001, 0x01000000, 0x01000001):
            with self.subTest(subtype=hex(subtype)):
                report = synthetic_report()
                report["image"]["cpu_subtype"] = subtype
                self.assert_rejected(report)

    def test_v32_compact_findings_require_exact_independent_boundary_source(self):
        for source in ("compact_unwind", "symbols", "lc_function_starts_suffix", "unavailable"):
            with self.subTest(source=source):
                report = synthetic_report()
                report["findings"][0]["function"]["boundary_source"] = source
                self.assert_rejected(report)

    def test_v32_encoding_mode_and_scope_must_agree(self):
        cases = (
            ("frame", "modeled_leaf_body", "0x4000000"),
            ("frameless", "synchronous_call_sites", "0x2000000"),
            ("frame", "synchronous_call_sites", "0x2000000"),
            ("frameless", "modeled_leaf_body", "0x4000000"),
            ("pauth_frame", "synchronous_call_sites", "0x4000000"),
        )
        for mode, scope, encoding in cases:
            with self.subTest(mode=mode, scope=scope, encoding=encoding):
                report = synthetic_report()
                replace_mode(report, mode=mode, scope=scope, encoding=encoding)
                self.assert_rejected(report)

    def test_v32_compact_encoding_cannot_request_unmodeled_recovery(self):
        cases = (
            ("frame", "synchronous_call_sites", "0x4000100"),  # SIMD-save bit.
            ("frame", "synchronous_call_sites", "0x4000020"),  # Reserved low bit.
            ("frame", "synchronous_call_sites", "0x4010000"),  # Unsupported frame bits.
            ("frameless", "modeled_leaf_body", "0x2000001"),  # Saved pair in frameless mode.
            ("frameless", "modeled_leaf_body", "0x2000100"),  # SIMD-save bit in frameless mode.
        )
        for mode, scope, encoding in cases:
            with self.subTest(mode=mode, encoding=encoding):
                report = synthetic_report()
                replace_mode(report, mode=mode, scope=scope, encoding=encoding)
                self.assert_rejected(report)

    def test_v32_dwarf_requires_evaluated_coverage(self):
        for coverage in ("dwarf_reference", "compact"):
            with self.subTest(coverage=coverage):
                report = synthetic_report()
                replace_mode(report, mode="dwarf", scope="synchronous_call_sites", encoding="0x3000004", coverage=coverage)
                self.assert_rejected(report)

    def test_v32_dwarf_requires_independent_boundaries(self):
        report = synthetic_report()
        replace_mode(report, mode="dwarf", scope="synchronous_call_sites", encoding="0x3000004", coverage="dwarf_evaluated")
        report["findings"][0]["function"]["boundary_source"] = "compact_unwind"
        self.assert_rejected(report)

    def test_v32_dwarf_requires_a_present_dwarf_encoding(self):
        for encoding in (None, "0x4000000", "0x2000000"):
            with self.subTest(encoding=encoding):
                report = synthetic_report()
                replace_mode(report, mode="dwarf", scope="synchronous_call_sites", encoding=encoding, coverage="dwarf_evaluated")
                self.assert_rejected(report)

    def test_unresolved_v32_remains_available_for_navigation(self):
        report = synthetic_report()
        make_unresolved(report)
        report["image"].update(architecture="arm64e", cpu_subtype=2)
        report["findings"][0]["function"]["boundary_source"] = "unavailable"
        self.assertIs(validate_report(report), report)

    def test_unknown_models_keep_generic_import_without_becoming_known_models(self):
        # These remain wire-format imports only. No prefix or future version is
        # treated as a registered v32 semantic model by this maintenance patch.
        for model in ("future-owned-model", "arm64-bounded-clz-v32-extra", "arm64-bounded-rbit-v33"):
            with self.subTest(model=model):
                report = synthetic_report(model)
                report["image"]["cpu_subtype"] = 0x80000000
                report["findings"][0]["function"]["boundary_source"] = "future-boundary-kind"
                self.assertIs(validate_report(report), report)
                self.assertEqual(report["generator"]["analysis_model_version"], model)

    def test_generic_guards_still_apply_to_unknown_model_imports(self):
        base = synthetic_report("future-owned-model")
        mutations = (
            lambda report: report["findings"][0].update(encoding="0x0"),
            lambda report: report["findings"][0].update(checked_pcs=["0x1010"]),
            lambda report: report["image"].update(architecture="x86_64"),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(case=index):
                report = deepcopy(base)
                mutate(report)
                self.assert_rejected(report)

    def test_existing_v31_guard_and_historical_v1_capability_behavior_are_preserved(self):
        report = synthetic_report("arm64-bounded-sequential-loops-v31")
        report["image"]["cpu_subtype"] = 0x80000000
        self.assert_rejected(report)
        historical = synthetic_report("arm64-linear-v1")
        historical["image"]["cpu_subtype"] = 0x80000000
        self.assertIs(validate_report(historical), historical)

    def test_unknown_additive_schema_fields_still_pass(self):
        report = synthetic_report()
        report["future_annotation"] = {"owned_note": "ignored additive field"}
        report["findings"][0]["future_evidence_hint"] = ["preserved"]
        self.assertIs(validate_report(report), report)


if __name__ == "__main__":
    unittest.main()
