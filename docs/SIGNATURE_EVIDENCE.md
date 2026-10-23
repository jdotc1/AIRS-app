# Raw signature evidence

## User workflow

Choose **Inventory App Components**, select a local app, and use **Capture Signature Evidence** on a component with a live discovery capability. AIRS reads that component as data. Expand **Captured signature evidence** to inspect exact slice descriptors, capture states, signature/entitlement blob offsets and hashes, and a bounded raw-byte preview. **Export Complete Archive** retains the inventory and every captured evidence document regardless of display filters.

Reopen the archive through **Open Report**, explicitly select its `airs.signature-evidence` record, and inspect the historical evidence. A standalone evidence JSON document can also be opened or imported into an inspection project. Opening a saved record does not recreate a live file capability or reread the original app. The original incoming document bytes are preserved when wrapped for project retention/export.

## Meaning

This is structural byte evidence. It does not validate a cryptographic signature, identify a trusted issuer, evaluate Gatekeeper, establish effective permissions, decode a DER dictionary, compare a raw blob to a Security.framework dictionary, or change an unwind verdict. Existing entitlement comparison and scoped signature assessments retain their separate contracts.

The `airs.signature-evidence` schema-1 document contains capture time/producer and one `CodeSignatureEvidence`. The evidence records component UUID/relative path, container size/hash, actual read counts, configured limits, and exact slice records. Each slice retains raw CPU/subtype bits, offset/size/hash, header/load-command extent, state, and any bounded signature region. XML/DER slot records retain their complete bytes including the eight-byte magic/length header, magic/type, length, container-relative and slice-relative offsets, and SHA-256.

Imported container/slice hashes are recorded historical identities because original binary bytes are not retained. Imported signature and entitlement blob bytes are retained and reparsed; their hashes/ranges are reconciled against the retained SuperBlob. This does not authenticate the report's author or unavailable original.

| State | Meaning |
| --- | --- |
| `collected` | A bounded SuperBlob was parsed and XML and/or DER entitlement blobs were retained. |
| `signatureAbsent` | No `LC_CODE_SIGNATURE` command was observed for the examined slice. |
| `entitlementsAbsent` | A bounded signature SuperBlob was parsed with no XML/DER entitlement slots. |
| `unexamined` | The slice is outside little-endian ARM64/ARM64e structural capture. |
| `malformed` | Signature commands, extents or SuperBlob records are invalid/ambiguous. |
| `budgetExceeded` | Signature bytes or slot counts exceed the recorded limits. |

An unavailable or stale source capability, invalid overall image layout, failed read or exceeded global container/header budget throws and publishes no fresh document. Per-slice absence is never substituted for one of these failures.

## Bounds and identity

The existing strict Mach-O inventory reader admits FAT32/FAT64 and thin layouts using one descriptor-bound file capability. Subtypes and capability bits remain exact. ARM64 and ARM64e structure can be retained without granting additional instruction/unwind support; other CPU families remain unexamined.

Defaults: 512 MiB streamed container hashing, 64 slices, 1 MiB total header reads, 512 KiB per retained signature, 4 MiB aggregate retained signatures, and 4,096 indexed slots per signature. Entitlement bytes duplicate a subset of the retained signature bytes and add at most 4 MiB. A standalone document is limited to 16 MiB; the complete existing archive limit remains 32 MiB. Capture records configured limits and actual byte usage. Callers may only lower the core limits.

All indexed blobs participate in duplicate/range/overlap checks, including types AIRS does not interpret. Entitlement slot types/magic must agree in both directions. Offsets into a header/index, overlapping records, duplicate signature commands and contradictory FAT/thin identities cannot become collected evidence. Checked subtraction precedes range additions.

Container/slice hashes share one bounded streaming pass. The captured descriptor is checked before/after reading; a final capability-only revalidation checks that the discovery path still names the same source. These observations are not an atomic filesystem snapshot. Cancellation is checked during reads and before publication. Native publication additionally requires the original inventory UUID and audit/entitlement revisions, and waits for the capture task to settle during Quit.

## Reused source

`BoundedCodeSignatureParser.swift` adapts the SuperBlob/index/slot and checked-range algorithms from EntitlementLens at `d7c6d58e08aa33ec950cd15bf852f277a44bef3c`, MIT. `third_party/EntitlementLens/` retains the complete license and adaptation map. The upstream URL-opening wrapper, architecture-string dictionary join and XML/DER semantic decoder are excluded.
