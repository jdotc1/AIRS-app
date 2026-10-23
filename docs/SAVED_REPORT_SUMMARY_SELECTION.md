# Saved summary detail selection

`validate_summary_verdicts(values)` validates a repeated verdict selection before
any report file I/O. It accepts a list or tuple containing agreement,
inconsistency and/or unresolved. It returns a deduplicated tuple in that fixed
order. None retains the default summary. Empty selections, bare strings and
unknown values raise `InputError` with code `invalid_summary_verdict`.

`select_summary_findings(summary, values=None, reason_codes=None)` accepts the complete output of
`summarize_report`. It returns detached data and filters only the `findings`
detail array. Every original source count, reason count, unresolved denominator,
identity, configuration, limit, issue and limitation remains intact. When an
explicit selection is present, `finding_selection` reports `requested`,
`selected_count`, `omitted_count` and `original_count`; these are row counts,
never an aggregate verdict. None returns the original shape without a selection
field. Input data is not mutated or aliased.

`validate_summary_reasons` reuses coverage's literal lowercase ASCII identifier
rules: 1 to 128 characters and at most 32 supplied codes. Reasons are sorted and
deduplicated. Details match any requested reason and must also match a requested
verdict, when both selectors are provided. Reason-only selection records an empty
`requested` verdict list and explicit `requested_reasons`.

The CLI validates selectors before file I/O, admits the saved report once,
selects details, optionally orders them, then applies an explicit detail limit.
Default operations are skipped to avoid redundant copies of an already detached
summary. JSON or text output still uses the protected writer.

Only use this projection on a complete, unselected summary. Selecting detail
rows does not authorize changing full-report counts or concluding a whole-image
pass when only agreement examples are displayed. No model scope, audit,
identity verification, file access or target execution is added by this helper.

The original three verdict-selection methods passed in the accepted second-wave
receipt. Do not rerun them on unchanged inputs. The two new methods in
`ReportSummaryReasonSelectionTests` and the newest composed CLI methods passed
in the focused resume qualification. Source review and test results retain
their distinct scopes; no GUI acceptance follows from these methods.
