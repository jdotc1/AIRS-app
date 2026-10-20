# Component inventory document, schema 1

`airs.components` is a declaration-only evidence payload, carried in the existing
`airs.review` schema-1 archive. Its JSON envelope has exactly `kind`,
`schemaVersion` (1) and `inventory`. Direct JSON import is also recognized; the
normal native export is a complete `.airsreview` archive.

The inventory contains `id`, `capturedAt`, `scope` and `components`. Dates use
Foundation Codable's finite numeric seconds since 2001-01-01 UTC; this is distinct
from inspection documents' explicitly named Unix-second field. Scope contains
`searchedLocations` (locations actually attempted), `completion`, `exclusions`
and `issues`. Completion is `completeWithinScope`, `partial`, `cancelled` or
`failed`. Neither completion nor the absence of findings implies whole-app
coverage or compatibility. Missing optional code directories can be covered as
absent within this explicit scope; symlinks and special/hardlinked duplicate
entries remain exclusions. A stopped traversal does not list later locations
as searched. Failed root selection produces an error without an empty-success
inventory.

Each component contains UUID `id`, optional `parentID`, exact `relativePath`,
`kind`, optional `declaredBundleID`/`declaredVersion`, `architectures`,
`minimumOSByArchitecture`, and `readIssues`. Paths identify observed executable
locations relative to the selected app root. A principal image represents its
containing app/XPC/extension/framework, and contained images link to the nearest
observed parent. IDs are local to this capture; paths/labels are not authenticated
identity. No selected source URL, bookmark, original binary, signature result or
live read authority is serialized. Optional nil record fields are omitted.

Bundle labels are associated only with a bounded safe CFBundleExecutable at its
exact conventional path. An image at another location cannot borrow labels via
a matching basename. Versioned frameworks use their physical version's resource
plist; symbolic aliases are not followed. Naked images and missing/bad plists
keep labels unavailable. Unknown CPU/subtype values are retained as hexadecimal
strings. ARM64e metadata is not supported unwind coverage. Minimum OS values come
from one unambiguous macOS build/minimum command, not an execution test;
contradictory platform commands make the image metadata unavailable.

Budgets are 8 MiB per document, 128 component records, 64 architecture/minimum
entries and 64 read issues per record, 256 exclusions/scope issues and 16 searched
locations. Paths/scope/issues are at most 4,096 UTF-8 bytes; labels and architecture
strings at most 256. IDs, parents, cycles and exact UTF-8 path uniqueness are
validated. The existing structural parser also rejects duplicate keys and retains
its depth/node/string budgets. Future document versions and unknown fields
reject. These bounds do not claim a process RSS ceiling.

Native discovery retains its 4,096-entry, depth-12, 128-candidate traversal limits.
The 1 MiB header budget is shared across discovery and metadata reads, with
per-plist 64 KiB bounds. Thin and fat32/fat64 headers are read without loading
or executing the target. Descriptor-bound file identity is revalidated through
the read. Header/table overlap, out-of-file ranges, excessive alignment,
duplicate/overlapping slices, inner/outer CPU disagreement, invalid command sizes,
truncation and exhausted budgets remain visible unavailable results. Imported
records never authorize a filesystem read or recreate BundleImageProvenance.

The archive attachment kind is `airs.components`, media type `application/json`,
schema 1. SHA-256 and byte length bind its exact document bytes, not an executable.
The archive's component references point to the inventory attachment. Native
filters affect display only; Export Complete Archive preserves all enclosing
archive bytes, including other evidence when reopening a multi-record archive.
