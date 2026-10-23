# Readable saved-report comparison

`airs.diff_text.render_diff_text` renders an existing `compare_reports` result
without I/O, binary analysis or changes to comparison semantics. The caller owns
CLI selection and output delivery; existing JSON defaults remain outside this
module's scope.

The deterministic output retains every comparison identity/compatibility field
and every full summary count. Detail retains each row's existing status, join
basis, IDs, names, verdicts, scopes and notes. Unique-symbol joins remain review
candidates. Ambiguous comparison rows are not promoted to changed/unchanged;
unmatched added/removed rows do not establish regressions or fixes.

Saved strings and keys, including nested identity fields, use ASCII JSON escaping.
Control characters, terminal escapes, non-ASCII and bidirectional characters
therefore cannot be emitted as active terminal controls. Only renderer-owned
newlines provide layout.

Defaults show up to 100 change rows, eight notes per shown row and 32 limitations.
Explicit omission counts accompany each clipped category; full summary counts
remain visible. Output accumulation stops with `InputError` code
`generated_report_size_limit` before returning oversized output. The existing
`MAX_REPORT_BYTES` cap always applies; callers may request a smaller byte cap.
ASCII output character count equals encoded byte count. The renderer returns no
partial result on a size error.

Four new synthetic methods in `tests/test_diff_text.py` cover counts and status
boundaries, string/key escaping, clipping, and exact/insufficient byte caps. They
are authored and unrun; no build, test, hash, corpus pass or binary analysis was
performed in this lane. CLI wiring and first validation belong to the parent.

Resume qualification: the supplied focused text-rendering methods subsequently
passed in the composed development receipts. The original authoring-only note
above describes the earlier checkpoint. No unchanged method was repeated.
