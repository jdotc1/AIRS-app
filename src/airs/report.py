"""Report validation, deterministic serialization, safe static HTML and writes."""
from __future__ import annotations

from collections import Counter
from html import escape
import json
import os
from pathlib import Path
import re
import tempfile
import uuid

from .types import InputError
from . import ANALYSIS_MODEL_VERSION

MAX_REPORT_BYTES = 64 * 1024 * 1024
VERDICTS = {"agreement", "inconsistency", "unresolved"}
COVERAGE = {"compact", "dwarf_reference", "dwarf_evaluated", "none", "unavailable"}
MODES = {"frame", "frameless", "dwarf", "pauth_frame", "none", "unknown"}
SCOPES = {"synchronous_call_sites", "modeled_leaf_body", "metadata_only"}
LABELS = {"agreement": "Agreement within scope", "inconsistency": "Supported inconsistency", "unresolved": "Unresolved"}


def dumps(value: dict, *, maximum_bytes: int = MAX_REPORT_BYTES) -> str:
    # ensure_ascii makes character count equal to UTF-8 byte count. Stop before
    # creating a serialized report that the native importer cannot consume.
    encoder = json.JSONEncoder(indent=2, sort_keys=True, ensure_ascii=True, allow_nan=False)
    chunks: list[str] = []
    length = 1  # final newline
    for chunk in encoder.iterencode(value):
        length += len(chunk)
        if length > maximum_bytes:
            raise InputError("generated_report_size_limit", "Generated JSON exceeds the report size limit; no partial report was written")
        chunks.append(chunk)
    return "".join(chunks) + "\n"


def _bad(message: str) -> None:
    raise InputError("invalid_report", message)


def _object(value: object, name: str) -> dict:
    if not isinstance(value, dict):
        _bad(f"{name} must be an object")
    return value


def _string(value: object, name: str, *, maximum: int = 65_536) -> str:
    if not isinstance(value, str) or len(value) > maximum:
        _bad(f"{name} must be a string of at most {maximum} characters")
    return value


def _integer(value: object, name: str, *, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        _bad(f"{name} must be an integer >= {minimum}")
    return value


def _array(value: object, name: str, *, maximum: int = 200_000) -> list:
    if not isinstance(value, list) or len(value) > maximum:
        _bad(f"{name} must be an array with at most {maximum} entries")
    return value


def _strings(value: object, name: str) -> list:
    values = _array(value, name)
    for item in values:
        _string(item, name)
    return values


def _address(value: object, name: str) -> int:
    value = _string(value, name, maximum=18)
    if not re.fullmatch(r"0x[0-9a-f]{1,16}", value):
        _bad(f"{name} must be a lowercase 64-bit hexadecimal address")
    return int(value, 16)


def validate_report(report: object) -> dict:
    """Validate imported v1 reports, including semantic count/identity invariants.

    This checks the wire format, not the truth of an imported analysis. Unknown
    additive fields are permitted in schema v1; unsupported major versions fail.
    """
    report = _object(report, "report")
    if type(report.get("schema_version")) is not int or report["schema_version"] != 1 or report.get("report_kind") != "airs.audit":
        _bad("Expected an airs.audit report with schema_version 1")
    generator = _object(report.get("generator"), "generator")
    for key in ("name", "version", "analysis_model_version"):
        _string(generator.get(key), f"generator.{key}")
    if "analysis_config" in report:
        config = _object(report["analysis_config"], "analysis_config")
        limits = _object(config.get("limits"), "analysis_config.limits")
        for name, value in limits.items():
            _integer(value, f"analysis_config.limits.{name}")
    identity = _object(report.get("image"), "image")
    for key in ("display_name", "architecture", "file_type"):
        _string(identity.get(key), f"image.{key}")
    if identity["architecture"] not in ("arm64", "arm64e"):
        _bad("The report has an unsupported image architecture")
    if identity["file_type"] not in ("execute", "dylib", "bundle"):
        _bad("The report has an unsupported final-image type")
    if identity.get("path") is not None:
        _string(identity["path"], "image.path")
    if identity.get("uuid") is not None:
        try:
            uuid.UUID(_string(identity["uuid"], "image.uuid"))
        except ValueError:
            _bad("image.uuid is not a UUID")
    for key in ("container_sha256", "slice_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", _string(identity.get(key), f"image.{key}")):
            _bad(f"image.{key} is not a SHA-256 digest")
    for key in ("cpu_subtype", "slice_offset", "slice_size"):
        _integer(identity.get(key), f"image.{key}")
    base = _address(identity.get("preferred_base"), "image.preferred_base")
    findings = _array(report.get("findings"), "findings", maximum=50_000)
    ids: set[str] = set()
    for finding in findings:
        finding = _object(finding, "finding")
        fid = _string(finding.get("id"), "finding.id")
        if not re.fullmatch(r"airsf-[0-9a-f]{64}", fid) or fid in ids:
            _bad("Finding IDs must be unique AIRS SHA-256 identifiers")
        ids.add(fid)
        function = _object(finding.get("function"), "function")
        _string(function.get("name"), "function.name")
        _string(function.get("boundary_source"), "function.boundary_source")
        start = _address(function.get("address"), "function.address")
        end = _address(function.get("end_address"), "function.end_address")
        offset = _address(function.get("image_offset"), "function.image_offset")
        size = _integer(function.get("size"), "function.size", minimum=1)
        if end <= start or end - start != size or start - base != offset:
            _bad("Function addresses, size and image-relative offset disagree")
        for field, allowed in (("verdict", VERDICTS), ("coverage", COVERAGE), ("mode", MODES), ("scope", SCOPES)):
            value = _string(finding.get(field), f"finding.{field}")
            if value not in allowed:
                _bad(f"Unknown finding.{field}")
        encoding = None
        if finding.get("encoding") is not None:
            encoding = _address(finding["encoding"], "finding.encoding")
            if encoding > 0xffffffff:
                _bad("finding.encoding exceeds 32 bits")
        checked = _array(finding.get("checked_pcs"), "checked_pcs")
        for address in checked:
            if not start <= _address(address, "checked_pc") < end:
                _bad("A checked PC is outside its function")
        if finding["verdict"] != "unresolved" and (not checked or finding["scope"] == "metadata_only"):
            _bad("Agreement/inconsistency needs checked PCs and an explicit analysis scope")
        if finding["verdict"] != "unresolved":
            if finding["coverage"] not in ("compact", "dwarf_reference", "dwarf_evaluated"):
                _bad("A supported finding must have present unwind metadata")
            if finding["coverage"] == "compact" and not encoding:
                _bad("A supported compact finding must contain a nonzero encoding")
            if generator["analysis_model_version"] in ("arm64-linear-v1", "arm64-linear-dwarf-v2", "arm64-bounded-cfg-v3", "arm64-bounded-calls-v4", "arm64-bounded-dwarf-cfg-v5", "arm64-bounded-returns-v6", "arm64-bounded-teardowns-v7", "arm64-bounded-suffixes-v8", "arm64-bounded-conditional-v9", "arm64-bounded-conditions-v10", "arm64-bounded-flags-v11", "arm64-bounded-register-flags-v12", "arm64-bounded-shifted-flags-v13", "arm64-bounded-extended-flags-v14", "arm64-bounded-logical-flags-v15", "arm64-bounded-logical-immediate-v16", "arm64-bounded-nonflag-immediate-v17", "arm64-bounded-nonflag-register-v18", "arm64-bounded-carry-v19", "arm64-bounded-conditional-compare-v20", "arm64-bounded-conditional-select-v21", "arm64-bounded-bitfield-v22", "arm64-bounded-extract-v23", "arm64-bounded-variable-shift-v24", "arm64-bounded-multiply-v25", "arm64-bounded-widening-multiply-v26", "arm64-bounded-high-multiply-v27", "arm64-bounded-loops-v28", "arm64-bounded-loop-calls-v29", "arm64-bounded-cfa-register-v30", "arm64-bounded-sequential-loops-v31", "arm64-bounded-clz-v32", "arm64-bounded-rbit-v33", "arm64-bounded-udiv-v34", "arm64-bounded-x-stack-v35", "arm64-bounded-fp-x-stack-v36", "arm64-bounded-sdiv-v37", "arm64-bounded-w-rbit-v38", "arm64-bounded-equivalent-compact-v39", "arm64-bounded-local-fde-v40"):
                if identity["architecture"] != "arm64" or identity["cpu_subtype"] & 0x00ffffff not in (0, 1):
                    _bad("This analysis model supports semantic findings only for ordinary ARM64")
                if generator["analysis_model_version"] in ("arm64-bounded-cfg-v3", "arm64-bounded-calls-v4", "arm64-bounded-dwarf-cfg-v5", "arm64-bounded-returns-v6", "arm64-bounded-teardowns-v7", "arm64-bounded-suffixes-v8", "arm64-bounded-conditional-v9", "arm64-bounded-conditions-v10", "arm64-bounded-flags-v11", "arm64-bounded-register-flags-v12", "arm64-bounded-shifted-flags-v13", "arm64-bounded-extended-flags-v14", "arm64-bounded-logical-flags-v15", "arm64-bounded-logical-immediate-v16", "arm64-bounded-nonflag-immediate-v17", "arm64-bounded-nonflag-register-v18", "arm64-bounded-carry-v19", "arm64-bounded-conditional-compare-v20", "arm64-bounded-conditional-select-v21", "arm64-bounded-bitfield-v22", "arm64-bounded-extract-v23", "arm64-bounded-variable-shift-v24", "arm64-bounded-multiply-v25", "arm64-bounded-widening-multiply-v26", "arm64-bounded-high-multiply-v27", "arm64-bounded-loops-v28", "arm64-bounded-loop-calls-v29", "arm64-bounded-cfa-register-v30", "arm64-bounded-sequential-loops-v31", "arm64-bounded-clz-v32", "arm64-bounded-rbit-v33", "arm64-bounded-udiv-v34", "arm64-bounded-x-stack-v35", "arm64-bounded-fp-x-stack-v36", "arm64-bounded-sdiv-v37", "arm64-bounded-w-rbit-v38", "arm64-bounded-equivalent-compact-v39", "arm64-bounded-local-fde-v40") and identity["cpu_subtype"] not in (0,1):
                    _bad("v3 supported findings require an exact ordinary ARM64 subtype")
                dwarf = generator["analysis_model_version"] in ("arm64-linear-dwarf-v2", "arm64-bounded-cfg-v3", "arm64-bounded-calls-v4", "arm64-bounded-dwarf-cfg-v5", "arm64-bounded-returns-v6", "arm64-bounded-teardowns-v7", "arm64-bounded-suffixes-v8", "arm64-bounded-conditional-v9", "arm64-bounded-conditions-v10", "arm64-bounded-flags-v11", "arm64-bounded-register-flags-v12", "arm64-bounded-shifted-flags-v13", "arm64-bounded-extended-flags-v14", "arm64-bounded-logical-flags-v15", "arm64-bounded-logical-immediate-v16", "arm64-bounded-nonflag-immediate-v17", "arm64-bounded-nonflag-register-v18", "arm64-bounded-carry-v19", "arm64-bounded-conditional-compare-v20", "arm64-bounded-conditional-select-v21", "arm64-bounded-bitfield-v22", "arm64-bounded-extract-v23", "arm64-bounded-variable-shift-v24", "arm64-bounded-multiply-v25", "arm64-bounded-widening-multiply-v26", "arm64-bounded-high-multiply-v27", "arm64-bounded-loops-v28", "arm64-bounded-loop-calls-v29", "arm64-bounded-cfa-register-v30", "arm64-bounded-sequential-loops-v31", "arm64-bounded-clz-v32", "arm64-bounded-rbit-v33", "arm64-bounded-udiv-v34", "arm64-bounded-x-stack-v35", "arm64-bounded-fp-x-stack-v36", "arm64-bounded-sdiv-v37", "arm64-bounded-w-rbit-v38", "arm64-bounded-equivalent-compact-v39", "arm64-bounded-local-fde-v40") and finding["mode"] == "dwarf"
                if dwarf:
                    if (finding["coverage"] != "dwarf_evaluated" or identity["cpu_subtype"] not in (0,1)
                            or function["boundary_source"] != "lc_function_starts" or encoding is None
                            or encoding & 0x0f000000 != 0x03000000):
                        _bad("Supported evaluated DWARF findings require evaluated coverage, ordinary subtype, independent boundaries and DWARF encoding")
                elif finding["coverage"] != "compact" or function["boundary_source"] != "lc_function_starts":
                    _bad("This model requires compact metadata and independent code-only function boundaries")
                expected_scope = {"frame": "synchronous_call_sites", "frameless": "modeled_leaf_body"}.get(finding["mode"])
                expected_mode = {"frame": 0x04000000, "frameless": 0x02000000}.get(finding["mode"])
                if not dwarf and (expected_scope is None or finding["scope"] != expected_scope or encoding is None or encoding & 0x0f000000 != expected_mode):
                    _bad("The finding's encoding, mode and scope contradict this analysis model")
                allowed_bits = 0xff00001f | (0x00fff000 if finding["mode"] == "frameless" else 0)
                if not dwarf and (encoding & ~allowed_bits or encoding & 0x00000f00 or (finding["mode"] == "frameless" and encoding & 0x1f)):
                    _bad("The encoding requests recovery outside this analysis model")
        if generator["analysis_model_version"] == "arm64-linear-v1" and finding["coverage"] == "dwarf_evaluated":
            _bad("Historical v1 has no evaluated DWARF coverage")
        _integer(finding.get("instruction_count"), "instruction_count")
        _strings(finding.get("reason_codes"), "reason_codes")
        _strings(finding.get("limitations"), "finding.limitations")
        for evidence in _array(finding.get("evidence"), "evidence"):
            evidence = _object(evidence, "evidence")
            for key in ("code", "message"):
                _string(evidence.get(key), f"evidence.{key}")
            for key in ("expected", "observed"):
                if evidence.get(key) is not None:
                    _string(evidence[key], f"evidence.{key}")
            if evidence.get("address") is not None:
                _address(evidence["address"], "evidence.address")
    ranges = _array(report.get("metadata_ranges"), "metadata_ranges")
    previous_end = 0
    for entry in ranges:
        entry = _object(entry, "metadata range")
        start, end = _address(entry.get("start"), "range.start"), _address(entry.get("end"), "range.end")
        range_mode = _string(entry.get("mode"), "range.mode")
        if end <= start or start < previous_end or _address(entry.get("encoding"), "range.encoding") > 0xffffffff or range_mode not in MODES:
            _bad("Invalid, overlapping or unsorted metadata ranges")
        previous_end = end
    for issue in _array(report.get("issues"), "issues"):
        issue = _object(issue, "issue")
        _string(issue.get("code"), "issue.code")
        _string(issue.get("message"), "issue.message")
        if issue.get("offset") is not None:
            _integer(issue["offset"], "issue.offset")
    _strings(report.get("limitations"), "limitations")
    summary = _object(report.get("summary"), "summary")
    counts = Counter(f["verdict"] for f in findings)
    expected_counts = {"function_count": len(findings), "agreement_count": counts["agreement"], "inconsistency_count": counts["inconsistency"], "unresolved_count": counts["unresolved"], "metadata_entry_count": len(ranges), "checked_pc_count": sum(len(f["checked_pcs"]) for f in findings)}
    for key, expected in expected_counts.items():
        if _integer(summary.get(key), f"summary.{key}") != expected:
            _bad(f"summary.{key} does not match report contents")
    if report.get("source_annotations") is not None:
        from .dsym import validate_annotations
        validate_annotations(report["source_annotations"], report)
    return report


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            _bad(f"Duplicate JSON object key: {key}")
        result[key] = value
    return result


def load_report(path: Path | str) -> dict:
    source = Path(path)
    try:
        if not source.is_file() or source.stat().st_size > MAX_REPORT_BYTES:
            raise InputError("report_size_limit", "Select a regular report file no larger than 64 MiB")
        with source.open("rb") as handle:
            raw = handle.read(MAX_REPORT_BYTES + 1)
        if len(raw) > MAX_REPORT_BYTES:
            raise InputError("report_size_limit", "Report grew beyond the 64 MiB size limit")
        parsed = json.loads(raw, object_pairs_hook=_unique_object, parse_constant=lambda _: _bad("Non-finite JSON number"))
    except (OSError, UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise InputError("unreadable_report", f"Cannot read the audit report: {exc}") from exc
    return validate_report(parsed)


def atomic_write(path: Path | str, text: str, *, protected: tuple[Path | str, ...] = ()) -> None:
    destination = Path(path).expanduser().absolute()
    for item in protected:
        source = Path(item).expanduser()
        same_path = destination.resolve() == source.resolve()
        try:
            same_file = destination.exists() and source.exists() and os.path.samefile(destination, source)
        except OSError:
            same_file = False
        if same_path or same_file:
            raise InputError("input_overwrite", "An output file must not replace an input file")
    if destination.is_dir():
        raise InputError("output_is_directory", "Choose a file path for the report output")
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="\n", dir=destination.parent, prefix=".airs-", delete=False) as handle:
            temporary = handle.name
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        temporary = None
    except OSError as exc:
        raise InputError("output_write_failed", f"Cannot write output: {exc}") from exc
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def render_html(report: dict) -> str:
    validate_report(report)
    esc = lambda value: escape(str(value), quote=True)
    identity, summary = report["image"], report["summary"]
    parts = ["<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>AIRS audit</title>",
        "<style>body{font:15px/1.55 system-ui,sans-serif;color:#17202c;background:#f6f8fb;margin:0}main{max-width:1120px;margin:40px auto;padding:0 24px}h1,h2,h3{line-height:1.2}h1{font-size:34px}code{font:12px ui-monospace,monospace;overflow-wrap:anywhere}section,.card{background:white;padding:22px;border:1px solid #dce2eb;border-radius:12px;margin:16px 0}table{border-collapse:collapse;width:100%}th,td{padding:9px;text-align:left;border-bottom:1px solid #e4e8ef;vertical-align:top}small,.muted{color:#526175}.badge{padding:4px 8px;border-radius:6px;background:#e5edf7;font-weight:600}.inconsistency{background:#ffe1d8}.unresolved{background:#fff0c7}.agreement{background:#dbeee8}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.metric strong{font-size:28px;display:block}a{color:#174f91}pre{white-space:pre-wrap;overflow-wrap:anywhere}details{margin:14px 0}@media print{body{background:white}section{break-inside:avoid}a{color:inherit}}</style><main>",
        f"<p class=\"muted\">AIRS · analysis model {esc(report['generator']['analysis_model_version'])}</p><h1>{esc(identity['display_name'])}</h1><p>{esc(identity['architecture'])} · UUID <code>{esc(identity.get('uuid') or 'unavailable')}</code></p>",
        f"<p>Image SHA-256: <code>{esc(identity['slice_sha256'])}</code></p><div class=\"grid\">",
    ]
    for key, label in (("function_count", "Functions listed"), ("agreement_count", "Agreement within scope"), ("inconsistency_count", "Supported inconsistencies"), ("unresolved_count", "Unresolved")):
        parts.append(f"<div class=\"card metric\"><strong>{summary[key]}</strong>{label}</div>")
    parts.append("</div><section><h2>Scope and limitations</h2><ul>" + "".join(f"<li>{esc(s)}</li>" for s in report["limitations"]) + "</ul></section>")
    if report["issues"]:
        parts.append("<section><h2>Input and coverage notes</h2><ul>" + "".join(f"<li><code>{esc(i['code'])}</code>: {esc(i['message'])}</li>" for i in report["issues"]) + "</ul></section>")
    parts.append("<section><h2>Function index</h2><table><thead><tr><th>Function / preferred VM address</th><th>Finding</th><th>Coverage / scope</th></tr></thead><tbody>")
    for f in report["findings"]:
        parts.append(f"<tr><td><a href=\"#{esc(f['id'])}\">{esc(f['function']['name'])}</a><br><code>{esc(f['function']['address'])}</code></td><td>{LABELS[f['verdict']]}</td><td>{esc(f['coverage'])}<br>{esc(f['scope'])}</td></tr>")
    parts.append("</tbody></table></section>")
    for f in report["findings"]:
        parts.append(f"<section id=\"{esc(f['id'])}\"><h2>{esc(f['function']['name'])}</h2><p><span class=\"badge {f['verdict']}\">{LABELS[f['verdict']]}</span></p><p><code>{esc(f['function']['address'])}–{esc(f['function']['end_address'])}</code> · {esc(f['mode'])} · {esc(f['scope'])}</p><p>Boundary source: {esc(f['function']['boundary_source'])}. Checked PCs: <code>{esc(', '.join(f['checked_pcs']) or 'none')}</code>.</p>")
        for e in f["evidence"]:
            parts.append(f"<h3>{esc(e['code'])}</h3><p>{esc(e['message'])}</p>")
            if e.get("address") is not None:
                parts.append(f"<p>PC: <code>{esc(e['address'])}</code></p>")
            if e.get("expected") is not None or e.get("observed") is not None:
                expected = e["expected"] if e.get("expected") is not None else "unknown"
                observed = e["observed"] if e.get("observed") is not None else "unknown"
                parts.append(f"<table><tr><th>Expected</th><td><code>{esc(expected)}</code></td></tr><tr><th>Observed</th><td><code>{esc(observed)}</code></td></tr></table>")
        parts.append("<p>Reasons: <code>" + esc(", ".join(f["reason_codes"])) + "</code></p>")
        if f["limitations"]:
            parts.append("<ul>" + "".join(f"<li>{esc(x)}</li>" for x in f["limitations"]) + "</ul>")
        parts.append("</section>")
    parts.append("<section><h2>Metadata ranges</h2><details><summary>Show raw compact-range index</summary><table><tr><th>Start</th><th>End</th><th>Encoding</th><th>Mode</th></tr>")
    for r in report["metadata_ranges"]:
        parts.append("<tr>" + "".join(f"<td><code>{esc(r[key])}</code></td>" for key in ("start", "end", "encoding", "mode")) + "</tr>")
    parts.append("</table></details></section><p class=\"muted\">This report records evidence within its stated model. Unresolved findings require further inspection.</p></main></html>\n")
    return "".join(parts)
