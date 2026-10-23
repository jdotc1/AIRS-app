# EntitlementLens bounded SuperBlob adaptation

- Repository: https://github.com/hideouts-io/EntitlementLens
- Pinned commit: `d7c6d58e08aa33ec950cd15bf852f277a44bef3c`
- License: MIT, copyright (c) 2026 hideouts-io; preserved verbatim in `LICENSE`.
- Adapted source: `Sources/EntitlementLens/Services/CodeSignatureParser.swift`
  and its subtraction-based range checks in
  `Sources/EntitlementLens/Services/MachOByteRange.swift` at that commit.
- AIRS adaptation: `native/Sources/AIRSCore/BoundedCodeSignatureParser.swift`.

The adaptation retains the bounded big-endian SuperBlob header/index walk,
entitlement slot constants, blob length/range checks and exact blob hashing.
It checks duplicate types and overlap across **every** indexed blob (including
non-entitlement records), rejects table/header aliases and null offsets, bounds
all arithmetic before addition, and preserves the complete XML/DER blob bytes.
Sorted ranges replace repeated pairwise overlap checks.

AIRS does not copy the upstream file-opening wrapper, architecture-label join to
Security-framework dictionaries, XML property-list decoding or DER dictionary
fallback. Its existing discovery capability supplies one no-follow descriptor
for exact FAT/thin metadata, signature reads and streaming source/slice digests.
A final capability-only revalidation checks that the path still names that file;
it does not reopen the path to obtain evidence bytes. Intel and unknown slices
remain inventoried but unexamined for signature structure.

Default hard ceilings are 512 MiB for the container hashing pass, 1 MiB total
header reads, 512 KiB for each signature, 4 MiB total retained signature bytes,
4,096 slots per signature, and 64 image slices. Raw entitlement copies are a
subset of the retained signatures and add at most another 4 MiB. Captures record
these limits and actual byte counts. Budget exhaustion is distinct from missing
or malformed metadata. Imported evidence reparses complete retained signature
regions and reconciles their slot ranges, bytes and hashes; the unavailable
original image's digests remain historical identities, not authenticated source
or signature trust claims.
