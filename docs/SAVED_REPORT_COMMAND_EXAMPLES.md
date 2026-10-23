# Saved-report command examples

Run these commands from the AIRS checkout with Python 3.11 or newer. Replace
`report.audit.json`, `before.audit.json` and `after.audit.json` with existing
saved audit reports. Each command reads saved JSON; it does not open, execute
or re-audit the original Mach-O image, recompute provenance hashes, or establish
that the original input bytes still match the saved identity.

## Summarize one saved report

JSON is the default format:

```sh
python3 -I airs_cli.py summary --report report.audit.json
```

Print the terminal-safe text presentation:

```sh
python3 -I airs_cli.py summary --report report.audit.json --format text
```

Select unresolved and inconsistency detail rows by repeating `--verdict`:

```sh
python3 -I airs_cli.py summary --report report.audit.json --verdict unresolved --verdict inconsistency --format text
```

Save the same selected summary as JSON using an explicit destination:

```sh
python3 -I airs_cli.py summary --report report.audit.json --verdict unresolved --verdict inconsistency --format json --output review-summary.json
```

Select detail rows containing any literal reason code, optionally combined
with a verdict filter:

```sh
python3 -I airs_cli.py summary --report report.audit.json --reason unsupported_instruction --verdict unresolved --format text
```

Repeat `--reason` for alternatives. Reason alternatives use OR; reason and
verdict selections combine with AND. Full source counts remain unchanged, and
`finding_selection.requested_reasons` records the requested literal identifiers.
The three reason-selection helper/CLI regression methods passed in the
focused resume qualification.

Accepted verdict codes are `agreement`, `inconsistency` and `unresolved`.
Selection affects finding detail rows only. Full-source counts, reason counts,
metadata and the original function denominator remain unchanged, including
unresolved findings. Selection metadata reports selected, omitted and original
counts, including when no finding matches. Text clips example/detail rows with
explicit omission counts; JSON retains the selected rows and complete count maps.
Full evidence remains in the original report, located by the saved finding ID.

## Inventory unresolved reasons

Print a text inventory from one report:

```sh
python3 -I airs_cli.py coverage --report report.audit.json --format text
```

Combine saved reports by repeating `--report`:

```sh
python3 -I airs_cli.py coverage --report before.audit.json --report after.audit.json --format text
```

Select final reason rows by repeating `--reason`:

```sh
python3 -I airs_cli.py coverage --report report.audit.json --reason unknown_recovery_value --reason unsupported_instruction --format text
```

Reason codes are literal lowercase ASCII identifiers, not text searches. Use
codes shown in the saved report or an unselected inventory; the example codes
need not occur in a particular input. At most 32 supplied reason codes are
accepted. Reason selection does not remove functions from the full counts or
alter duplicate/conflict handling. A selected code with no matching reason row
does not imply that its underlying behavior was checked or supported.

For machine-readable output, choose JSON and an output file:

```sh
python3 -I airs_cli.py coverage --report report.audit.json --reason unknown_recovery_value --format json --output selected-coverage.json
```

## Compare two saved reports

Print the existing conservative saved-report comparison as text:

```sh
python3 -I airs_cli.py diff --baseline before.audit.json --current after.audit.json --format text
```

Save a text comparison:

```sh
python3 -I airs_cli.py diff --baseline before.audit.json --current after.audit.json --format text --output comparison.txt
```

Comparison retains its existing identity, matching and ambiguity rules. A
presentation format does not strengthen a match, resolve unknowns or establish
that a behavior changed in the underlying binaries.

## Interpret and retain the output

Agreement applies only to the recorded checked PCs and scope; it is not a
whole-binary pass. Coverage, verdict and scope remain separate. Unknown model
labels retain their saved identity under the existing loader and acquire no
new semantic validation from these commands. An empty selection, empty report
or agreement-only report creates no aggregate correctness claim.

All three commands default to JSON and accept `--format text` and `--output`.
Without `--output`, they print to standard output. With `--output`, the shared
atomic writer protects each saved source report from overwrite and writes only
a completed result. Use that option when retaining output so the command's
source-file protection applies. Successful output-file writes print a small
JSON receipt naming the destination and report kind. Size-limit failures remain
explicit rather than producing a partial report file.

These are implemented command examples documented from source. No command,
test, build, audit or hash was executed to author this page.

The source-only summary `--limit N` option (0 to 200000) caps finding detail
rows after selection and preserves the full source counts. `--limit 0` retains
counts and context without finding detail rows. Explicit `finding_limit` metadata
discloses retained and omitted detail. The focused detail-limit helper/CLI methods passed on resume.

Use `--sort verdict` to stably group inconsistencies first, then unresolved
findings, then agreements. Within each group the saved relative order remains.
Ordering occurs after selection and before `--limit`; for example:

```sh
python3 -I airs_cli.py summary --report report.audit.json --sort verdict --limit 20 --format text
```

The default `--sort source` retains saved order. Explicit verdict ordering adds
`finding_order: "verdict"`; it changes presentation only and creates no new
finding or severity assessment. Ordering and its CLI/text composition are
source-reviewed, and their four focused test methods passed on resume.
