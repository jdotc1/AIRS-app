# AIRS 0.3.1 Preview — build 5

This update brings the public app to the completed private v35 checkpoint.
The engine baseline is 2b4b958, with signing fix b9988e8 and dSYM fix
74d5a47 from private main. In-progress v36 is excluded.

- X-only RBIT and UDIV, with exact model admission in Python and native reports.
- Bounded SP-relative, unsigned scaled aligned 8-byte X stack loads/stores.
  Full known slots, allocation bounds, overlap invalidation, frame lifetime and
  pointer-escape checks remain required. Unsupported forms remain unresolved.
- Shared frame-effect classification preserves the existing X29/SP guard.
- Architecture-specific signing metadata coverage and dSYM picker attachment routing.
- All previously released 0.3.0 component, project and exchange features remain.

Report schema remains 1. The engine model is arm64-bounded-x-stack-v35.
Accepted focused semantic/native import and independent review receipts are
reused. The retained owned two-library v35 observation was 16 functions,
16 agreement, zero inconsistency and zero unresolved; this is a bounded prior
measurement, not a new corpus run or general support claim.

The standalone app is Developer ID signed, Apple notarized and stapled.
New-container signature verification, ticket validation and local macOS
distribution assessment passed. Release qualification is recorded separately. No unchanged suite, corpus,
source/runtime provenance hash or dependency qualification is repeated.
Minimum-OS, Intel-host, clean-Mac and broader workload qualification remain open.
The stronger external MacScope consumer/paired workflow remains separate.
