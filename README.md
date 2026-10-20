# AIRS 0.1.1

**Read-only ARM64 binary analysis and entitlement review for macOS security research.**

AIRS is a native macOS workspace for examining ARM64 Mach-O unwind behavior and
comparing application entitlements on Apple silicon. It brings bounded unwind
diagnostics and entitlement differences into a local review workflow, reading
selected files as data without loading or executing the inspected applications.

Use it to inspect supported unwind patterns and review changes in declared
entitlements. Findings remain tied to supported analysis coverage, with
ambiguous and unsupported cases reported as unresolved.

Download the app from the [public releases](https://github.com/jdotc1/AIRS-app/releases).

Distribution status: Developer ID signed and Apple-notarized preview.
The exported app carries a validated staple and passed Gatekeeper assessment.

## Changes in 0.1.1

- Empty entitlement results explain the current search/category state and offer
  an explicit recovery action while preserving sorting and comparison data.
- Unwind review identifies a selected function hidden by filters and offers
  Show Selected Function or Report Overview without replacing its evidence.
- No-match function guidance keeps the overview row available. Reason codes and
  evidence appear before the longer function identity details.
- Native function-list selection uses view-local state with guarded workspace
  synchronization, avoiding publication during the native list update callback.

Analysis coverage, report schemas and supported conclusions are unchanged.

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
