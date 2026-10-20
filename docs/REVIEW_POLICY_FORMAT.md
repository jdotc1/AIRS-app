# Owned-build review policy — schema 1

B5 evaluates explicit expectations over recorded evidence. It supplies no aggregate
safety score, automatic remediation or claim of current trust. The evaluator is
ReviewPolicy.evaluate; GUI and CLI share it and PolicyResult.data().

## Policy and outcomes

schemas/review-policy-v1.schema.json describes airs.review-policy schema 1:
kind, schemaVersion, reviewModel, nonempty rules and acknowledgements. Unknown
checks/fields, empty rules and unsupported scopes are rejected. Input is bounded
to 2 MiB, 128 unique rules and 256 acknowledgments. Policy digests use sorted-key
canonical JSON. The public context and result types have explicit initializers.

The recognized reviewModel is airs.component.review.schema1.policy1. It names
this interpretation of the schema-1 component review, not an extractor version.
A different/unknown model requires review and makes the outcome incomplete.
The existing inventory format does not record a producer/extractor model; no
producer-model equivalence is inferred from app versions or schema versions.

Each rule explicitly names a componentRelativePath and check:

- requiredArchitectures requires architecture arm64 or x86_64 at that exact
  current component location, matching the review's requested slice. Incomplete
  inventory, read issues or unavailable/different slices produce missing evidence.
  This first subset evaluates one requested slice per review, not a universal scan.
- acknowledgedEntitlementChanges requires a performed, exact-location typed
  comparison for that component/slice. Every changed key needs an exact binding.
  Missing result objects are incomplete. Absent versus present-empty entitlement
  representation changes remain violations and cannot be waived in schema 1.
- signatureValidity uses componentRelativePath @app-root, architecture omitted,
  and a required exact scopeDescription, matching B3's whole-app assessment.
  Per-component/per-slice signature claims are not provided. A completed failed
  assessment is a violation; unavailable/cancelled/notPerformed is missing evidence.
- symbolMatches requires component/slice scope, but the current component-review
  format has no qualified symbol/source evidence. It therefore remains incomplete.
  Component correspondence or matching names cannot substitute for symbol evidence.

Overall status is incomplete whenever required evidence is missing, even when
known violations also exist; otherwise failed if violations exist, otherwise
passed. Both lists are preserved in deterministic rule/key order. Exit statuses
are 0 passed, 1 failed, 2 incomplete or input/output failure. PolicyResult includes
evaluationID, explicit mode, policyDigest, status, violations and missingEvidence.
A passed historicalRecord evaluates recorded expectations only.

## Exact acknowledgments and provenance

An acknowledgment binds reviewDigest, reportDigest, componentRelativePath,
architecture, keyUTF8 and typed beforeValue/afterValue. keyUTF8 is base64 of exact
UTF-8 bytes; canonical-equivalent Unicode spellings remain distinct. Values are
base64 canonical typed EntitlementValue JSON, reusing EntitlementDiff's encoding;
omitted before/after fields mean absent values. Boolean and integer cannot match.
The authoring helper ReviewPolicy.acknowledgements(for:) produces candidate exact
bindings for an explicit caller decision; evaluation never invokes it or edits
observations. B4 freeform acknowledgments cannot satisfy these rules.

reviewDigest is SHA-256 over a length-unambiguous JSON array of validated inventory
payloads, requested slice, declaration observations and ordered entitlement
outcomes. reportDigest covers the complete canonical schema-1 comparison. Saved
provenance is normalized before comparison encoding, so live/archive reopening
does not change identity through notices. Random archive attachment UUIDs are
excluded from this identity. Component matching is reconstructed before both
evaluation and acknowledgment authoring; caller-supplied matching is not authority.
These are identities of the recorded review, not hashes of an original app binary.

PolicyEvaluationContext carries id, expectedContentIdentities, explicit mode,
reviewDigest and session-only reviewOrigin. AssessmentAvailability and
AvailableAssessment are reused from B3 and are not Codable. In liveArtifact mode,
both reviewOrigin and each required assessment must be currentRun(context.id).
Any imported record is assigned importedHistory, regardless of encoded claims.

A signature rule needs two caller-supplied expectations bound by the context's
expected review digest: scopeKey -> sha256:<whole-app-content-digest> and
scopeKey+:document -> sha256:<subject-document-digest>. Construct scopeKey using
ReviewPolicy.scopeKey(componentRelativePath:architecture:scopeDescription:), which
uses exact UTF-8/base64 fields and a whole-app marker. Both digests, exact scope,
kind and provenance must match one unique assessment. Missing, different-artifact,
ambiguous or wrong-evaluation evidence cannot pass. Expected digests are explicit
inputs; the policy evaluator does not discover or freshly verify them.

## Request, CLI and GUI

schemas/review-policy-request-v1.schema.json defines the saved-evidence request:
kind airs.review-policy-request, schemaVersion 1, evaluationID, mode,
reviewArchive, policy, expectedReviewDigest, expectedContentIdentities, assessments.
Paths resolve relative to the request's folder; absolute local paths are also
accepted. assessments lists at most 16 raw airs.assessments JSON documents (not
archives); each is bounded to 4 MiB. Request input is bounded to 512 KiB. The review
is a B2 .airsreview archive, admitted through existing bounded archive validation.

Run the existing packaged CLI:

```sh
airs-entitlements review --request incomplete-request.json --output new-result.json
```

Standard output is JSON, diagnostics standard error. --output exclusively creates
a new file and protects every request/policy/report/assessment input and aliases.
Existing comparison and batch exit meanings are unchanged. This command reads
saved evidence only: it performs no live app, signature, distribution or symbol
checks and executes no target. Explicit liveArtifact mode is accepted but remains
incomplete for imported review evidence. Fresh-mode provenance is supported by
the shared API for callers holding current evaluation capabilities; neither this
CLI nor this initial GUI creates those capabilities from saved files.

File → Review Owned Build Policy opens the same request. The view shows explicit
mode and requires Evaluate Recorded Evidence. It preserves known violations and
missing reasons and exports the same result JSON through AIRS's existing protected
write/Quit owner. It adds no competing app scene or implicit evidence acquisition.

fixtures/policy-owned contains synthetic owned records with an expected change,
an unacknowledged change, an unavailable x86_64 slice and a missing signature
assessment. Its three request/policy variants demonstrate passed/failed/incomplete.
scripts/verify-owned-policy-example.sh takes an already-built absolute CLI path
and a new output directory, verifies exits 0/1/2 and stdout/file parity. Reuse an
existing receipt instead of rerunning this example unchanged.
