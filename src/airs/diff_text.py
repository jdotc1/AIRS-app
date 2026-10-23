"""Deterministic terminal-safe rendering of an existing saved-report comparison."""
from __future__ import annotations

import json

from .report import MAX_REPORT_BYTES
from .types import InputError


def render_diff_text(comparison: dict, *, maximum_bytes: int = MAX_REPORT_BYTES,
                     maximum_changes: int = 100, maximum_notes: int = 8,
                     maximum_limitations: int = 32) -> str:
    """Render without I/O or analysis; never return a partial oversized report."""
    for value in (maximum_bytes, maximum_changes, maximum_notes, maximum_limitations):
        if type(value) is not int or value < 0:
            raise InputError("invalid_limits", "Text output limits must be nonnegative integers")
    maximum_bytes = min(maximum_bytes, MAX_REPORT_BYTES)
    encoder = json.JSONEncoder(ensure_ascii=True, sort_keys=True, allow_nan=False)
    chunks: list[str] = []
    length = 0

    def append(text: str) -> None:
        nonlocal length
        if length + len(text) > maximum_bytes:
            raise InputError("generated_report_size_limit", "Generated comparison text exceeds the report size limit; no partial report was written")
        chunks.append(text)
        length += len(text)

    def quoted(value: object) -> None:
        for chunk in encoder.iterencode(value):
            append(chunk)

    def field(key: str, value: object, indent: str = "  ") -> None:
        append(indent)
        quoted(key)
        append(": ")
        quoted(value)
        append("\n")

    append("AIRS comparison\nComparison identity and compatibility:\n")
    for key, value in sorted(comparison["comparison"].items()):
        field(key, value)
    append("Full comparison counts (including omitted detail):\n")
    for key, value in sorted(comparison["summary"].items()):
        field(key, value)
    append("Matched counts include review candidates; ambiguous comparison rows are not classified as changed or unchanged.\n")
    append("Added/removed rows have no accepted counterpart; they do not establish a regression or a fix.\n")
    changes = comparison["changes"]
    append("Change detail:\n")
    for index, row in enumerate(changes[:maximum_changes], 1):
        append(f"  Row {index}:\n")
        for key, value in sorted(row.items()):
            if key != "notes":
                field(key, value, "    ")
        notes = row.get("notes", [])
        for note in notes[:maximum_notes]:
            field("note", note, "    ")
        append(f"    Omitted notes: {max(0, len(notes) - maximum_notes)}\n")
    append(f"Omitted change rows: {max(0, len(changes) - maximum_changes)}\n")
    limitations = comparison["limitations"]
    append("Limitations:\n")
    for limitation in limitations[:maximum_limitations]:
        field("limitation", limitation)
    append(f"Omitted limitations: {max(0, len(limitations) - maximum_limitations)}\n")
    return "".join(chunks)
