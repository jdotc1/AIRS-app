# AIRS review archive, schema 1

A review archive is a UTF-8 JSON document, conventionally `.airsreview`, with
`kind: "airs.review"`, `schemaVersion: 1`, `attachments` and `components`.
It supplements existing `airs.inspection` v1, EntitlementDiff schema-1 comparison
and `airs.audit` schema-1 formats. None of those formats changes.

Each attachment has `id` (UUID), `kind`, `schemaVersion`, `mediaType`, lowercase
hex `sha256`, `byteCount`, and `chunks`. Chunks are ordered base64 strings
containing at most 524,288 decoded bytes each. Concatenating decoded chunks
reconstructs the original evidence bytes, including whitespace. The size and
SHA-256 bind those exact bytes, not a selected executable or a pathname.
An empty payload has no chunks. There is no filename-based relationship.

`components` currently contains manifest-local references with a UUID `id` and
an array of attachment UUIDs `evidenceIDs`. These are relationships, not a claim
that AIRS has inventoried components. B1 supplies actual inventory payloads later.
IDs must be unique within each collection; references must resolve to attachments
and may not repeat within one component.

The complete archive is limited to 32 MiB, 256 attachments, 128 component
references and 256 evidence IDs per component. The structural parser retains its
96-level, 100,000-node and 1 MiB decoded-string ceilings; chunking keeps individual
base64 strings below that ceiling. Attachment chunks are bounded before base64
allocation. Each recognized embedded format retains its own decoder limits,
including the 8 MiB inspection/comparison ceiling. Export also counts base64
expansion toward the complete-file limit. These are import/work budgets, not a
claim that process RSS is capped at 32 MiB.

After length and digest validation, AIRS parses JSON attachments at schema 1
with kinds `airs.inspection`, `EntitlementDiff` or `airs.audit` using their
existing decoders. A recognized malformed payload rejects the archive. Other
kinds, versions or media types remain opaque and explicitly **uninterpreted**.
They cannot be opened as supported reports or satisfy analysis/policy. Unknown
archive versions reject with a version error. Unknown manifest fields and
repeated JSON keys reject, including imported `validation` or trust flags.
Validation is computed locally; a digest does not authenticate an author's
claims, signature, permission, origin or completeness.

Opening an archive stages its records for explicit selection without replacing
audit or entitlement state. Selecting a supported attachment opens its original
bytes in the existing report review route. Cancellation, quit, or changed
workspace revisions prevent late publication. The source archive URL remains
local session context and does not become an embedded binary path or identity.
No selected app is executed and no opaque blob is interpreted as executable code.

This B0 foundation provides encoding/decoding and native open/review dispatch.
It does not add component discovery, assessments, policy, project persistence or
a general archive-authoring interface. Original binaries are not automatically
collected. Existing imported files do not migrate or rewrite themselves.
