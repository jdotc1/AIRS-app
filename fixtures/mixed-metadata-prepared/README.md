First bounded qualification is now complete; see docs/MIXED_METADATA_OWNED_QUALIFICATION.md
from the repository root and fixtures/mixed-metadata-prepared/qualification-v38.json.
The proposal/preparation below is historical and grants no repeat run.

# Prepared mixed metadata witness

Source-only packet: no generator, compiler, decoder or auditor has been run.
Use existing tests/parser_helpers.py to prepare four new synthetic Mach-O data
inputs only after a specifically authorized run. Never execute the target.

Reuse: AIRS canonical frame/owned call helpers and existing split-metadata parser
test; the owned sink shape is already retained in the AIRS nonleaf fixture using
MacScope-derived control-flow patterns. No MacScope source changes or new dependency.

Each case has exactly two independently delimited functions and eight words:
frame 0x100001000–0x100001018; sink 0x100001018–0x100001020. Two calls are
at preferred VM 0x100001008 and 0x10000100c. Offsets passed to regular_unwind
are image-relative; function offsets passed to build_macho are text-relative.
These are source-predicted identities/ranges, not a measured generated image.

| Case | Expected current frame outcome | Sink | Purpose |
| --- | --- | --- | --- |
| single-range | agreement, synchronous_call_sites, two original BL PCs | agreement | Owned valid control |
| split-equal | unresolved, multiple_metadata_ranges, no checked PCs | agreement | Equal encodings do not establish per-PC admission |
| split-different | unresolved, multiple_metadata_ranges, no checked PCs | agreement | Rule transition cannot be flattened to first rule |
| uncovered-prefix | unresolved, multiple_metadata_ranges, unavailable coverage, unknown mode | agreement | Later rule does not cover the prefix |

Expected denominator remains two in every case: control two agreements;
other cases one agreement/one unresolved. No frame inconsistency may be inferred
from deliberately changed metadata until a separately reviewed per-PC contract
exists. Preserve all ranges; do not turn a gap or rule transition into agreement.

The next bounded product increment may expose range intersections in existing
refusal evidence while retaining the same model, reason and empty checked PCs.
That is diagnostic groundwork, not PC-sensitive recovery support. Full per-range
analysis and per-FDE isolation remain distinct future contracts. This packet
introduces neither. Any new generated-input pass needs its own bounded authority;
no rerun of retained inputs, compilation or release action is implied.
