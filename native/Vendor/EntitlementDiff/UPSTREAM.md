# EntitlementDiff reusable modules

Donor commit: `58b450bd5bd0ad84bfaef4e5e636e9441fc123d5`.
AIRS base: `d872e8e11e2517efcbbae0d6fcb3c8a478a768e2`.

Core, Model, Security and CLIKit sources and LICENSE were initially copied unchanged from Git,
not from the historical integration ZIP. Package.swift is an AIRS-owned library-only
manifest retaining Swift 6 and macOS 14. No donor executable, scene, GUI commands,
file-open registration, executable target, tests or resources are included.

CLI checkpoint adds unchanged Sources/EntitlementDiffCLIKit/ComparisonCommand.swift
from the same pinned commit. AIRS owns its separate entry point and executable name;
the runner retains the donor argument, status, schema and exclusive-output policy.

See docs/ENTITLEMENTS_INTEGRATION.md in the AIRS repository for the exact manifest,
capability scope, donor receipts and fresh host evidence.

## AIRS inspection-document codec extension (handoff)

Local changes for standalone AIRS inspection documents are confined to
Sources/EntitlementDiffCore/SavedReport.swift. Snapshot, dictionary and typed-value
decoding was extracted into a private helper shared by the existing SavedReport
parser and the new public EntitlementSnapshotJSONCodec. The latter supports a
standalone snapshot and a bounded versioned envelope containing one snapshot.
The BoundedJSON parser, its budgets, and legacy comparison schema/encoding are
unchanged. No private engine dependency or AIRS-specific document schema was
added to the vendor module.

The AIRS-owned wrapper lives in native/Sources/AIRSEntitlements/InspectionDocument.swift;
its format is documented in docs/INSPECTION_DOCUMENT_FORMAT.md. Tests in
native/Tests/AIRSEntitlementsTests/InspectionDocumentTests.swift cover shared typed
values, strict malformed-input rejection, import budgets and legacy comparison
round trips. The source handoff was prepared on Linux without Swift; these tests
are NOT RUN. Record red/green and full native-suite evidence on macOS before
accepting or releasing this extension.

20 October 2026 native integration: ComparisonModel.useSavedBaseline now preserves
captured AppIdentity while marking the snapshot saved-only. It still clears live
URLs and pending read generations. AIRS capture/adoption tests exercise this
wrapper path. The 15 new document/library Mac tests passed; subsequent exact
identity-summary coverage passed separately. Existing source receipts are reused;
no blanket native-suite rerun is implied.

## AIRS evidence-envelope structural validator — 2026-10-20

SavedReport.swift adds public `EvidenceEnvelopeJSON.validate(_:)`, reusing the
existing private BoundedJSON parser for AIRS-owned chunked review envelopes up to
32 MiB. The parser's 96-level, 100,000-node and 1 MiB string budgets, duplicate-key
rejection, and all existing SavedReport/snapshot entry points and their 8 MiB
limits remain unchanged. Archive schema, chunk/base64 validation, digest binding
and evidence dispatch live in AIRSEntitlements, not the vendor module.

## B2 conventional code-unit extraction seam — 2026-10-20

SecurityEntitlementReader.swift factors its existing architecture-specific static
metadata extraction into public readCode(at:executableURL:architecture:sourceName:identity:).
The original app read still performs AppBundlePreflight and calls the same body.
AIRS owns nested-unit preflight and before/after identity checks in AIRSCore and
AIRSEntitlements. No signature validation, trust assessment, fallback or target
execution is introduced. The exact typed metadata decoder remains shared.
