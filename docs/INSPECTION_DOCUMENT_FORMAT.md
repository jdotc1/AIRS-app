# AIRS inspection document, version 1

Status: implementation handoff. The Swift implementation and tests have not been
compiled or run in the authoring environment. The macOS verification gate below
is required before this feature is accepted.

## Purpose

An inspection document holds one captured entitlement snapshot and a small amount
of descriptive metadata. It does not represent a comparison. It does not retain
the original binary, a selected filesystem URL, or a binary hash. An entitlement
value or captured Info.plist label may itself contain a path-looking string;
those values remain unchanged.

The capture timestamp records when the displayed snapshot was captured for this
document. It is not certification of an atomic read of an application bundle.
Imported timestamps, labels, producer versions and provenance are unverified
claims from the document's author.

The suggested extension is `.airsinspect`. Content is UTF-8 JSON. A file
extension alone never establishes its kind or validity.

## Schema

Every field below is required. No additional outer fields are accepted.

| Field | Version 1 representation |
| --- | --- |
| `kind` | Exact string `airs.inspection` |
| `schemaVersion` | Exact JSON integer token `1`; `1.0`, strings and booleans are rejected |
| `scope` | Exact string `mainExecutableRequestedArchitecture` |
| `signatureValidation` | Exact string `notPerformed` |
| `gatekeeperAssessment` | Exact string `notPerformed` |
| `capturedAtUnixSeconds` | Finite JSON number, UTC seconds since 1970; at least 2001-01-01 and before 10000-01-01 |
| `producerVersion` | At most 64 UTF-8 bytes; one to four numeric dot-separated components, optionally followed by a `-` or `+` suffix of ASCII letters, digits, dots, hyphens and plus signs; suffix begins with a letter or digit |
| `captureProvenance` | `nativeExtraction`, `savedSnapshot` or `syntheticExample` |
| `originalBinaryRetained` | Exact boolean `false` |
| `identity` | `null` or the exact three-field object described below |
| `snapshot` | One standalone snapshot, using the existing typed EntitlementDiff snapshot representation |

`identity`, when present, contains `bundleIdentifier`, `version` and `build`.
Each key is required and its value is a string or `null`. Strings are nonblank,
at most 256 UTF-8 bytes, and contain no ASCII C0 control character or DEL. Unicode
spelling, whitespace within nonblank values, slashes and backslashes are retained.
Unknown identity fields are rejected. These are captured Info.plist labels;
they do not authenticate an application or its signing identity.

The snapshot contains exactly `sourceName`, `signingIdentifier`, `architecture`,
`presence`, `origin` and `entitlements`. The existing parser's validation remains
authoritative, including source-name, identifier, architecture, absent-entitlement,
typed-value and duplicate-entry rules. Integer values remain decimal strings.
Dictionary entries remain arrays so Unicode spellings that Swift dictionaries
consider canonically equivalent remain distinguishable. Optional UI identity
metadata is carried outside this unchanged snapshot representation.

Creation derives provenance from the input snapshot: synthetic input becomes
`syntheticExample`; otherwise a saved baseline becomes `savedSnapshot`; otherwise
it becomes `nativeExtraction`. Import requires synthetic provenance and snapshot
origin to agree. Import always sets `snapshot.isSavedBaseline` to `true` and
restores the captured identity labels to `snapshot.identity`. It preserves the
recorded provenance field. Thus a reopened document may record an original
`nativeExtraction` while correctly presenting its current snapshot as saved,
unverified metadata.

## Validation and limits

The entire document passes through the existing bounded JSON parser before
Foundation decodes any descriptive fields. Duplicate object keys, including
escaped spellings of the same key, are rejected throughout the document.
Unknown outer fields, unknown identity fields, unsupported versions, inconsistent
snapshot presence and unsupported typed values are rejected.

The document shares the legacy import budgets:

- 8 MiB for the complete file, including whitespace.
- 96 JSON nesting levels.
- 100,000 JSON value nodes.
- 1 MiB of decoded UTF-8 per JSON string.

The wrapper consumes part of the same depth and node budgets. A snapshot that
alone reaches a limit may therefore be too large when placed inside a document.
Both the standalone snapshot encoder and document encoder validate their output
through the corresponding decoder. No encoder promises to persist an oversized
or unsupported in-memory snapshot.

The capture time is serialized as a JSON number and normalized at construction
to the precision carried by its UTC Unix-seconds representation. No date formatter
or locale participates in encoding. JSON output uses sorted object keys and a
trailing newline. Sorting is serialization consistency, not a signature or a
cryptographic identity scheme.

`read(at:)` accepts local regular files, reads at most the byte limit plus one,
and delegates validation to `decode`. Its caller owns security-scoped access,
off-main-thread scheduling, cancellation, selection of an export destination,
and protected-write rules.

## Why JSON instead of a binary-plist wrapper

Reusing the bounded JSON parser allows the entire wrapper and snapshot to share
one duplicate-key and resource-budget policy. The snapshot stays a typed JSON
object, rather than an opaque base64 payload. A binary-plist wrapper decoded
through Foundation alone would require an additional duplicate-key validation
policy. The new document therefore does not add that second parser contract.

## Public API

The AIRSEntitlements module adds:

- `InspectionDocument(snapshot:capturedAt:producerVersion:)`
- `InspectionDocumentCodec.encode(_:)`
- `InspectionDocumentCodec.decode(_:)`
- `InspectionDocumentCodec.read(at:)`
- `InspectionIdentity(bundleIdentifier:version:build:)`
- `InspectionCaptureProvenance`
- `InspectionDocumentError`

The vendored core adds `EntitlementSnapshotJSONCodec.encode(_:)`, `decode(_:)`
and `decodeEnvelope(_:snapshotKey:expectedKeys:schemaVersion:)`. The envelope
method validates the complete JSON and decodes a selected snapshot; callers
must still validate their own metadata. It is a reusable snapshot codec, not a
new comparison schema.

## Legacy compatibility

Legacy schema-1 `ComparisonReport` encoding is unchanged. `SavedReport.parse`
still requires its existing exact comparison field set and recomputes derived
comparison data from the captured pair. It does not accept inspection documents.
The new document decoder does not accept legacy comparison reports. Shared
snapshot, dictionary and value decoding was moved into one private helper;
the bounded JSON parser itself is unchanged.

An existing comparison can contribute one explicitly chosen snapshot to a new
inspection document. No automatic migration, duplicate self-comparison or
modification of the old report is performed.

## Required macOS verification

All tests below are **NOT RUN** in this handoff.

1. Add the inspection test file and minimal public API stubs to a Mac checkout.
   Run `swift test --package-path native --filter InspectionDocumentTests`.
   Resolve missing-symbol or syntax errors, then record behavioral failures
   caused by the unimplemented codec. A compiler error is not a behavioral red.
2. Apply the implementation and rerun that command. Confirm the exact numeric
   edge cases, including negative zero, the smallest subnormal real and the
   largest finite real, survive the platform's Foundation JSON encoder.
3. Run `swift test --package-path native` with the normal project toolchain.
   Report every failure, including unrelated failures. Do not replace an exact
   value assertion with a lossy equality check to obtain a green result.
4. Verify a manually created live inspection document reopens as saved metadata.
   Confirm old audit and entitlement-comparison files still open through their
   existing import paths after the separate UI integration.

The tests use owned, deterministic JSON fixtures and temporary document files.
They never load or run the inspected application.
