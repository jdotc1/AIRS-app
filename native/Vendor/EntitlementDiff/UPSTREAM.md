# EntitlementDiff reusable modules

Donor commit: `58b450bd5bd0ad84bfaef4e5e636e9441fc123d5`.
AIRS base: `d872e8e11e2517efcbbae0d6fcb3c8a478a768e2`.

Core, Model, Security and CLIKit sources and LICENSE are copied unchanged from Git,
not from the historical integration ZIP. Package.swift is an AIRS-owned library-only
manifest retaining Swift 6 and macOS 14. No donor executable, scene, GUI commands,
file-open registration, executable target, tests or resources are included.

CLI checkpoint adds unchanged Sources/EntitlementDiffCLIKit/ComparisonCommand.swift
from the same pinned commit. AIRS owns its separate entry point and executable name;
the runner retains the donor argument, status, schema and exclusive-output policy.

See docs/ENTITLEMENTS_INTEGRATION.md in the AIRS repository for the exact manifest,
capability scope, donor receipts and fresh host evidence.
