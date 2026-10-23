# Saved-report summary text

`render_summary_text(summary)` renders an existing `airs.report_summary` object
from `summarize_report`. It performs no I/O, admission, analysis, hashing or
identity verification. The caller loads and admits the saved audit report.

The text retains full source summary counts, the complete function denominator
including unresolved findings, all three verdict counts, saved image identity,
generator/model and any recorded analysis configuration. Scope, coverage, mode
and reason counts describe saved findings. Reasons remain grouped by verdict
and can overlap within a verdict. Metadata entries are explicitly separate from
the function denominator. Agreement remains limited to recorded checked PCs and
scope; the text never assigns a whole-binary pass.

To keep detail compact, text includes the first five finding examples in saved
order, at most twelve rows per scope/coverage/mode/reason group, and the first
five source caveats. Clipped groups state their omitted row counts; example
clipping states its omitted count even when zero. All summary caveats are
retained, and source-caveat clipping directs the reader to the saved report.
Counts always describe the complete source. Example details retain finding ID,
name, address, verdict, scope, mode, coverage and checked-PC count so readers can
locate full evidence in the saved report.

Every source value is rendered as ASCII JSON with escaped terminal controls,
ANSI escape characters, newlines and Unicode direction controls. Names and other
untrusted values cannot introduce terminal commands or additional text lines.
Mapping keys are sorted; count rows sort by descending count then code; output
has one final newline and does not mutate its input.

Six methods in `ReportSummaryTextTests` cover full counts/scope and example
clipping, hostile strings, deterministic empty output/count-row clipping, and exact ASCII byte limits.
They are supplied unrun for the first composed verification gate. No passing
test or runtime result is claimed by this document.

`maximum_bytes` defaults to the existing 64 MiB `MAX_REPORT_BYTES` limit.
The renderer bounds cumulative text, including the final newline. JSON string
expansion is counted before allocating quoted strings. Exceeding the budget
raises `InputError` with `generated_report_size_limit`; no partial text is
returned and no output is written. A small-budget regression exercises escaped
Unicode/control expansion and success exactly at the full output byte boundary.

When `finding_selection` is present, its complete metadata is rendered with the
same escaping and byte budget, preserving requested selections and original,
selected and omitted counts. Finding examples then explicitly describe selected
rows. Full source denominator and verdict counts remain unchanged. Selection
omissions and the renderer's example-detail omissions are separate counts.

Explicit byte limits must be exact nonnegative integers; booleans, floats and
other types are rejected with `invalid_report_size_limit`. A requested limit
above `MAX_REPORT_BYTES` is clamped to that global ceiling. Zero is valid as a
budget and refuses this nonempty text output.

Resume qualification: the supplied focused text-rendering methods subsequently
passed in the composed development receipts. The original authoring-only note
above describes the earlier checkpoint. No unchanged method was repeated.
