# AIRS 0.1.0 — initial preview

Distribution status: Developer ID signed preview; notarization is pending.
The app archive is held in a draft release until notarization is completed.

Native macOS review of bounded ARM64 unwind evidence and application entitlement
comparisons. Includes audit history, saved-report review, explicit-pair entitlement
batches and a command-line entitlement comparison tool. The native workspace uses
Lumen and includes the latest Compare Entitlements layout improvements.

The app includes Python 3.15.0 and requires an Apple silicon Mac with macOS 14 or
newer. The inspected targets are read as data and never executed. Unsupported
analysis remains unresolved; findings apply only to the supported checked scope.
This is not a general ARM64 correctness guarantee or an automated remediation tool.

Lumen's two required libraries are included as a portable, sanitized source
snapshot. The source release omits developer instructions, local evidence and
private repository history. Python and EntitlementDiff license notices are retained.

This preview has not been qualified on a clean Mac or as an Intel app. Existing
AppKit geometry diagnostics remain under investigation. No MacScope consumer or
automatic patching capability is claimed.
