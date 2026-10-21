# AIRS bound review request and consumer acknowledgment

Public development protocol, 20 October 2026. The AIRS producer and acknowledgment
admission are implemented in this source snapshot. The stronger receiving
consumer and paired native qualification remain pending. This is distinct from
the existing manual-v1 handoff and does not advertise a new app release.

## Decisions

1. Use an opt-in bound-review request with a distinct kind/version. Never label
   optional v1 fields as stronger acceptance: the existing importer can ignore
   additions. Keep Export Handoff JSON and its current receiver unchanged.
2. Bind the exact original audit bytes, then select the finding and configuration
   from those bytes. Do not reconstruct or relabel a historical report.
3. Require exact container and selected-slice identity for this stronger profile.
   The existing v1 selected-slice navigation profile remains separate. A matching
   slice in a different fat wrapper cannot satisfy the stronger profile.
4. An acknowledgment records a consumer decision and, separately, whether
   navigation actually completed. Parsing or opening a confirmation dialog is
   insufficient to report success.
5. Recovery semantics remain source-reported. Unknown analysis-model labels are
   permitted as bounded opaque provenance in this navigation-only profile; they
   never imply consumer support for that recovery model.

## Transport and resource profile

Reuse the existing AIRS InspectionArchive attachment machinery and bounded JSON
parser. The transport is an `airs.review`, schemaVersion 1 archive, containing
exactly two attachments and no components: one bound request and one original
`airs.audit`, schema 1 report. Attachment IDs are distinct UUIDs. Existing archive
SHA-256/byteCount rules apply to both exact payloads. The archive's encoded size
is at most 32 MiB, including base64 expansion; the request is at most 1 MiB.
A report that does not fit this complete-file budget declines explicitly; do not
truncate evidence or split it silently. Ordinary v1 transport remains available
only as a separately selected weaker workflow.

The request uses kind `airs.macscope_bound_request`, schema_version integer 1,
and media type application/json. This new kind is deliberately distinct from
`airs.macscope_handoff`. The report attachment uses kind `airs.audit`, schema 1,
and media type application/json. No additional attachment, executable image,
external URI, path traversal, archive extraction or automatic sibling-file lookup
is part of this profile. The user opens the image separately in the consumer.
A legacy archive viewer may retain an uninterpreted request; that is not import
acceptance. The bound importer must explicitly recognize this request kind.

All JSON layers reject duplicate object keys, invalid UTF-8, non-finite numbers,
and parser-budget violations before interpretation. Protocol objects reject
unknown keys; future additions need a new version. Original report objects retain
the audit schema's additive-field rules. Reuse the existing receiver's narrower
field/array bounds for the selected finding (1 MiB projected handoff, 256-byte
source/model labels, 4096-byte reasons/messages, 4096-entry arrays, and its
existing limitations bounds). Freeze those bounds in implementation against the
pinned importer rather than silently relaxing them. The archive parser's existing
depth/node/string limits also apply. A valid audit outside these bounds returns
`profile_limit`, not partial acceptance.

## Request fields and exact-byte identity

The request object has precisely these required fields:

| Field | Required value / meaning |
| --- | --- |
| report_kind, schema_version | airs.macscope_bound_request, integer 1 (boolean is invalid) |
| request_id | New UUID for this user-initiated request; not a trust credential |
| profile | exact_artifact_source_report_navigation_v1 |
| source_report | Object: attachment_id UUID, sha256 lowercase 64 hex digits, byte_count nonnegative integer |
| finding_id | Exact ID of one and only one finding in the bound report |
| configuration | One of the two objects defined below |
| projection | Complete existing make_handoff result, retaining its existing v1 triplet |

The source_report descriptor must equal the selected audit attachment descriptor.
Its SHA-256 is over the exact original report bytes, including whitespace and
line endings. No canonical JSON, newline normalization, BOM removal, or
encode/decode round trip substitutes for those bytes. Request identity is SHA-256
plus byte count of its exact attachment payload, not the outer archive bytes;
there is no self-digest field. Repacking identical attachments therefore does
not change request identity. The acknowledgment carries this request identity.

At initial admission, validate exact attachment bytes using the existing digest
boundary. Reuse a valid digest-bound local receipt where its unchanged-input
witness is valid; never trust a serialized `verified` flag. Import into another
process requires its own trustworthy admission evidence or an explicitly trusted
local receipt mechanism. No cross-process receipt trust mechanism is assumed.
Producer export may reuse an accepted exact-byte identity only when that receipt
actually covers these source bytes. Image digest receipts are not report digest
receipts. Missing report identity must not be fabricated from the image SHA or a
reserialized report. Preserve the original report; first sealing of a new request
is distinct from permission to repeat checks on unchanged evidence.

## Configuration and finding binding

Configuration is transitive through the report digest; it does not need a second,
cross-language canonicalization algorithm. Its exact shapes are:

- If analysis_config is absent: `{ "state": "not_recorded" }`.
- If present: `{ "state": "recorded", "value": <entire analysis_config object> }`.

A present null, empty substitute, or synthesized defaults cannot stand in for an
absent configuration. The value must satisfy the audit configuration validator
and equal the entire value extracted from the validated bound report. For the
current limits map, values are integers, never booleans or floats. Preserve all
recorded keys; unsupported future configuration types decline as
`unsupported_configuration`. Object key order is irrelevant, arrays are ordered,
strings compare decoded Unicode scalars without normalization, and numeric types
must satisfy their schema before equality. Missing and null are distinct.
`not_recorded` is an explicit provenance limitation, not evidence of default
limits and not proof of configuration reproducibility.

Validate the source as airs.audit schema 1 before selecting the finding. Require
exactly one matching ID; duplicates decline. The projection must equal the result
of the existing make_handoff projection from that report/finding: image fields,
selection, finding evidence/limitations, source generator and requirements. Use
schema-aware structural equality with the preceding missing/null/type rules;
no lossy string or numeric coercion. Existing VM strings must validate as hex;
require the producer's exact strings in the projection, then use parsed integers
for range arithmetic. The consumer may implement this small projection locally;
it must not execute the AIRS engine or import private shared code at runtime.
The nested v1 object alone cannot establish binding without these outer checks.

## Consumer admission and application

Process these stages in order, stopping at the first failure:

1. Bounded regular-file snapshot, archive/parser/attachment identity validation.
2. Request kind, version, profile, field bounds and source attachment resolution.
3. Audit validation, unique finding selection, configuration and full projection
   equality. Unsupported audit schema/configuration is an explicit decline.
4. Verify the actual open image's container SHA, selected-slice SHA, architecture,
   raw CPU subtype, slice offset and size, plus UUID equality when source UUID is
   present. Both digests must come from the consumer's verified admission state
   for that image snapshot. Missing container evidence returns
   `identity_unavailable`; do not infer it from slice equality or a filename.
5. Reuse preferred-unslid-VM/__TEXT-base arithmetic and require the entire
   half-open range in one file-backed executable segment. No runtime slide,
   recovery execution, binary loading or code patching is implied.
6. Display source generator/model, configuration state, selected evidence,
   limitations, and the distinction between identity verification and
   source-reported recovery semantics. User chooses Navigate or Cancel.
7. Immediately before navigation, revalidate focused image/session identity and
   its admission witness. If changed, decline as stale. Apply the start address
   through the existing selection API; read back selected image and address.
   Only matching readback produces `navigated`. API invocation alone does not.

The stronger profile deliberately adds whole-container verification; unchanged
v1 checks are reusable components, not proof that this additional gate exists.
No supported-model allowlist is introduced for this static navigation profile.
A future consumer that interprets recovery semantics needs a separate explicit
model-capability contract and qualification.

## Consumer acknowledgment

A consumer creates one terminal receipt in memory for each import attempt. Export
is an explicit local user action to a new file, outside immutable app resources;
no automatic upload, callback, deep link or source overwrite. Failed export is
reported to the user; navigation may have completed without a saved receipt.
A saved acknowledgment is UTF-8 JSON, at most 1 MiB, with kind
`airs.macscope_bound_acknowledgment`, schema_version integer 1. Required fields:

| Field | Meaning |
| --- | --- |
| acknowledgment_id | New UUID for this terminal outcome |
| request | Exact request_id, sha256 and byte_count if stage 3 succeeded; otherwise null |
| untrusted_request_id | Parsed UUID solely for diagnostic correlation, otherwise null |
| source_report | Validated source descriptor after stage 3; otherwise null |
| finding_id | Bound selected ID after stage 3; otherwise null |
| consumer | bundle_id, version, build; source_revision and build_provenance_state (`declared` or `unavailable`) |
| profile | Recognized requested profile, otherwise null |
| completed_at | UTC RFC3339 timestamp; advisory, not identity or replay authority |
| outcome | navigated, cancelled, rejected, or error |
| code | Stable terminal code below |
| admission | not_validated, source_bound, or destination_verified |
| destination | null, or verified image/slice fields and session-local image ID |
| navigation | null, or requested_start, selected_start and selected_image_id |
| semantics | Literal source_reported_not_consumer_verified |
| diagnostic | Bounded plain text, maximum 4096 UTF-8 bytes; no raw report dump |

`request` becomes trusted correlation only after source/configuration/projection
validation succeeds; earlier parsed IDs never masquerade as bound correlation.
`destination` is populated only after stage 5 succeeds. `navigation` is populated
only for navigated and must have equal requested/selected preferred-VM addresses
and the same verified destination session ID. For navigated, admission must be
destination_verified and request/source/finding/destination must all be present.
Cancelled requires destination_verified, code user_cancelled and null navigation.
Rejection/error always have null navigation; stale rejection resets destination
to null and admission to source_bound because prior destination admission is no
longer current. No generic accepted outcome blurs admission with applied action.

Stable codes: `navigation_completed`, `user_cancelled`; rejection codes
`malformed_transport`, `attachment_identity_mismatch`, `unsupported_contract`,
`profile_limit`, `invalid_source_report`, `unsupported_configuration`,
`finding_not_unique`, `configuration_mismatch`, `projection_mismatch`,
`identity_unavailable`, `image_identity_mismatch`, `address_mapping_mismatch`,
`stale_destination`; operational error codes `read_failed`, `navigation_failed`.
Use the stage order above for precedence; within stage 3, report validation,
unique finding, configuration support/equality, then projection equality.
Unreadable bytes are read_failed; parsable but invalid bytes are a rejection.
Navigation failure/readback mismatch is an error, never navigation_completed.
If consumer serialization/storage fails, show the failure rather than fabricating
a saved acknowledgment. Timestamps and declared source revisions are not signed
attestations. The receipt demonstrates what its local issuer recorded, not
cryptographic authenticity, remote trust, or recovery-semantics correctness.

AIRS imports acknowledgments as evidence: bounded parser, strict version/shape,
exact stored request bytes identity and source descriptor/finding correlation,
then outcome invariants. An unmatched receipt stays unassociated; no filename or
request UUID alone joins it to a finding. Identical receipt IDs with identical
bytes are idempotent; conflicting bytes for one ID decline. Multiple attempts
may coexist and are not silently replaced by the latest timestamp. Reimporting a
request requires a new explicit navigation decision; no automatic replay.

## AIRS compatibility profile and evidence limits

The complete archive cap is 32 MiB, including base64 expansion. Request and
acknowledgment payloads are at most 1 MiB. The current configuration shape is
exactly an object containing limits, with nonnegative UInt64 values. Additive
source-report fields remain in the original attachment. Projection serialization
supports strings, booleans, nulls, arrays/objects and nonnegative UInt64 integers;
unsupported numeric generator/evidence extensions decline without coercion.

Receipt destination keys are image_id (session-local UUID), uuid, architecture,
cpu_subtype, container_sha256, slice_sha256, slice_offset, slice_size and
preferred_base. display_name is not a receipt destination key. Consumer bundle,
version and build strings must be nonempty and bounded to 256 UTF-8 bytes. A
declared source_revision is lowercase 40-hex; unavailable provenance uses null.
No source declaration is promoted to signed binary attestation.

See native/Sources/AIRSEntitlements/BoundReviewRequest.swift and
BoundReviewAcknowledgment.swift for the exact executable validation profile.
InspectionArchive, CoverageJSONIdentity and existing file witnesses are reused.
The producer has focused synthetic protocol/workspace evidence; its accepted
checks do not establish native panel interaction or actual consumer behavior.
The receiver must use verified whole-container/slice admission, final focus
revalidation and actual selection readback before emitting navigation_completed.
A future paired producer → consumer → exported receipt → AIRS import check is
still required. No semantic recovery endorsement, target execution or automatic
callback/upload is introduced.
