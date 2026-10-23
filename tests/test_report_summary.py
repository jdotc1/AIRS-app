"""Small synthetic saved-report projections; no images or sealed receipts used."""
from copy import deepcopy
import unittest

from airs.report_summary import summarize_report


def saved_report():
    findings = []
    for i, verdict in enumerate(("agreement", "inconsistency", "unresolved")):
        findings.append({
            "id": "airsf-" + str(i) * 64,
            "function": {"name": "f" + str(i), "address": hex(0x1000 + i * 16),
                         "end_address": hex(0x1010 + i * 16), "image_offset": hex(i * 16),
                         "size": 16, "boundary_source": "lc_function_starts"},
            "verdict": verdict,
            "coverage": "none" if verdict == "unresolved" else "compact",
            "mode": "none" if verdict == "unresolved" else "frame",
            "scope": "metadata_only" if verdict == "unresolved" else "synchronous_call_sites",
            "encoding": None if verdict == "unresolved" else "0x4000000",
            "checked_pcs": [] if verdict == "unresolved" else [hex(0x1004 + i * 16)],
            "instruction_count": 4,
            "reason_codes": ["shared_reason", "shared_reason"],
            "limitations": ["bounded scope"], "evidence": [{"code": "synthetic", "message": "full evidence"}],
        })
    return {
        "schema_version": 1, "report_kind": "airs.audit",
        "generator": {"name": "AIRS", "version": "synthetic", "analysis_model_version": "future-model"},
        "image": {"display_name": "synthetic", "file_type": "dylib",
                  "architecture": "arm64e", "cpu_subtype": 2,
                  "container_sha256": "1" * 64, "slice_sha256": "2" * 64,
                  "slice_offset": 4096, "slice_size": 48, "preferred_base": "0x1000", "uuid": None},
        "analysis_config": {"limits": {"max_total_instructions": 12}},
        "summary": {"function_count": 3, "agreement_count": 1, "inconsistency_count": 1,
                    "unresolved_count": 1, "checked_pc_count": 2, "metadata_entry_count": 1},
        "findings": findings,
        "metadata_ranges": [{"mode": "frame", "start": "0x1000", "end": "0x1030",
                             "encoding": "0x4000000"}],
        "issues": [{"code": "budget", "message": "bounded"}],
        "limitations": ["saved source limit"],
    }


class ReportSummaryTests(unittest.TestCase):
    def test_unresolved_and_supported_reasons_remain_separate(self):
        summary = summarize_report(saved_report())
        self.assertEqual(summary["finding_counts"]["by_verdict"],
                         {"agreement": 1, "inconsistency": 1, "unresolved": 1})
        self.assertEqual(summary["summary"]["function_count"], 3)
        self.assertEqual(summary["finding_counts"]["by_scope"],
                         {"metadata_only": 1, "synchronous_call_sites": 2})
        for verdict in ("agreement", "inconsistency", "unresolved"):
            self.assertEqual(summary["reason_counts_by_verdict"][verdict], {"shared_reason": 1})
        self.assertEqual(summary["metadata"]["issue_count"], 1)

    def test_exact_source_identity_model_config_and_absence(self):
        report = saved_report()
        summary = summarize_report(report)
        self.assertEqual(summary["report_kind"], "airs.report_summary")
        for key in ("schema_version", "report_kind", "generator", "image", "analysis_config"):
            self.assertEqual(summary["source_report"][key], report[key])
        del report["analysis_config"]
        self.assertNotIn("analysis_config", summarize_report(report)["source_report"])

    def test_detached_projection_keeps_additive_identity_and_counts(self):
        report = saved_report()
        report["image"]["future_identity"] = {"values": [1]}
        report["summary"]["future_count"] = 7
        report["analysis_config"]["future_policy"] = {"values": [2]}
        original = deepcopy(report)
        summary = summarize_report(report)
        self.assertEqual(report, original)
        self.assertEqual(summary["summary"]["future_count"], 7)
        summary["source_report"]["image"]["future_identity"]["values"].append(3)
        summary["source_report"]["analysis_config"]["future_policy"]["values"].append(4)
        summary["findings"][0]["checked_pcs"].clear()
        self.assertEqual(report, original)
        self.assertEqual(summarize_report(report), summarize_report(report))

    def test_zero_findings_and_all_agreements_never_emit_binary_pass(self):
        report = saved_report()
        report["findings"] = []
        report["summary"].update(function_count=0, agreement_count=0, inconsistency_count=0,
                                 unresolved_count=0, checked_pc_count=0)
        summary = summarize_report(report)
        self.assertNotIn("verdict", summary)
        self.assertNotIn("status", summary)
        self.assertTrue(any("not a whole-binary pass" in text for text in summary["limitations"]))
        report = saved_report()
        report["findings"] = report["findings"][:1]
        report["summary"].update(function_count=1, agreement_count=1, inconsistency_count=0,
                                 unresolved_count=0, checked_pc_count=1)
        summary = summarize_report(report)
        self.assertEqual(summary["finding_counts"]["by_verdict"]["unresolved"], 0)
        self.assertNotIn("verdict", summary)
        self.assertEqual(summary["findings"][0]["scope"], "synchronous_call_sites")
