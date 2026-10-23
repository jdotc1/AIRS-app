"""Conservative build comparison. Address equality across builds is not identity."""
from __future__ import annotations

from collections import defaultdict

from .report import validate_report


def _identity(report: dict) -> dict:
    return {key: report["image"].get(key) for key in ("display_name", "uuid", "slice_sha256", "architecture")}


def _signature(finding: dict) -> tuple:
    start = int(finding["function"]["address"], 16)
    evidence = tuple((e["code"], e.get("expected"), e.get("observed"), int(e["address"], 16) - start if e.get("address") else None) for e in finding["evidence"])
    return (finding["verdict"], finding["coverage"], finding["mode"], finding["scope"], finding.get("encoding"), tuple(sorted(finding["reason_codes"])), tuple(int(pc, 16) - start for pc in finding["checked_pcs"]), evidence)


def compare_reports(baseline: dict, current: dict) -> dict:
    validate_report(baseline)
    validate_report(current)
    same_image = baseline["image"]["slice_sha256"] == current["image"]["slice_sha256"] and baseline["image"]["architecture"] == current["image"]["architecture"]
    compatible = baseline["generator"]["analysis_model_version"] == current["generator"]["analysis_model_version"] and baseline["image"]["architecture"] == current["image"]["architecture"]
    configuration_changed = baseline.get("analysis_config") != current.get("analysis_config")
    groups: dict[str, dict[str, list]] = defaultdict(lambda: {"before": [], "after": []})

    for side, report in (("before", baseline), ("after", current)):
        for finding in report["findings"]:
            function = finding["function"]
            if same_image:
                key = "offset:" + hex(int(function["image_offset"], 16))
            elif function["name"] and not function["name"].startswith(("sub_", "<", "0x")):
                key = "symbol:" + function["name"]
            else:
                # A stripped function has no reliable cross-build join key yet.
                key = f"unmatched:{side}:{finding['id']}"
            groups[key][side].append(finding)

    summary = {"matched_count": 0, "changed_count": 0, "unchanged_count": 0, "added_count": 0, "removed_count": 0, "ambiguous_count": 0}
    changes: list[dict] = []
    for key in sorted(groups):
        before_group, after_group = groups[key]["before"], groups[key]["after"]
        before = before_group[0] if len(before_group) == 1 else None
        after = after_group[0] if len(after_group) == 1 else None
        notes: list[str] = []
        basis = "exact_image_offset" if key.startswith("offset:") else "unique_symbol" if key.startswith("symbol:") else "unmatched"
        if len(before_group) > 1 or len(after_group) > 1:
            change = "ambiguous"
            notes.append(f"This key has {len(before_group)} baseline and {len(after_group)} current candidates; none was selected automatically.")
        elif before is not None and after is not None:
            summary["matched_count"] += 1
            if not compatible:
                change = "ambiguous"
                notes.append("Analysis model or architecture differs. Reanalyze both inputs with one model before interpreting a verdict change.")
            elif configuration_changed:
                change = "ambiguous"
                notes.append("Analysis configuration differs or is missing from one report. Reanalyze both inputs with one configuration before interpreting a finding change.")
            else:
                change = "unchanged" if _signature(before) == _signature(after) else "changed"
            if basis == "unique_symbol":
                notes.append("Unique symbol-name match is a review candidate; it does not prove source-function identity across builds.")
        elif after is not None:
            change = "added"
            notes.append("No accepted baseline match; this may be a newly named, moved or previously stripped function.")
        else:
            change = "removed"
            notes.append("No accepted current match; absence is not a fixed finding.")
        summary[change + "_count"] += 1
        representative = after or before or (after_group or before_group)[0]
        row = {"key": key, "match_basis": basis, "function_name": representative["function"]["name"], "change": change, "notes": notes}
        for prefix, value in (("baseline", before), ("current", after)):
            if value is not None:
                row[prefix + "_id"] = value["id"]
        if before is not None:
            row.update(before_verdict=before["verdict"], before_scope=before["scope"])
        if after is not None:
            row.update(after_verdict=after["verdict"], after_scope=after["scope"])
        changes.append(row)

    limitations = ["Different build addresses are never joined solely because they are equal.", "Cross-build symbol matches are candidates for review, not guaranteed source identity.", "Added/removed unmatched functions are not automatically regressions/fixes.", "An agreement still has the scope and limitations of its source report."]
    if configuration_changed:
        limitations.append("Analysis configuration differs or is missing from one report; budget-related scope changes require review.")
    return {"schema_version": 1, "report_kind": "airs.diff", "comparison": {"baseline_image": _identity(baseline), "current_image": _identity(current), "same_image": same_image, "model_compatible": compatible, "analysis_configuration_changed": configuration_changed, "matching_policy": "exact_digest_then_unique_symbol"}, "summary": summary, "changes": changes, "limitations": limitations}
