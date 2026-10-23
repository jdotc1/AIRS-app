"""Saved-report handoff boundaries using small synthetic wire-format records."""
from copy import deepcopy
import unittest

from airs.bridge import make_handoff
from airs.types import InputError


def saved_report():
    return {
        "schema_version": 1, "report_kind": "airs.audit",
        "generator": {"name": "AIRS", "version": "0.1.0",
                      "analysis_model_version": "arm64-linear-v1",
                      "future_provenance": {"notes": ["original"]}},
        "image": {"display_name": "Synthetic saved report", "architecture": "arm64",
                  "file_type": "execute", "cpu_subtype": 0,
                  "uuid": "00010203-0405-0607-0809-0a0b0c0d0e0f",
                  "container_sha256": "a" * 64, "slice_sha256": "b" * 64,
                  "slice_offset": 16384, "slice_size": 8192, "preferred_base": "0x100000000"},
        "findings": [{"id": "airsf-" + "1" * 64,
                      "function": {"name": "_synthetic", "address": "0x100001000",
                                   "end_address": "0x100001020", "image_offset": "0x1000",
                                   "size": 32, "boundary_source": "lc_function_starts"},
                      "verdict": "agreement", "coverage": "compact", "mode": "frame",
                      "encoding": "0x4000000", "scope": "synchronous_call_sites",
                      "checked_pcs": ["0x10000100c"], "instruction_count": 8,
                      "reason_codes": ["modeled_state_agrees"],
                      "evidence": [{"code": "caller_lr", "message": "Synthetic evidence",
                                    "address": "0x10000100c", "expected": "original x30",
                                    "observed": "original x30"}],
                      "limitations": ["Only synchronous call sites are checked."]}],
        "metadata_ranges": [], "issues": [], "limitations": ["Synthetic fixture only."],
        "summary": {"function_count": 1, "agreement_count": 1, "inconsistency_count": 0,
                    "unresolved_count": 0, "metadata_entry_count": 0, "checked_pc_count": 1},
    }


class HandoffBoundaryRegressionTests(unittest.TestCase):
    def test_exported_evidence_and_provenance_are_independent_snapshots(self):
        report = saved_report()
        original = deepcopy(report)
        handoff = make_handoff(report, report["findings"][0]["id"])
        self.assertEqual(handoff["finding"]["scope"], "synchronous_call_sites")
        handoff["finding"]["checked_pcs"].clear()
        handoff["finding"]["evidence"][0]["observed"] = "edited"
        handoff["finding"]["reason_codes"].append("edited")
        handoff["finding"]["limitations"].clear()
        handoff["source_analysis"]["future_provenance"]["notes"].append("edited")
        self.assertEqual(report, original)
        fresh = make_handoff(report, report["findings"][0]["id"])
        frozen = deepcopy(fresh)
        report["findings"][0]["evidence"][0]["message"] = "source edit"
        report["findings"][0]["checked_pcs"].clear()
        report["generator"]["future_provenance"]["notes"].clear()
        self.assertEqual(fresh, frozen)

    def test_snapshot_keeps_unknown_scope_slice_identity_and_offset_spaces(self):
        report = saved_report()
        finding = report["findings"][0]
        finding.update(verdict="unresolved", scope="metadata_only", checked_pcs=[],
                       reason_codes=["unsupported_instruction"], evidence=[])
        report["summary"].update(agreement_count=0, unresolved_count=1, checked_pc_count=0)
        handoff = make_handoff(report, finding["id"])
        self.assertEqual(handoff["finding"]["verdict"], "unresolved")
        self.assertEqual(handoff["finding"]["scope"], "metadata_only")
        self.assertEqual(handoff["finding"]["checked_pcs"], [])
        self.assertEqual(handoff["finding"]["reason_codes"], ["unsupported_instruction"])
        for key in ("uuid", "architecture", "cpu_subtype", "container_sha256", "slice_sha256",
                    "slice_offset", "slice_size", "preferred_base"):
            self.assertEqual(handoff["image"][key], report["image"][key])
        self.assertEqual(handoff["selection"]["address_space"], "preferred_vm")
        self.assertEqual(handoff["selection"]["vm_range"], {"start": "0x100001000", "end": "0x100001020"})
        self.assertEqual(handoff["selection"]["image_relative_range"], {"start": "0x1000", "end": "0x1020"})

    def test_report_admission_and_unknown_finding_still_refuse_export(self):
        report = saved_report()
        with self.assertRaises(InputError) as unknown:
            make_handoff(report, "missing")
        self.assertEqual(unknown.exception.code, "unknown_finding")
        report["findings"][0]["function"]["image_offset"] = "0x5000"
        with self.assertRaises(InputError) as malformed:
            make_handoff(report, report["findings"][0]["id"])
        self.assertEqual(malformed.exception.code, "invalid_report")
