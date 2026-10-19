# AIRS 0.1.1 Preview

A focused usability update for the native macOS workspace.

## Changes

- Entitlement searches and empty categories now explain why no keys are visible
  and offer Clear Search, Show All Changes or Show All Keys as appropriate.
  Sorting and complete comparison data remain intact.
- Matching entitlement snapshots offer Show All Keys; snapshots containing no
  keys receive completed-comparison wording without a misleading recovery action.
- Unwind review identifies a selected function hidden by search or verdict filters.
  Show Selected Function restores its row; Report Overview retains filter context.
- Empty function results no longer cover the overview row. Reason codes and
  evidence precede the longer function identity block.
- Function-list selection no longer publishes workspace changes directly from
  the native list update callback.

## Compatibility and validation

Version 0.1.1 (2), Apple silicon, macOS 14 or newer, with private Python 3.15.0.
Analysis model v31, report schemas, extraction and export semantics are unchanged.
Selected files are read as data and never executed.

Three focused selection tests and a native minimum-layout check with four states
passed. Native packaged-app interactions confirmed both workflows; the final
selection-binding repair completed checked transitions without publication
warnings. Unchanged engine, runtime, model and export evidence was reused.

This remains a preview. Clean-Mac, older-macOS and Intel-app qualification are
not established. Existing system window-sharing geometry and host-service
messages remain documented; this release does not claim a clean runtime log.
No general ARM64 correctness, effective-permission or security verdict is implied.

## Distribution

Developer ID signed and Apple-notarized. The exported app passed strict signature
validation, staple validation and Gatekeeper assessment (Notarized Developer ID).
Apple accepted submission 7A389300-70C3-4CEB-ACB3-F6935D32F129 on October 19, 2026.
The signed release app also completed saved-report selection recovery and synthetic
entitlement-search recovery checks. No target app was executed or reanalyzed.
