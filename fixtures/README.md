# Fixture corpus

## Synthetic byte fixtures

`python3 fixtures/generate.py` regenerates ten deterministic Mach-O data files
and a manifest with SHA-256 digests and stated expected mixed-case outcomes.
The generator does not call the engine to decide those expectations.

These files are deliberately small parser/model examples. They are not signed,
runnable applications and must not be used as Apple runtime fixtures. No input
binary is executed by the analyzer or example-generation scripts.

| Fixture | Purpose |
| --- | --- |
| `mixed-regular.macho` | Nine functions: three scoped agreements, two supported inconsistencies, four unresolved |
| `mixed-compressed.macho` | Same instructions/rules through common and local compressed encodings |
| `before.macho`, `after.macho` | Three stable named functions; two synthetic metadata changes for comparison |
| `arm64e.macho` | Metadata remains readable; semantic checks remain unresolved |
| `universal32.macho`, `universal64.macho` | Ordinary arm64 selected even when arm64e is listed first |
| `no-unwind.macho` | Missing metadata produces unresolved findings, not a defect claim |
| `symbol-boundaries.macho` | Weaker symbol fallback is visible and declines semantic checking |
| `metadata-only.macho` | Metadata entries do not invent function boundaries |

The DWARF example contains a reference and a terminator-only `__eh_frame` section.
That section is intentionally not a valid FDE example. It verifies that presence
or an offset alone does not become a DWARF validity claim.

Parser unit tests use a separately implemented helper in `tests/parser_helpers.py`.
The root generator and that helper provide two independent ways to construct
the documented layouts. Neither is a substitute for independent LLVM output.

## Owned Apple-toolchain source

`toolchain/canonical.S` supplies simple frame and leaf assembly with CFI;
`toolchain/helpers.c` supplies a direct-call target and a compiler-dependent
function shape. They are original, bounded sources intended for macOS builds:

```bash
bash scripts/build-owned-fixtures-macos.sh --output-dir build/owned-toolchain
```

The recipe builds ARM64 dylibs at O0/O2, creates dSYMs, records tool versions and
UUIDs, and produces optional LLVM dumps and audit reports. It never launches the
dylibs. These source files and the recipe have **not** been compiled with an
Apple toolchain in this environment. Review actual emitted bytes/rules before
turning their results into expected semantic outcomes.

## Example reports

```bash
python3 scripts/generate-examples.py
```

Outputs in `examples/` are current engine results on the synthetic corpus.
They are ready-to-open UI examples, not independent compiler/runtime ground truth.
