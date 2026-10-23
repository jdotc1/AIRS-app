# AIRS

A native macOS evidence-review workspace with a separately executable,
standard-library-only Python ARM64 Mach-O unwind analyzer. Selected binaries are
input data and are never loaded or executed by the analyzer.

## Development source and the published app

This tree is a **development source snapshot beyond the published
[AIRS 0.3.1/build 5 preview](https://github.com/jdotc1/AIRS-app/releases/tag/v0.3.1)**.
It does not replace that release, its tag or downloadable assets. No next release
version is assigned. SOURCE_SNAPSHOT.json identifies the private source revision,
published baseline, export scope and reused sanitation evidence.

The source now includes model `arm64-bounded-local-fde-v40`: bounded X29-relative
X stack access, signed X division, W RBIT, equivalent contiguous compact rules,
and local refusal for the two operand-free FDE row-state opcodes. These changes
retain explicit unsupported and unresolved boundaries; they are not general
memory analysis or broad DWARF-program support. See
[development scope and evidence limits](docs/DEVELOPMENT_STATUS.md).

The native app adopts Lumen's complete settings-window scaffold: a compact
native toolbar, one sidebar control, category history, coherent surfaces and
searchable Engine/Reports panes. The actual AIRS Settings window was visually
reviewed before a separate local developer installation. This is appearance
evidence, not complete interaction or release qualification.

Other development changes include settled project companion import/export and
re-export, historical-outcome presentation, and a bounded read-only project
catalog command. Historical observations and imported receipts do not establish
current permissions, issuer authenticity, trust, safety or a restored live queue.
The stronger C4 exchange retains its separate
[public protocol contract](docs/MACSCOPE_BOUND_CONTRACT.md).

## Build and verification

macOS 14 or newer, Apple silicon; Swift 6.1 or newer. Python source requires
3.11 or newer. Older-OS, minimum-toolchain, clean-Mac and Intel-host qualification
remain separate limits.

```
swift build --package-path native --configuration release --product AIRSApp
swift build --package-path native --configuration release --product airs-entitlements
python3 -I -B airs_cli.py --version
```

Lumen and EntitlementDiff are vendored. A developer bundle can be assembled with
`bash scripts/package-app.sh --release --external-python`. A standalone bundle
requires a prepared private Python runtime; see docs/PRIVATE_PYTHON.md. These are
operator instructions, not newly executed release qualification. Version constants
in the source and developer packaging are not a new release identity.

Accepted checks are reused for unchanged boundaries. New source preparation does
not repeat engine suites, corpora, dependency checks or signing. Test output roots
use portable temporary defaults; AIRS_TEST_OUTPUT_ROOT selects an explicit output root.
An explicit, fail-closed Settings-review mode uses isolated storage and preferences;
normal startup remains the default. CI instructions are not a distribution approval.

## Source scope and licensing

The export excludes private Git history, maintainer instructions, internal
handoffs, qualification/comparison receipts, local logs, screenshots, corpus
locations and compiled apps/runtimes. Owned parser/report regression fixtures and
public schemas/contracts remain included. SOURCE_FILES.txt inventories the payload;
SOURCE_EXPORT_SCOPE.json distinguishes changed inspection from evidence reuse.

AIRS and the bundled Lumen snapshot are licensed under the [MIT License](LICENSE).
Lumen's mixed-snapshot source identity and distribution authorization are recorded
in native/Vendor/Lumen/PROVENANCE.md. EntitlementDiff retains its MIT license;
Python's upstream licenses accompany the separately packaged runtime. See
[third-party notices](THIRD_PARTY_NOTICES.md).

Publication, optimized release integration, signing/notarization and release
acceptance are separate steps. This source snapshot claims none of them.
