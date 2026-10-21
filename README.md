# AIRS

A native macOS evidence-review workspace with a separately executable,
standard-library-only Python ARM64 Mach-O unwind analyzer. Selected binaries are
input data and are never loaded or executed by the analyzer.

## Preview 0.3.0/build 4

This preview includes bounded missing-principal bundle declaration observation,
shared component entitlement-read availability, portable inspection projects,
exact project-manifest preservation with staged-package preflight, and Python
CLZ-v32 report import-admission parity. Missing executable declarations do not
create executable identity or entitlement authority. No asset-catalog or
Interface Builder inspection is added.

SOURCE_SNAPSHOT.json identifies the corresponding frozen source revision.
Distribution qualification and remaining limits are recorded with the release.

The AIRS side also includes stronger C4 review exchange: selected
finding bound-request export, exact original report/configuration binding,
acknowledgment import and retained receipt review. The stronger MacScope consumer
and paired workflow remain pending. The existing manual-v1 handoff is separate
and remains available. New native menu/panel interaction is not yet qualified.
See [the public protocol contract](docs/MACSCOPE_BOUND_CONTRACT.md).

The existing A/B feature set includes entitlement inspection and retained
baselines, review archives, component inventory/comparison, scoped assessments,
inspection projects and batch-history associations, owned-build policy review,
and bounded coverage presentation with the CLZ-v32 engine.

Unsupported instructions, ambiguous state and missing evidence remain visible.
Entitlements are declarations; historical observations and imported receipts do
not establish current permissions, issuer authenticity, trust or safety.

## Build and verification

macOS 14 or newer, Apple silicon; Swift 6.1 or newer. Python source requires
3.11 or newer. Minimum-toolchain, clean-Mac and older-OS qualification remain
separate limits. No Intel-host support is claimed.

```
swift build --package-path native --configuration release --product AIRSApp
swift build --package-path native --configuration release --product airs-entitlements
python3 -I -B airs_cli.py --version
```

Lumen and EntitlementDiff are vendored. A developer bundle can be assembled with
`bash scripts/package-app.sh --release --external-python`. A standalone bundle
requires the prepared private Python runtime; see docs/PRIVATE_PYTHON.md.
These commands are operator instructions, not newly executed release qualification.

Accepted A/B/release checks and focused C4 receipts are reused for unchanged
boundaries. C4's original local implementation has 12 focused contract passes and
one workspace pass; compilation is not native-interaction or consumer acceptance.
Tests use portable temporary output roots; AIRS_TEST_OUTPUT_ROOT can select an
explicit local test-artifact parent. Unchanged checks are not replayed merely
because files were exported. Source CI is not distribution approval; this
publication intentionally skips hosted CI under the verification-reuse policy.

## Source scope and remaining gates

LumenTokens/LumenUI retain the owner's distribution authorization in
native/Vendor/Lumen/PROVENANCE.md. EntitlementDiff's MIT license is preserved.
No additional open-source license grant is made for AIRS or Lumen here.
Python's upstream license accompanies the binary runtime, excluded from source.

The export excludes private history, maintainer instructions, internal handoffs,
local receipt logs, corpus locations, screenshots and compiled apps/runtimes.
Tests and owned parser/data fixtures are included. SOURCE_FILES.txt inventories
the export; SOURCE_EXPORT_SCOPE.json separates reused files from changed-content
sanitation. Pattern inspection is bounded, not proof that all confidential text
can be detected. See RELEASE_NOTES.md for the source-update scope.

The stronger consumer, actual selection readback/receipt production, native AIRS
export/import interaction and paired exchange remain qualification gates. Broader operating-system, second-machine reconstruction and capacity qualification
remain separate from this bounded preview.
