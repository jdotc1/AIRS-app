"""Deterministic terminal-safe text for an existing saved-report summary."""
from __future__ import annotations

import json

from .report import MAX_REPORT_BYTES
from .types import InputError


EXAMPLE_LIMIT = 5
COUNT_ROW_LIMIT = 12
SOURCE_LIMITATION_LIMIT = 5


class _BoundedText:
    def __init__(self, maximum_bytes: int):
        self.maximum_bytes = maximum_bytes
        self.length = 0
        self.parts: list[str] = []

    def _reserve(self, size: int) -> None:
        if self.length + size > self.maximum_bytes:
            raise InputError('generated_report_size_limit',
                             'Generated summary text exceeds the report size limit; no partial report was written')

    def append(self, text: str) -> None:
        self._reserve(len(text) + 1)
        self.parts.extend((text, '\n'))
        self.length += len(text) + 1

    def quoted(self, value) -> str:
        # JSONEncoder can allocate a complete escaped string as one chunk.
        # Count its ASCII expansion first, stopping before that allocation.
        size = 0

        def add(count):
            nonlocal size
            size += count
            self._reserve(size)

        def visit(item):
            if isinstance(item, str):
                add(2)
                for character in item:
                    code = ord(character)
                    add(2 if character in '\"\\\b\f\n\r\t' else
                        6 if code < 32 or 127 <= code <= 65535 else
                        12 if code > 65535 else 1)
            elif isinstance(item, dict):
                add(2 + max(0, len(item) - 1) * 2 + len(item) * 2)
                for key, member in item.items():
                    visit(key)
                    visit(member)
            elif isinstance(item, (list, tuple)):
                add(2 + max(0, len(item) - 1) * 2)
                for member in item:
                    visit(member)
            else:
                add(len(json.dumps(item, ensure_ascii=True, allow_nan=False)))

        visit(value)
        return json.dumps(value, ensure_ascii=True, sort_keys=True, allow_nan=False)

    def finish(self) -> str:
        return ''.join(self.parts)


def _count_rows(lines: _BoundedText, title: str, counts: dict) -> None:
    lines.append(title + ':')
    rows = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    for name, count in rows[:COUNT_ROW_LIMIT]:
        lines.append(f'  {lines.quoted(name)}: {lines.quoted(count)}')
    if not rows:
        lines.append('  (none)')
    if len(rows) > COUNT_ROW_LIMIT:
        lines.append(f'  {len(rows) - COUNT_ROW_LIMIT} additional rows omitted')


def render_summary_text(summary: dict, *, maximum_bytes: int = MAX_REPORT_BYTES) -> str:
    """Render :func:`summarize_report` output without I/O or new analysis.

    Counts always refer to the full saved source; clipping applies only to text
    detail rows. No pass/fail result, report admission or identity check occurs.
    All values originating in the summary are emitted as ASCII JSON literals.
    """
    if type(maximum_bytes) is not int or maximum_bytes < 0:
        raise InputError('invalid_report_size_limit',
                         'Summary text byte limit must be a nonnegative integer')
    maximum_bytes = min(maximum_bytes, MAX_REPORT_BYTES)
    source = summary['source_report']
    counts = summary['summary']
    lines = _BoundedText(maximum_bytes)
    lines.append('Saved audit report summary')
    lines.append('Saved image identity: ' + lines.quoted(source['image']))
    lines.append('Saved generator/model: ' + lines.quoted(source['generator']))
    lines.append('Full source counts: ' + lines.quoted(counts))
    lines.append('Function denominator (includes unresolved): ' + lines.quoted(counts['function_count']))
    lines.append('Verdict counts: ' + lines.quoted(summary['finding_counts']['by_verdict']))
    lines.append('Agreement applies only to recorded checked PCs and scope; not a whole-binary pass.')
    lines.append('Saved identity/model are reported, not reverified against current bytes.')
    if 'analysis_config' in source:
        lines.append('Saved analysis configuration: ' + lines.quoted(source['analysis_config']))
    for key, title in (('by_scope', 'Recorded scopes'), ('by_coverage', 'Recorded coverage'), ('by_mode', 'Recorded modes')):
        _count_rows(lines, title, summary['finding_counts'][key])
    for verdict in ('agreement', 'inconsistency', 'unresolved'):
        _count_rows(lines, f'Reasons for {verdict} (overlapping finding counts)',
                    summary['reason_counts_by_verdict'][verdict])
    metadata = summary['metadata']
    lines.append('Metadata entries (not additional functions): ' + lines.quoted(metadata['entry_count']))
    lines.append('Saved metadata issues: ' + lines.quoted(metadata['issue_count']))
    findings = summary['findings']
    row_label = 'saved rows'
    if 'finding_order' in summary:
        lines.append('Finding detail order (as supplied; saved values preserved): ' +
                     lines.quoted(summary['finding_order']))
    if 'finding_selection' in summary:
        lines.append('Finding selection (full source counts above remain unchanged): ' +
                     lines.quoted(summary['finding_selection']))
        row_label = 'selected rows'
    if 'finding_limit' in summary:
        lines.append('Finding detail limit (full source counts above remain unchanged): ' +
                     lines.quoted(summary['finding_limit']))
        row_label = 'retained rows'
    lines.append(f'Finding examples (first {min(len(findings), EXAMPLE_LIMIT)} of {len(findings)} {row_label}):')
    for finding in findings[:EXAMPLE_LIMIT]:
        detail = {key: finding[key] for key in ('id', 'verdict', 'scope', 'mode', 'coverage')}
        detail['name'] = finding['function'].get('name')
        detail['address'] = finding['function'].get('address')
        detail['checked_pc_count'] = len(finding.get('checked_pcs', []))
        lines.append('  ' + lines.quoted(detail))
    if not findings:
        lines.append('  (none)')
    lines.append(f'{max(0, len(findings) - EXAMPLE_LIMIT)} finding examples omitted; full counts above are unchanged.')
    lines.append('Summary caveats:')
    for limitation in summary['limitations']:
        lines.append('  ' + lines.quoted(limitation))
    source_limits = summary['source_limitations']
    lines.append('Saved source caveats:')
    for limitation in source_limits[:SOURCE_LIMITATION_LIMIT]:
        lines.append('  ' + lines.quoted(limitation))
    if not source_limits:
        lines.append('  (none recorded)')
    if len(source_limits) > SOURCE_LIMITATION_LIMIT:
        lines.append(f'  {len(source_limits) - SOURCE_LIMITATION_LIMIT} additional source caveats omitted; consult the saved report.')
    return lines.finish()
