"""File selection, bounded analysis orchestration and stable report assembly."""
from __future__ import annotations

from bisect import bisect_right
from collections import Counter
from dataclasses import asdict, replace
import hashlib
import plistlib
from pathlib import Path
import stat

from . import ANALYSIS_MODEL_VERSION, REPORT_SCHEMA_VERSION, __version__
from .audit import encoding_mode as _mode
from .cfg import audit_current_function
from .compact import parse_compact_unwind
from .dwarf_cfi import parse_eh_frame
from .macho import parse_macho
from .types import AuditResult, Evidence, InputError, Issue, Limits


GLOBAL_LIMITATIONS = [
    "This is a bounded static model, not a proof that a binary always unwinds correctly.",
    "Compact unwind is checked at supported synchronous call states or explicitly labeled leaf-body states; no asynchronous or all-PC guarantee is made.",
    "Unsupported instructions, flow outside the bounded CFG and at-most-two sequential disjoint natural-loop subset, unsupported CFI, ARM64e/PAC and SIMD saves remain unresolved.",
    "Exception personalities, LSDA behavior, runtime stack contents and executable behavior are not validated.",
    "The inspected file is read as data and is never loaded or executed.",
    "Selecting a .app analyzes its principal executable; embedded images are not recursively scanned in this version.",
]


def resolve_input(path: Path | str) -> Path:
    """Resolve a file or the principal executable of an explicitly selected .app."""
    candidate = Path(path).expanduser().resolve()
    if candidate.is_dir():
        if candidate.suffix.lower() != ".app":
            raise InputError("unsupported_directory", "Select a Mach-O file or a .app bundle; recursive scanning is not implemented")
        plist = candidate / "Contents" / "Info.plist"
        try:
            if plist.stat().st_size > 1024 * 1024:
                raise InputError("oversized_plist", "The app Info.plist exceeds the 1 MiB input limit")
            with plist.open("rb") as handle:
                contents = plistlib.loads(handle.read(1024 * 1024 + 1))
        except (OSError, ValueError, plistlib.InvalidFileException) as exc:
            raise InputError("invalid_bundle", f"Cannot read the selected app's Info.plist: {exc}") from exc
        name = contents.get("CFBundleExecutable") if isinstance(contents, dict) else None
        if not isinstance(name, str) or not name or name in (".", "..") or Path(name).name != name or "\\" in name:
            raise InputError("invalid_bundle_executable", "CFBundleExecutable must name one executable inside Contents/MacOS")
        candidate = candidate / "Contents" / "MacOS" / name
        resolved = candidate.resolve()
        if not resolved.is_relative_to((candidate.parent).resolve()):
            raise InputError("bundle_executable_escape", "The app executable resolves outside Contents/MacOS")
        candidate = resolved
    try:
        mode = candidate.stat().st_mode
    except OSError as exc:
        raise InputError("unreadable_input", f"Cannot access the selected input: {exc}") from exc
    if not stat.S_ISREG(mode):
        raise InputError("not_regular_file", "The input must be a regular local file")
    return candidate


def _serialize_evidence(evidence: Evidence) -> dict:
    result = asdict(evidence)
    if evidence.address is not None:
        result["address"] = hex(evidence.address)
    return {key: value for key, value in result.items() if value is not None}


def audit_path(path: Path | str, *, requested_arch: str = "auto", limits: Limits = Limits(), include_path: bool = False) -> dict:
    input_path = resolve_input(path)
    try:
        if input_path.stat().st_size > limits.max_file_bytes:
            raise InputError("file_size_limit", f"Input exceeds the {limits.max_file_bytes} byte limit")
        with input_path.open("rb") as handle:
            data = handle.read(limits.max_file_bytes + 1)
    except OSError as exc:
        raise InputError("unreadable_input", f"Cannot read input: {exc}") from exc
    if len(data) > limits.max_file_bytes:
        raise InputError("file_size_limit", "Input grew beyond the configured size limit while reading")
    image = parse_macho(data, str(input_path), limits, requested_arch)
    table = parse_compact_unwind(image, limits)
    cfi_table = None
    if any(_mode(entry.encoding) == "dwarf" for entry in table.entries):
        try:
            cfi_table = parse_eh_frame(image, limits)
        except InputError as error:
            # A malformed or unsupported table remains metadata, never a defect.
            cfi_table = error
    starts = [entry.start for entry in table.entries]
    findings: list[dict] = []
    issues = list(image.issues) + list(table.issues)
    remaining_instructions = limits.max_total_instructions
    remaining_evidence = limits.max_total_evidence
    remaining_cfg_steps = limits.max_total_cfg_steps
    cfg_budget_exhausted = False
    budget_exhausted = False
    evidence_budget_exhausted = False

    for function in image.functions:
        index = bisect_right(starts, function.start) - 1
        entry = table.entries[index] if index >= 0 and table.entries[index].start <= function.start < table.entries[index].end else None
        entry_coverage = ("dwarf_reference" if _mode(entry.encoding) == "dwarf" else "compact") if entry else "unavailable"
        # A single compact range may legitimately cover several functions. The
        # converse requires PC-sensitive rules, deliberately not implemented here.
        split = entry is not None and entry.end < function.end
        later = bisect_right(starts, function.start)
        split = split or (later < len(starts) and starts[later] < function.end)
        estimated_instructions = (function.size + 3) // 4
        if remaining_evidence < max(1, limits.max_evidence_per_function):
            evidence_budget_exhausted = True
            outcome = AuditResult("unresolved", entry_coverage, _mode(entry.encoding) if entry else "unknown", "metadata_only", ("report_evidence_budget",), limitations=("The remaining evidence budget cannot hold the next bounded analysis; this function is explicitly unresolved.",))
        elif split:
            outcome = AuditResult("unresolved", entry_coverage, _mode(entry.encoding) if entry else "unknown", "metadata_only", ("multiple_metadata_ranges",), evidence=(Evidence("range_split", "The function intersects multiple metadata ranges; PC-sensitive rule selection is not yet implemented", function.start),)[:limits.max_evidence_per_function])
        elif estimated_instructions > remaining_instructions:
            budget_exhausted = True
            outcome = AuditResult("unresolved", entry_coverage, _mode(entry.encoding) if entry else "unknown", "metadata_only", ("total_instruction_budget",), limitations=("The report includes this function, but the total instruction budget prevented semantic analysis.",))
        else:
            remaining_instructions -= estimated_instructions
            effective = replace(limits,max_cfg_steps_per_function=min(limits.max_cfg_steps_per_function,remaining_cfg_steps))
            outcome = audit_current_function(image, function, entry, effective, cfi_table=cfi_table)
            remaining_cfg_steps = max(0,remaining_cfg_steps-outcome.cfg_steps)
            if outcome.reason_codes == ("cfg_work_limit",) and remaining_cfg_steps == 0:
                cfg_budget_exhausted = True
        remaining_evidence -= len(outcome.evidence)

        stable_key = f"{REPORT_SCHEMA_VERSION}:{ANALYSIS_MODEL_VERSION}:{image.slice_sha256}:{image.architecture}:{function.start:x}:{function.end:x}"
        finding = {
            "id": "airsf-" + hashlib.sha256(stable_key.encode()).hexdigest(),
            "function": {"name": function.name, "address": hex(function.start), "end_address": hex(function.end), "image_offset": hex(function.start - image.preferred_base), "size": function.size, "boundary_source": function.boundary_source},
            "verdict": outcome.verdict,
            "coverage": outcome.coverage,
            "mode": outcome.mode,
            "encoding": f"0x{entry.encoding:08x}" if entry else None,
            "scope": outcome.scope,
            "reason_codes": list(outcome.reason_codes),
            "checked_pcs": [hex(pc) for pc in outcome.checked_pcs],
            "instruction_count": outcome.instruction_count,
            "evidence": [_serialize_evidence(e) for e in outcome.evidence],
            "limitations": list(outcome.limitations),
        }
        findings.append(finding)

    if cfg_budget_exhausted:
        issues.append(Issue("cfg_budget_reached", "The total CFG state-visit budget was exhausted; affected functions remain unresolved"))
    if budget_exhausted:
        issues.append(Issue("analysis_budget_reached", "The configured total instruction budget was reached; affected functions are explicitly unresolved"))
    if evidence_budget_exhausted:
        issues.append(Issue("report_evidence_budget_reached", "The remaining report evidence budget prevented further semantic analysis; affected functions are explicitly unresolved"))
    if not image.functions:
        issues.append(Issue("no_function_boundaries", "No supported function-start source is available; metadata ranges are displayed without semantic findings"))
    counts = Counter(f["verdict"] for f in findings)
    identity = {
        "display_name": input_path.name,
        "architecture": image.architecture,
        "cpu_subtype": image.cpu_subtype,
        "uuid": image.uuid,
        "container_sha256": image.container_sha256,
        "slice_sha256": image.slice_sha256,
        "slice_offset": image.slice_offset,
        "slice_size": image.slice_size,
        "preferred_base": hex(image.preferred_base),
        "file_type": {2: "execute", 6: "dylib", 8: "bundle"}.get(image.file_type, "unknown"),
    }
    if include_path:
        identity["path"] = str(input_path)
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "report_kind": "airs.audit",
        "generator": {"name": "AIRS", "version": __version__, "analysis_model_version": ANALYSIS_MODEL_VERSION},
        "analysis_config": {"limits": asdict(limits)},
        "image": identity,
        "summary": {"function_count": len(findings), "agreement_count": counts["agreement"], "inconsistency_count": counts["inconsistency"], "unresolved_count": counts["unresolved"], "metadata_entry_count": len(table.entries), "checked_pc_count": sum(len(f["checked_pcs"]) for f in findings)},
        "issues": [{k: v for k, v in asdict(issue).items() if v is not None} for issue in issues],
        "metadata_ranges": [{"start": hex(e.start), "end": hex(e.end), "encoding": f"0x{e.encoding:08x}", "mode": _mode(e.encoding)} for e in table.entries],
        "findings": findings,
        "limitations": GLOBAL_LIMITATIONS,
    }
