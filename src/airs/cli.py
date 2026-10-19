"""Small automation surface shared by people, CI and the native app."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from . import __version__
from .bridge import make_handoff
from .diff import compare_reports
from .dsym import attach_dsym
from .coverage import coverage_inventory
from .engine import audit_path, resolve_input
from .report import atomic_write, dumps, load_report, render_html
from .types import InputError


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="airs", description="Bounded offline ARM64 Mach-O unwind diagnostics. A completed report is not a whole-binary pass.")
    parser.add_argument("--version", action="version", version=f"AIRS {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)
    audit = commands.add_parser("audit", help="Analyze one final Mach-O file or the principal executable of a .app")
    audit.add_argument("input", type=Path)
    audit.add_argument("--arch", choices=("auto", "arm64", "arm64e"), default="auto")
    audit.add_argument("--format", choices=("json", "html"), default="json")
    audit.add_argument("--output", type=Path)
    audit.add_argument("--include-path", action="store_true", help="Include the resolved local path in the report")
    audit.add_argument("--fail-on-inconsistency", action="store_true", help="Exit 1 when supported inconsistencies are present; unresolved is still reported separately")
    diff = commands.add_parser("diff", help="Compare two saved audit reports using conservative matching")
    diff.add_argument("--baseline", type=Path, required=True)
    diff.add_argument("--current", type=Path, required=True)
    diff.add_argument("--output", type=Path)
    handoff = commands.add_parser("handoff", help="Export a selected finding using the proposed MacScope adapter contract")
    handoff.add_argument("--report", type=Path, required=True)
    handoff.add_argument("--finding-id", required=True)
    handoff.add_argument("--output", type=Path)
    symbols = commands.add_parser("symbols", help="Attach identity-matched dSYM line locations to a saved audit; no re-analysis")
    symbols.add_argument("--report", type=Path, required=True)
    symbols.add_argument("--dsym", type=Path, required=True)
    symbols.add_argument("--output", type=Path)
    inventory = commands.add_parser("coverage", help="Inventory unresolved reasons in saved reports without re-auditing images")
    inventory.add_argument("--report", type=Path, action="append", required=True)
    inventory.add_argument("--output", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if sys.version_info < (3, 11):
            raise InputError("python_version", "AIRS requires Python 3.11 or later")
        if args.command == "audit":
            source = resolve_input(args.input)
            report = audit_path(source, requested_arch=args.arch, include_path=args.include_path)
            output = render_html(report) if args.format == "html" else dumps(report)
            protected = (source, args.input)
            exit_code = 1 if args.fail_on_inconsistency and report["summary"]["inconsistency_count"] else 0
        elif args.command == "diff":
            report = compare_reports(load_report(args.baseline), load_report(args.current))
            output, protected, exit_code = dumps(report), (args.baseline, args.current), 0
        elif args.command == "symbols":
            report = attach_dsym(load_report(args.report), args.dsym)
            output, protected, exit_code = dumps(report), (args.report, args.dsym), 0
        elif args.command == "coverage":
            if len(args.report) > 128:
                raise InputError("inventory_limit", "At most 128 reports may be inventoried")
            if sum(path.stat().st_size for path in args.report) > 128 * 1024 * 1024:
                raise InputError("inventory_limit", "Combined saved reports exceed 128 MiB")
            report = coverage_inventory([load_report(path) for path in args.report])
            output, protected, exit_code = dumps(report), tuple(args.report), 0
        else:
            report = make_handoff(load_report(args.report), args.finding_id)
            output, protected, exit_code = dumps(report), (args.report,), 0
        if args.output is None:
            sys.stdout.write(output)
        else:
            atomic_write(args.output, output, protected=protected)
            print(json.dumps({"written": str(args.output), "report_kind": report["report_kind"]}, ensure_ascii=True))
        return exit_code
    except InputError as exc:
        error = {"code": exc.code, "message": str(exc)}
        if exc.offset is not None:
            error["offset"] = exc.offset
        print(json.dumps({"error": error}, ensure_ascii=True), file=sys.stderr)
        return 2
    except BrokenPipeError:
        return 2
    except Exception as exc:
        print(json.dumps({"error": {"code": "internal_error", "message": f"{type(exc).__name__}: {exc}"}}, ensure_ascii=True), file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
