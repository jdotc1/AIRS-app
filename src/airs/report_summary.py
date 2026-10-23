"""Read-only projections of admitted saved audit reports; no analysis is run."""
from __future__ import annotations

from collections import Counter
from copy import deepcopy


SUMMARY_LIMITATIONS = (
    "This summary describes a saved report; its analysis truth and current input bytes were not reverified.",
    "Agreement applies only to each finding's checked PCs and recorded scope; it is not a whole-binary pass.",
    "Unresolved findings remain in the function denominator. Metadata ranges are not additional functions.",
    "No cross-build matching, new audit, target execution or provenance hashing is performed.",
)


def _counts(values) -> dict[str, int]:
    return dict(sorted(Counter(values).items()))


def summarize_report(report: dict) -> dict:
    """Project one report already admitted by :func:`airs.report.load_report`.

    This function performs no I/O, report admission, re-audit or identity checks.
    It returns detached JSON-compatible data without modifying the input. All
    counts describe saved records, not independently verified engine facts.
    Unknown additive fields in copied source objects remain intact. Per-finding
    evidence payloads are intentionally omitted; original IDs locate them in the
    audit report. There is no aggregate verdict or pass/fail status.
    """
    findings = report["findings"]
    verdicts = ("agreement", "inconsistency", "unresolved")
    result = {
        "schema_version": 1,
        "report_kind": "airs.report_summary",
        "source_report": {
            "schema_version": report["schema_version"],
            "report_kind": report["report_kind"],
            "generator": deepcopy(report["generator"]),
            "image": deepcopy(report["image"]),
        },
        "summary": deepcopy(report["summary"]),
        "finding_counts": {
            "by_verdict": {v: sum(f["verdict"] == v for f in findings) for v in verdicts},
            "by_coverage": _counts(f["coverage"] for f in findings),
            "by_mode": _counts(f["mode"] for f in findings),
            "by_scope": _counts(f["scope"] for f in findings),
        },
        "reason_counts_by_verdict": {
            v: _counts(reason for f in findings if f["verdict"] == v
                       for reason in set(f["reason_codes"]))
            for v in verdicts
        },
        "findings": [
            {key: deepcopy(f[key]) for key in (
                "id", "function", "verdict", "coverage", "mode", "scope",
                "encoding", "checked_pcs", "instruction_count", "reason_codes", "limitations",
            ) if key in f}
            for f in findings
        ],
        "metadata": {
            "entry_count": len(report["metadata_ranges"]),
            "entry_counts_by_mode": _counts(r["mode"] for r in report["metadata_ranges"]),
            "issue_count": len(report["issues"]),
            "issues": deepcopy(report["issues"]),
        },
        "source_limitations": deepcopy(report["limitations"]),
        "limitations": list(SUMMARY_LIMITATIONS),
    }
    # Absence is meaningful for historical reports; do not invent defaults.
    if "analysis_config" in report:
        result["source_report"]["analysis_config"] = deepcopy(report["analysis_config"])
    return result
