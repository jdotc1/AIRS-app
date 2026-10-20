# Component review archive, version 1

B2 uses the existing `.airsreview` envelope. One `airs.component.review`
attachment binds two `airs.components` attachments (Previous and Current), the
explicit requested architecture, declaration observations and per-match outcomes.
The combined inventories retain the existing 128-component budget. Match IDs are
deterministic from inventory IDs, component IDs and relation; matching uses exact
UTF-8 path bytes. A location correspondence is not cryptographic identity.

Compared outcomes reference original `ComparisonReport.jsonData()` attachments
of kind `EntitlementDiff`, retaining that report schema. Schema-safe source names
are `component-<component UUID>`; the bound inventory supplies the exact relative
path. The assembler validates both component names, match IDs and requested slice.
Unavailable outcomes retain a reason and cannot carry a comparison attachment.
Dangling or duplicate result references reject. Unknown kinds remain uninterpreted.

Declaration observations retain component ID, category, relative source path,
requested architecture for loader metadata, explicit state and original bytes or
an extraction issue. Info comparisons use the documented allowlist; retained Info
bytes include other fields. Privacy compares the explicit conventional resource
manifest, with missing path distinct from unreadable/malformed. Loader bytes are a
bounded plist serialization of observed commands for the requested slice, not raw
Mach-O bytes. All three families retain typed values. There is no compliance,
trust, compatibility or effective-permissions verdict.

Only live selections retain process-local validated discovery capabilities.
Imported inventories and archives cannot authorize code-unit reads. Live reads
also compare current Info bytes with the captured Info observation before and
after extraction; a detected change requires rebuilding. Reads are sequential
observations, not an atomic snapshot of an entire app. Selected code is never
loaded or executed. Conventional app/XPC/appex/framework preflight is supported;
naked helpers remain unavailable for entitlement reads.

The native imported-review session retains the entire original archive for
re-export, preserving evidence bytes and unknown attachments. Reconstructing its
typed model does not establish trust or grant a live capability.
