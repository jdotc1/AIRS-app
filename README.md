# AIRS 0.2.0

Shipping source preparation for A/B-RC1, build 3. This snapshot is not a signed,
notarized or published release. Existing public binaries remain 0.1.1 until a
separately authorized release.

AIRS is a native macOS evidence-review workspace with a separately executable,
standard-library-only Python ARM64 Mach-O unwind analyzer. Selected binaries are
input data and are never loaded or executed by the analyzer.

The A/B feature set includes entitlement inspection and retained baselines,
review archives, component inventory/comparison, explicitly scoped assessments,
inspection projects and batch-history associations, owned-build policy review,
and bounded coverage presentation with the CLZ-v32 engine extension.

Unsupported instructions, ambiguous state and missing evidence remain visible.
Entitlements are declarations; a historical result does not establish current
permissions, trust, safety or distribution acceptance. Review the analysis and
format contracts in docs/ before interpreting findings.

## Build and verification

macOS 14 or newer, Apple silicon; Swift 6.1 or newer. Python source requires
3.11 or newer. Local accepted qualification used Swift 6.4.2 and Python 3.15.0;
minimum-toolchain and clean-Mac qualification remain separate gates.

```
swift build --package-path native --configuration release --product AIRSApp
swift build --package-path native --configuration release --product airs-entitlements
python3 -I -B airs_cli.py --version
```

Lumen and EntitlementDiff are vendored. A developer bundle can be assembled with
`bash scripts/package-app.sh --release --external-python`. A standalone bundle
requires the prepared private Python runtime; see docs/PRIVATE_PYTHON.md and
`python3 scripts/prepare-private-python.py --help`. Packaging/signing commands are
operator actions, not actions performed by this snapshot preparation.

For a new source identity requiring verification, the portable entry point is
`python3 -I -B scripts/verify-python.py --fail-on-skip --receipt build/python.json`.
Native checks are described by `scripts/verify-macos.sh`. Reuse valid accepted
receipts for unchanged inputs; these commands are not a request to replay them.
The supplied CI workflow is source qualification, not distribution approval.

## Included code and evidence

LumenTokens/LumenUI retain the owner's distribution authorization in
native/Vendor/Lumen/PROVENANCE.md. EntitlementDiff's MIT license is preserved.
No additional open-source license grant is made for AIRS or Lumen here.
Python's upstream license accompanies the binary runtime, which is not included
in this source snapshot.

This export excludes private history, maintainer instructions, handoffs, local
receipts/logs, corpus artifact locations, screenshots, compiled app/runtime and
historical internal status documents. Tests and owned parser/data fixtures are
included. See RELEASE_NOTES.md, SOURCE_SNAPSHOT.json and SOURCE_FILES.txt.
