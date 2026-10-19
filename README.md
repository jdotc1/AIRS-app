# AIRS 0.1.0

Distribution status: Developer ID signed preview; notarization is pending.
The app archive is held in a draft release until notarization is completed.

A native macOS workspace for bounded ARM64 Mach-O unwind diagnostics and
entitlement comparisons. Analysis reads selected files as data; it does not
load or execute the inspected applications.

## Requirements

The distributed app supports Apple silicon Macs running macOS 14 or newer.
It includes private Python 3.15.0; no separate Python installation is required.
The app is an initial preview. Clean-Mac and Intel-app qualification remain open.

## Evidence and limits

Keep coverage, verdict and scope separate. Unsupported instructions and
ambiguous states remain unresolved. Missing metadata alone is not a defect.
Read docs/ANALYSIS_CONTRACT.md for supported subsets and their boundaries.
MacScope integration is a future consumer contract, not an installed integration.

## Build from source

Use a macOS Swift toolchain supporting Swift 6.1 or newer. The Lumen and
EntitlementDiff dependencies are vendored; no developer-specific checkout path
is required. Run `swift build --package-path native --configuration release`.
For an external-Python developer app, run
`bash scripts/package-app.sh --release --external-python`.
A standalone package requires a prepared private runtime; see
`python3 scripts/prepare-private-python.py --help` for its preparation interface.

The Python engine remains independently executable:
`python3 -I -B airs_cli.py --help`.

## Included code

LumenTokens and LumenUI are included with the owner's distribution authorization;
see native/Vendor/Lumen/PROVENANCE.md. EntitlementDiff's MIT license is preserved.
Python's upstream license and third-party notices accompany the binary app.
No additional open-source license grant is made for AIRS or Lumen here.
