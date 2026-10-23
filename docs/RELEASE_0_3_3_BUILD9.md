# AIRS 0.3.3 Preview — build 9

This maintenance release improves native Settings sizing and removes the captured
comparison-sheet AttributeGraph sizing cycle. The engine remains
`arm64-bounded-cfi-control-v41`; report semantics and export formats are unchanged.

## Changes

- Settings has a 560-point content minimum and 640-point preferred height, with
  more space between interpreter controls. Existing preferences are retained.
- Comparison summary tiles are measured eagerly. Findings use pages of up to
  50 eager rows with Previous/Next navigation, avoiding lazy layout feedback
  during native sheet sizing. Every finding remains reachable. Complete JSON
  and exported reports retain the full comparison.
- A debug-only fixture opener is available only through the existing explicitly
  isolated review configuration; normal launches and release builds omit it.

## Accepted evidence

The changed AIRSApp debug and optimized targets built successfully. Three focused
native tests passed: presentation/minimum sizing/dismissal, complete once-only
page coverage and page clamping after smaller filter results. The actual isolated
SwiftUI app-scene check recorded zero AttributeGraph cycle breakpoint hits across
unchanged-only presentation, filter changes, a synthetic 51-row comparison,
forward/backward pagination and dismissal. The failing baseline and rejected
candidates were retained locally. These checks qualify a bounded workflow, not
all reports, window sizes or macOS versions.

Previously accepted v41 owned-image qualification used three functions and ten
machine words: two agreements, zero inconsistencies, one unresolved refusal and
five modeled PC observations. It included the fixed advance forms, balanced
remember/restore state, an underflow refusal and an independent compact neighbor.
The selected image was never executed. The earlier browser-downloaded build 7
completed native import, analysis, export and baseline comparison under App
Translocation. Build 9 reuses those unchanged engine/runtime results; its own
browser-download acceptance was not repeated.

Build 9 passed new-bundle signing validation and Apple notarization, and its ticket
was stapled. Its installed startup was observed with no cycle, crash or hang in
that interval. System locale, DetachedSignatures SQLite, LaunchServices and
BaseBoard diagnostics were present; this is not a clean-log claim. Settings and
stores were preserved during the previously authorized local installation.
Publishing this release does not modify that installed app or its data.

The accepted signed build 9 candidate is reused unchanged for this release.
The public native source files exactly retain the accepted implementation via
Git object identities. Unchanged public files, vendor/runtime qualification,
semantic tests, comparison checks, signing and notarization were reused; no fresh
CI pass or repeated unchanged-suite result is claimed.

## Remaining scope

This remains an Apple silicon preview requiring macOS 14 or newer. No disposable
clean machine was available. Fresh-profile, minimum-macOS, Intel-app and offline
qualification remain incomplete. The app reads selected images as data and does
not establish general unwind correctness, asynchronous/all-PC validity, signature
trust or effective permissions. See the analysis contract for supported boundaries.
