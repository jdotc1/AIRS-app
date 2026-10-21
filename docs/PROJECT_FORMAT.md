# Inspection projects — schema 1

B4 separates editable review metadata from immutable original observations.
The normal root is Application Support/AIRS/InspectionProjects. The DEBUG-only
AIRS_PROJECT_REVIEW_ROOT override supports isolated local qualification.

Projects/<UUID>/manifest.json records schemaVersion, UUID, monotonic revision,
name, creation/update times, evidence references and SHA-256 digests, optional
pinned baseline, annotation IDs and append-only annotations, batch links and
revision history. Capture/check times, project-added times and annotation times
remain separate. Model/extractor labels are separate from app-version declarations;
missing labels remain explicitly unrecorded. No original app is retained.

Evidence/ uses the existing SnapshotLibrary receipt and exact-byte retention
format. Imported .airsreview bytes are retained unchanged. Known raw reports are
wrapped deterministically in a B0 archive without changing their original payload.
Duplicate identical imports within a project do not create a successor revision.
Notes and acknowledgments never modify observation bytes. Annotation corrections
append a note referencing the earlier note. A pin is project membership metadata,
not a trust verdict or authority to perform live checks.

Manifest commits require the expected parent revision and successor parent+1.
A root no-follow cooperative flock serializes mutations. New projects publish a
same-directory staged directory; successors use an atomic manifest replacement.
Interrupted publication preserves the prior manifest. Derived batch/project maps
are rebuilt from manifests, never written into settled batch rows. Batch links
record family, history UUID, selected row UUIDs and link time; they do not retry work.
Current native choices cover already loaded history and current retained checkpoints.

Defaults: 64 projects, 128 retained archives / 256 MiB total, 32 MiB per archive;
per project 128 evidence references, 128 notes of at most 8192 UTF-8 bytes,
128 batch links, 1024 history events and a 2 MiB manifest. Admission refuses when
full; no automatic eviction or history pruning. Unpin before removing baseline
membership. Removing membership leaves retained bytes. Explicit retained-copy
removal requires no project references and moves the copy to Trash. Removing a
project moves its metadata to Trash and leaves retained evidence available.
Corrupt or missing manifests stay visible for recovery; missing/corrupt evidence
cannot become a valid pinned baseline. Unreferenced evidence still occupies capacity.

Original archives and project metadata have separate export actions. Metadata
export contains references and notes only: it is not a self-contained project
backup or an implemented project interchange/import format. Project roots and
current-session import URLs are protected against report/export overwrites.

Cached validated bytes are bound to observed report and receipt file identities;
changed files require validation again. This is a cooperative local store, not an
adversarial-filesystem atomic snapshot or tamper-proof audit ledger. No analysis,
signature, distribution or slice semantics change in B4.

## C5 follow-up — 20 October 2026

The metadata-only UI export remains distinct from the new portable project
directory format. The native command now exports complete referenced evidence
and reconstructs a fresh local store while preserving project/evidence IDs,
baseline, notes and history. See PORTABLE_PROJECTS.md for limits, explicit
confirmation, seven focused passes and remaining native/second-machine gates.
