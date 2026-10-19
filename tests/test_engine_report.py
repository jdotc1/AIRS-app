"""End-to-end diagnostics and report invariants using owned byte fixtures."""
from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

from airs.bridge import destination_matches, make_handoff
from airs.diff import compare_reports
from airs.engine import audit_path, resolve_input
from airs.report import atomic_write, dumps, load_report, render_html, validate_report
from airs.types import InputError, Limits

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "fixtures"))
from generate import generate  # noqa: E402
from parser_helpers import build_macho, regular_unwind  # noqa: E402


class EngineReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temporary.name)
        cls.manifest = generate(cls.directory)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def report(self, name="mixed-regular.macho"):
        return audit_path(self.directory / name)

    def test_mixed_fixture_expected_supported_and_unresolved_results(self):
        report = validate_report(self.report())
        findings = {finding["function"]["name"]: finding for finding in report["findings"]}
        for name, expectation in self.manifest["mixed_expectations"].items():
            with self.subTest(function=name):
                self.assertEqual(findings[name]["verdict"], expectation["verdict"], findings[name])
        self.assertEqual(report["summary"]["agreement_count"], 3)
        self.assertEqual(report["summary"]["inconsistency_count"], 2)
        self.assertEqual(report["summary"]["unresolved_count"], 4)
        self.assertEqual(findings["_frameless_leaf"]["scope"], "modeled_leaf_body")

    def test_regular_and_compressed_formats_have_same_analysis(self):
        before, after = self.report(), self.report("mixed-compressed.macho")
        before_findings, after_findings = before["findings"], after["findings"]
        self.assertEqual(before["summary"], after["summary"])
        for lhs, rhs in zip(before_findings, after_findings):
            for key in ("verdict", "coverage", "mode", "scope", "checked_pcs", "evidence"):
                self.assertEqual(lhs[key], rhs[key])

    def test_fat_auto_selection_preserves_selected_slice_identity(self):
        thin = self.report("before.macho")
        for name in ("universal32.macho", "universal64.macho"):
            fat = self.report(name)
            self.assertEqual(thin["image"]["slice_sha256"], fat["image"]["slice_sha256"])
            self.assertNotEqual(thin["image"]["container_sha256"], fat["image"]["container_sha256"])
            self.assertEqual([f["id"] for f in thin["findings"]], [f["id"] for f in fat["findings"]])

    def test_arm64e_never_issues_a_semantic_agreement(self):
        report = self.report("arm64e.macho")
        self.assertEqual(report["image"]["architecture"], "arm64e")
        self.assertEqual(report["summary"]["unresolved_count"], report["summary"]["function_count"])

    def test_absent_metadata_and_weak_boundaries_are_unresolved(self):
        for name in ("no-unwind.macho", "symbol-boundaries.macho"):
            report = self.report(name)
            self.assertEqual(report["summary"]["unresolved_count"], 3)
            self.assertEqual(report["summary"]["inconsistency_count"], 0)

    def test_metadata_entries_do_not_invent_function_boundaries(self):
        report = self.report("metadata-only.macho")
        self.assertEqual(len(report["metadata_ranges"]), 3)
        self.assertEqual(report["findings"], [])
        self.assertIn("no_function_boundaries", {issue["code"] for issue in report["issues"]})

    def test_analysis_budget_preserves_unresolved_denominator(self):
        report = audit_path(self.directory / "before.macho", limits=Limits(max_total_instructions=0))
        self.assertEqual(report["summary"]["function_count"], 3)
        self.assertEqual(report["summary"]["unresolved_count"], 3)
        self.assertIn("analysis_budget_reached", {i["code"] for i in report["issues"]})

    def test_evidence_budget_preserves_denominator_and_records_configuration(self):
        report = audit_path(self.directory / "before.macho", limits=Limits(max_total_evidence=0))
        self.assertEqual(report["summary"]["function_count"], 3)
        self.assertEqual(report["summary"]["unresolved_count"], 3)
        self.assertEqual(sum(len(f["evidence"]) for f in report["findings"]), 0)
        self.assertEqual(report["analysis_config"]["limits"]["max_total_evidence"], 0)
        self.assertTrue(compare_reports(self.report("before.macho"), report)["comparison"]["analysis_configuration_changed"])

    def test_serialization_size_cap_does_not_emit_partial_json(self):
        with self.assertRaises(InputError) as context:
            dumps({"example": "longer than limit"}, maximum_bytes=8)
        self.assertEqual(context.exception.code, "generated_report_size_limit")

    def test_split_metadata_respects_global_and_function_evidence_caps(self):
        code = struct.pack("<6I", 0xa9bf7bfd, 0x910003fd, 0xd503201f, 0x94000400, 0xa8c17bfd, 0xd65f03c0)
        unwind = regular_unwind(((0x1000, 0x04000000), (0x1004, 0x04000000)), 0x1018)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "split.macho"
            source.write_bytes(build_macho(code, unwind_info=unwind))
            for limits in (Limits(max_total_evidence=0), Limits(max_evidence_per_function=0)):
                report = audit_path(source, limits=limits)
                self.assertEqual(report["summary"]["unresolved_count"], 1)
                self.assertEqual(report["findings"][0]["evidence"], [])

    def test_invalid_negative_limits_are_rejected(self):
        with self.assertRaises(InputError):
            Limits(max_file_bytes=-1)

    def test_same_input_is_deterministic_and_paths_are_opt_in(self):
        first = self.report("before.macho")
        self.assertEqual(dumps(first), dumps(self.report("before.macho")))
        self.assertNotIn("path", first["image"])
        with_path = audit_path(self.directory / "before.macho", include_path=True)
        self.assertEqual(Path(with_path["image"]["path"]), (self.directory / "before.macho").resolve())

    def test_app_selection_resolves_only_principal_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "Owned Example.app"
            (bundle / "Contents" / "MacOS").mkdir(parents=True)
            executable = bundle / "Contents" / "MacOS" / "Owned Example"
            executable.write_bytes((self.directory / "before.macho").read_bytes())
            (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Owned Example"}))
            self.assertEqual(resolve_input(bundle), executable.resolve())
            self.assertEqual(audit_path(bundle)["summary"]["function_count"], 3)
            (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "../escape"}))
            with self.assertRaises(InputError):
                resolve_input(bundle)

    def test_import_rejects_inflated_success_counts_and_unknown_verdicts(self):
        for mutation in ("count", "verdict", "scope", "id"):
            report = self.report("before.macho")
            if mutation == "count":
                report["summary"]["agreement_count"] += 1
            elif mutation == "verdict":
                report["findings"][0]["verdict"] = "safe"
            elif mutation == "scope":
                report["findings"][0]["scope"] = "metadata_only"
            else:
                report["findings"][1]["id"] = report["findings"][0]["id"]
            with self.subTest(mutation=mutation), self.assertRaises(InputError):
                validate_report(report)

    def test_duplicate_json_keys_and_non_finite_numbers_are_rejected(self):
        for raw in ('{"schema_version":1,"schema_version":2}', '{"summary":NaN}'):
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as output:
                output.write(raw)
                path = Path(output.name)
            try:
                with self.assertRaises(InputError):
                    load_report(path)
            finally:
                path.unlink()

    def test_import_rejects_supported_findings_outside_declared_model(self):
        for mutation in ("arm64e", "dwarf", "no_metadata", "simd", "weak_boundary", "wrong_scope"):
            report = self.report("before.macho")
            finding = report["findings"][0]
            if mutation == "arm64e":
                report["image"].update(architecture="arm64e", cpu_subtype=2)
            elif mutation == "dwarf":
                finding.update(mode="dwarf", coverage="dwarf_reference", encoding="0x03000000")
            elif mutation == "no_metadata":
                finding.update(coverage="none", encoding=None)
            elif mutation == "simd":
                finding["encoding"] = "0x04000100"
            elif mutation == "weak_boundary":
                finding["function"]["boundary_source"] = "symbol_table"
            else:
                finding["scope"] = "modeled_leaf_body"
            with self.subTest(mutation=mutation), self.assertRaises(InputError):
                validate_report(report)

    def test_wrong_enum_types_are_input_errors(self):
        for field in ("verdict", "coverage", "mode", "scope"):
            for value in ([], {}, None):
                report = self.report("before.macho")
                report["findings"][0][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(InputError):
                    validate_report(report)
        report = self.report("before.macho")
        report["metadata_ranges"][0]["mode"] = []
        with self.assertRaises(InputError):
            validate_report(report)

    def test_json_roundtrip_and_html_escaping(self):
        report = self.report("before.macho")
        report["findings"][0]["function"]["name"] = '<example a="b">&frame'
        html = render_html(report)
        self.assertIn("&lt;example a=&quot;b&quot;&gt;&amp;frame", html)
        self.assertNotIn('<example a="b">', html)
        self.assertIn("Content-Security-Policy", html)
        self.assertEqual(validate_report(json.loads(dumps(report))), report)

    def test_atomic_output_refuses_input_or_hardlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            source.write_text("preserve", encoding="utf-8")
            link = Path(temporary) / "hardlink"
            link.hardlink_to(source)
            for destination in (source, link):
                with self.assertRaises(InputError):
                    atomic_write(destination, "replace", protected=(source,))
            self.assertEqual(source.read_text(), "preserve")

    def test_diff_detects_supported_rule_changes_by_unique_symbol(self):
        diff = compare_reports(self.report("before.macho"), self.report("after.macho"))
        self.assertEqual(diff["summary"]["matched_count"], 3)
        self.assertEqual(diff["summary"]["changed_count"], 2)
        self.assertEqual(diff["summary"]["unchanged_count"], 1)
        self.assertTrue(all(c["match_basis"] == "unique_symbol" for c in diff["changes"]))

    def test_diff_rejects_address_only_cross_build_matching(self):
        before, after = self.report("before.macho"), self.report("after.macho")
        for report in (before, after):
            for finding in report["findings"]:
                finding["function"]["name"] = "sub_" + finding["function"]["address"]
        diff = compare_reports(before, after)
        self.assertEqual(diff["summary"]["matched_count"], 0)
        self.assertEqual(diff["summary"]["added_count"], 3)
        self.assertEqual(diff["summary"]["removed_count"], 3)

    def test_exact_image_diff_normalizes_equivalent_hex_offsets(self):
        before = self.report("before.macho")
        after = deepcopy(before)
        after["findings"][0]["function"]["image_offset"] = "0x01000"
        diff = compare_reports(before, after)
        self.assertEqual(diff["summary"]["matched_count"], 3)
        self.assertEqual(diff["summary"]["unchanged_count"], 3)

    def test_model_changes_and_duplicate_symbols_are_explicitly_ambiguous(self):
        before, after = self.report("before.macho"), self.report("after.macho")
        after["generator"]["analysis_model_version"] = "future-model"
        self.assertEqual(compare_reports(before, after)["summary"]["ambiguous_count"], 3)
        after["generator"]["analysis_model_version"] = before["generator"]["analysis_model_version"]
        for report in (before, after):
            report["findings"][0]["function"]["name"] = "_duplicate"
            report["findings"][1]["function"]["name"] = "_duplicate"
        self.assertEqual(compare_reports(before, after)["summary"]["ambiguous_count"], 1)

    def test_handoff_requires_exact_slice_identity_and_preserves_address_space(self):
        report = self.report("before.macho")
        handoff = make_handoff(report, report["findings"][0]["id"])
        self.assertEqual(handoff["selection"]["address_space"], "preferred_vm")
        self.assertTrue(destination_matches(handoff, architecture="arm64", slice_sha256=report["image"]["slice_sha256"], uuid=report["image"]["uuid"]))
        self.assertFalse(destination_matches(handoff, architecture="arm64", slice_sha256="0" * 64, uuid=report["image"]["uuid"]))
        self.assertFalse(destination_matches(handoff, architecture="arm64e", slice_sha256=report["image"]["slice_sha256"], uuid=report["image"]["uuid"]))
        with self.assertRaises(InputError):
            make_handoff(report, "not-a-finding")

    def test_handoff_identity_guard_rejects_incomplete_or_malformed_identity(self):
        malformed = {"schema_version": 1, "report_kind": "airs.macscope_handoff", "image": {}}
        self.assertFalse(destination_matches(malformed, architecture=None, slice_sha256=None))
        self.assertFalse(destination_matches([], architecture="arm64", slice_sha256="0" * 64))
        report = self.report("before.macho")
        handoff = make_handoff(report, report["findings"][0]["id"])
        handoff["schema_version"] = True
        self.assertFalse(destination_matches(handoff, architecture="arm64", slice_sha256=report["image"]["slice_sha256"], uuid=report["image"]["uuid"]))


if __name__ == "__main__":
    unittest.main()
