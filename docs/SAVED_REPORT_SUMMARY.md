# Saved audit report summary

The CLI dispatcher provides summaries of admitted saved audit reports:

```text
python3 -I airs_cli.py summary --report FILE [--format json|text] [--verdict CODE ...] [--reason CODE ...] [--sort source|verdict] [--limit N] [--output FILE]
```

JSON is the default. Repeat `--verdict` to select any combination of `agreement`,
`inconsistency` and `unresolved`. Invalid verdict codes are rejected before report
I/O; duplicate codes are normalized to the stable verdict order. Successful
summary output exits 0 without deriving an aggregate pass/fail result. The
saved-report loader admits the source file; no image is opened or re-audited,
no target executes, and no provenance hashes or cross-build matches are computed.

The completed dispatcher loads the report once, calls
`airs.report_summary.summarize_report`, applies
optional detail selection, stable ordering and an explicit detail limit, then renders JSON or
`airs.report_summary_text.render_summary_text`. With `--output`, it uses the
existing protected atomic writer and protects the source report from overwrite.
Without `--output`, output goes to standard output.

## JSON projection

The output has `report_kind: airs.report_summary` and `schema_version: 1`.
`source_report` retains the source schema, kind, generator (including the exact
analysis model), full image identity and analysis configuration when present.
An absent historical configuration remains absent. Source objects and counts
retain additive fields; the input is never modified and returned containers do
not alias it.

`summary` copies all source counts. `finding_counts` counts the full finding
array by verdict, coverage, mode and scope. `reason_counts_by_verdict` counts the
number of findings containing each reason, separately for agreement,
inconsistency and unresolved; repeated reason strings within one finding count
once. Unresolved findings remain in the full function denominator.

`findings` preserves original IDs, function objects, verdicts, coverage, mode,
scope, encoding, checked PCs, instruction counts, reasons and limitations. Full
evidence payloads remain in the original audit report and are located by ID.
`metadata` records entry counts by mode and retains every issue. Metadata ranges
are not additional discovered functions. Source limitations remain separate from
the summary's explicit interpretation limits.

Verdict and literal reason selection change only the detail rows in `findings`.
Repeated reason codes use OR; reason and verdict selections combine with AND.
Reason selection records `requested_reasons` in `finding_selection`.

`--sort verdict` stably groups inconsistency, unresolved and agreement details
after selection. The default source order remains unchanged. `--limit N` accepts
0 through 200000 and retains that many rows after ordering. `finding_order` and
`finding_limit` disclose these operations and their omitted-detail counts.

These operations change only detail presentation. Counts, identity,
configuration, metadata, reasons and limitations continue to describe the full
source report. `finding_selection` records the requested verdicts and selected,
omitted and original finding counts, even when no details match. Without a
selection, that field is absent. Selection never changes a finding's verdict,
coverage, checked PCs or scope.

## Text presentation

`--format text` prints saved image identity, generator/model, configuration when
present, full source counts and the denominator including unresolved findings.
It prints coverage, mode, scope and per-verdict reason counts, metadata counts,
selection counts when requested, and a bounded set of finding examples.

Text detail clipping is explicit: at most twelve rows per count section, five
finding examples and five source limitations are displayed, with omitted counts
identified. Full source counts remain unchanged by clipping or verdict selection.
The JSON projection retains selected rows up to an explicitly requested detail
limit, with complete count maps.
Text values use ASCII JSON escaping so saved control characters cannot become
terminal control sequences. Generated-output size exhaustion remains an explicit
failure, without a partial report file.

There is no aggregate verdict, pass/fail status or whole-binary correctness
claim, including for an empty report or a report containing only agreement.
Imported analysis truth and current input bytes are not reverified. Unknown
model IDs remain exactly as admitted by the existing saved-report loader.

## Related saved-report presentation

The completed `diff` and `coverage` dispatchers also accept `--format json|text`
with JSON defaults. For example:

```text
python3 -I airs_cli.py diff --baseline BEFORE --current AFTER --format text
python3 -I airs_cli.py coverage --report FILE --format text
python3 -I airs_cli.py summary --report FILE --verdict unresolved --verdict inconsistency --format text
```

These formats present their existing saved-report results. They do not authorize
or perform a new audit of the referenced images. Existing input admission,
comparison/coverage semantics, protected output writes and output-size limits
remain in force.

Current source documentation includes reason selection, detail limits and verdict
ordering. The first summary projection, verdict selection and text-format
receipts remain historical evidence; the ten newest reason/limit/order methods passed on resume. No build or test was executed to reconcile this document.
