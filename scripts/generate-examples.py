#!/usr/bin/env python3
"""Generate reviewable examples from the owned fixture corpus and current model."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "src"))
from airs.engine import audit_path
from airs.report import atomic_write, dumps, render_html, validate_report
from airs.diff import compare_reports
from airs.bridge import make_handoff


def main() -> None:
    output = ROOT / "examples"
    output.mkdir(exist_ok=True)
    reports = {}
    for name, fixture in (("mixed", "mixed-regular"), ("before", "before"), ("after", "after")):
        report = validate_report(audit_path(ROOT / "fixtures" / "generated" / f"{fixture}.macho"))
        reports[name] = report
        atomic_write(output / f"{name}.audit.json", dumps(report))
    atomic_write(output / "mixed.audit.html", render_html(reports["mixed"]))
    atomic_write(output / "before-after.diff.json", dumps(compare_reports(reports["before"], reports["after"])))
    selected = next(f for f in reports["mixed"]["findings"] if f["verdict"] == "inconsistency")
    atomic_write(output / "selected.macscope-handoff.json", dumps(make_handoff(reports["mixed"], selected["id"])))
    print("Generated three audit reports, one HTML report, one comparison and one handoff")


if __name__ == "__main__":
    main()
