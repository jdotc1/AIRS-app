# Small owned nonleaf workload — prepared, not run

Historical preparation instructions below remain in force for new/repeated runs.
A later explicit user grant authorized exactly one v36 pass, now completed and
recorded in qualification-v36.json and docs/NONLEAF_V36_RESULTS.md. The original
v35 expectations.json is preserved; a separate pre-run v36 overlay was used.
No additional run is authorized. No target was executed.

This packet is source and predicted expectations only. User authorization is
limited to preparing it. **Do not compile, link, disassemble, audit or execute it
under this preparation request.** No binary, report, identity digest or observed
result exists. expectations.json has execution_authorized=false and null observed
results/artifact identity. A later chat grant must explicitly authorize the new
bounded compiler/disassembly/audit pass before the plan below is used.

## Purpose and denominator

Use a richer but small owned workload to decide the next engine increment after
v35. One assembly-only ARM64 dylib is proposed, containing exactly eight functions:
seven nonleaf cases and one owned local sink. No O0/O2 duplicate is useful for
handwritten assembly. The existing two-library 16-function corpus and its accepted
16/0/0 receipt stay untouched and separate; this proposed denominator is eight.

This packet samples stable frames, six saved callee registers, mixed W/X stack
locals, unknown conditional paths and a known two-iteration call loop. Controls
separate a known metadata defect from unknown recovery, valid unsupported forms,
a reserved encoding and stored-pointer escape. Explicit compact records keep
rule semantics inspectable without relying on compiler-chosen CFI. This first
packet does not rank mixed-FDE handling, general CFI, indirect calls or runtime
function outputs. It is designed to identify complete-function blockers, not
maximize a score or estimate application coverage.

## Reuse and source layout

- AIRS fixtures/toolchain/canonical.S supplies the stable frame/direct-call pattern.
- Existing AIRS high-multiply.S and related fixtures supply explicit compact-record
  macros, owned sink structure and saved-register recovery controls.
- AIRS fixtures/toolchain/loops.S already adapts the owned MacScope A64Oracle
  control_flow.s branch/counter pattern. The MacScope file was inspected read-only
  for this preparation; no donor changes or checks were performed.
- AIRS X_STACK_SLOTS.md and accepted recovery/loop contracts supply the supported
  memory, call, unknown and budget boundaries. No new engine feature is required
  or introduced by this packet.

nonleaf.S expands setup to six instructions: allocate 80 bytes; three integer
pair stores; FP/LR pair store; establish FP at SP+64. Teardown is six instructions:
load FP/LR and the three integer pairs; deallocate 80 bytes; RET. Every instruction
is intended to occupy four bytes. The immediate MOVs fit one MOVZ instruction.
The local sink is private extern to request an internal direct call, while its
symbol/range must still be independently verified before an audit.

| Entry-SP offset | Stored value | Compact rule with 0x04000007 |
| --- | --- | --- |
| -8 / -16 | original X30 / X29 | FP+8 / FP |
| -24 / -32 | original X19 / X20 | First integer pair |
| -40 / -48 | original X21 / X22 | Second integer pair |
| -56 / -64 | original X23 / X24 | Third integer pair |
| -72 / -80 | local SP+8 / SP+0 | Not a saved-register rule |

## Predicted results, conditional on actual linked structure

| Case | Intended bytes | Source BL offsets | Predicted result |
| --- | ---: | --- | --- |
| pressure_branch | 116 | +76, +88 | Agreement, synchronous call sites; both possible paths recover all saved originals |
| call_loop | 64 | +28 | Agreement, synchronous call sites; two known iterations at the same original BL PC |
| wrong_rule | 56 | +28 | Inconsistency: compact rule intentionally omits pair recovery, live X19=6 |
| unknown_recovery | 56 | +28 | Unresolved unknown_recovery_value; synchronous call-site scope retained, no supported checked PCs |
| unsupported | 60 | +32 | Unresolved at SDIV +24; also inventory FP-relative X load +28 independently |
| invalid | 56 | +28 | Unresolved invalid_bitfield_encoding for 0x93000000 at +24 |
| pointer_escape | 64 | +36 | Unresolved stack_address_escapes_call: clearing X0 does not clear its stored pointer |
| sink | 8 | none | Agreement at leaf-body NOP offset +0 |

Conditional predicted totals: **3 agreement, 1 inconsistency, 4 unresolved, all
8 functions retained**, with five distinct supported checked PCs. The loop can
have more than one state observation at one BL PC. These are not measured counts.
A supported inconsistency is the intentional wrong-rule positive control, not a
newly discovered engine regression. An unresolved control is a required refusal,
not a failure to reach agreement. No target code is ever to be executed.

## Proposed future run, requiring separate explicit authorization

1. Select one fresh output directory under a new local development output parent and preserve
   an exclusive started marker containing the authorized scope, actual source
   revision and one-image/one-audit maximum. Existing outputs must never be
   overwritten or silently retried. No receipt-bypass option is permitted.
2. Reuse the Apple-tool discovery and fixed argument-array subprocess patterns
   already used in the accepted B6 compare/build drivers. Record the effective
   compiler and SDK while assembling just nonleaf.S and linking one ARM64 dylib,
   minimum macOS 14, with debug symbols and normal LC_FUNCTION_STARTS. Do not build
   helpers.c/canonical.S as extra inputs: their patterns are already incorporated,
   and adding them would change the denominator. No C compiler probe is needed.
3. Retain the object/library and one independent Apple llvm-objdump disassembly,
   symbol/boundary and compact-unwind observation. Verify the eight named ranges,
   exact sizes, direct internal sink targets, metadata and the BL offsets before
   starting the analyzer. Independently inspect every complete body, including
   instructions after the first unsupported word. The reserved word may be printed
   as data; preserve that observation without requiring a disassembler to call it
   a named instruction. Structural or compiler divergence stops this pass; do not
   revise expectations to fit the eventual analyzer result.
4. Run one isolated Python -I -B AIRS audit using the existing audit_path/Limits
   interface and serialize through the existing report codec. Use the proposed
   explicit limits in expectations.json; other fields keep accepted defaults.
   The CLI currently need not expose every Limits field, so reuse a fixed owned
   standard-library driver rather than invent CLI switches. No driver is run or
   granted authority by this document. Total proposed compiler/disassembly/audit
   budget is 120 seconds, one image, one audit, no retries.
5. Reconcile exact actual function/metadata identities and original BL offsets
   against expectations. Keep all eight cases and report verdict, scope, checked
   PCs, reasons, complete blockers, uncertainty, work counters and elapsed costs.
   Distinguish structural/precondition failure from changed semantic expectation.
   For wrong_rule, require the known X19 recovery witness, not only a verdict.
   Unexpected extra functions or missing metadata remain an explicit gate failure.
6. Preserve first analyzer-emitted image/slice identity as the run binding. Do not
   separately rehash the input or rerun accepted v35, historical corpus, native,
   release/signing or dependency checks. No baseline engine pass is needed: this
   is a new eight-function workload with source-derived expectations, not a new
   comparison on the already accepted 16-function corpus.

Before any broader engine work, classify observed blockers by complete-case value
and soundness cost. Current source inspection alone does not establish which
future family should be implemented. Engine changes, a second run, optimization
variants, MacScope consumer checks, GUI, release integration and distribution
remain separately scoped.
