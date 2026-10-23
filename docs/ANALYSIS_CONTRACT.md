Current isolated model: `arm64-bounded-equivalent-compact-v39` admits fully
covering contiguous ranges with exactly equal frame/frameless compact encodings
through the existing auditor. Original metadata remains unchanged; changed rules,
gaps, overlaps, excluded modes and unknown recovery remain conservative. Sixteen
new Python methods, sixteen affected methods and three native admission methods
pass; the real native app debug target built. See EQUIVALENT_COMPACT.md and
EQUIVALENT_COMPACT_RESULTS.md. Accepted v38 workloads were not rerun, and release
integration remains separate. Historical checkpoints below retain their scope.

Current isolated model: `arm64-bounded-w-rbit-v38` adds exact scalar W RBIT,
reusing the X reversal transfer and existing zero-extending W write. Raw stack
sources still decline, symbolic values stay unknown, NZCV is unchanged and body
FP writes remain refused. Twelve new Python methods, three new native admission
methods and 23 affected existing methods pass in composed receipts. The real
native debug app target built; no prepared library was compiled or analyzed.
See RBIT_W.md and RBIT_W_RESULTS.md. Historical checkpoints below retain their
original scope; the release lane is unchanged.

# Analysis contract

Current isolated model: arm64-bounded-sdiv-v37 adds scalar X signed division with
concrete signed64 truncation toward zero, explicit zero/overflow behavior and
unchanged provenance/unknown/frame scope. Eighteen new Python methods, three new
native methods and twelve affected selectors pass. See SDIV_X.md and
SDIV_X_RESULTS.md. The retained complete nonleaf body gains typed call-site
agreement; no new whole-image/workload result or release action is claimed.

Previous isolated development model: arm64-bounded-fp-x-stack-v36 adds bounded
unsigned X29-relative X STR/LDR using known allocated-frame authority and the
existing slot/provenance/frame helpers. Eighteen new Python methods, three new
native methods and six affected checks pass; real native debug products built.
See FP_X_STACK.md, FP_X_STACK_RESULTS.md and CURRENT_ENGINE_MATRIX.md. The last
whole-image receipt remains v35; the prepared nonleaf-v35 workload remains unrun.

Current engine navigation: CURRENT_ENGINE_MATRIX.md identifies the isolated v37
subset, conservative boundaries, accepted receipts and separate release gates.
Frame-effect maintenance now shares one Instruction.changes_fp classification
across legacy and CFG body admission, preserving the prior v35 policy/model.
Five new and three affected methods pass; see FRAME_EFFECT_RESULTS.md. No native
or whole-image check was repeated for this source-only maintenance.

Isolated development checkpoint (21 October 2026): bounded SP-relative X stack
slots are implemented under `arm64-bounded-x-stack-v35`. Exact unsigned scaled
STR/LDR, known whole-slot reads, mixed-width invalidation, pointer escape/lifetime
and frame guards are qualified with 23 new Python methods, three new native
methods and three affected identity checks in composed receipts. The real native
debug products built; independent review and its corrected test typo are recorded
in X_STACK_SLOTS_RESULTS.md. See X_STACK_SLOTS.md for the bounded contract.
The subsequently authorized two-library comparison measured 16 agreement,
0 inconsistency, 0 unresolved with the same 16-function denominator, five
cumulative gains and no observed regressions. See V35_WHOLE_IMAGE_COMPARISON.md.
Release integration and GUI qualification are not claimed.

Previous isolated development checkpoint (21 October 2026): X-only UDIV is implemented
under model `arm64-bounded-udiv-v34`, following the accepted v33 RBIT change.
Sixteen new Python methods and five affected selectors pass in composed receipts;
independent semantic review found no actionable defect. Exact Python/native model
registration is qualified: the real native debug target built and all three new
admission tests passed after competing compilations cleared. This is not release
integration or a new aggregate result. See UDIV.md and UDIV_RESULTS.md. Subsequent older checkpoints
retain their original scope.

Previous isolated development model `arm64-bounded-rbit-v33` adds X-only scalar
RBIT with exact fixed-bit admission, concrete 64-bit reversal, conservative
unknowns, stack-provenance refusal and unchanged NZCV/recovery scope. Python and
native admission register its exact identity. See RBIT_X.md and RBIT_X_RESULTS.md.
This branch is separate from the release lane; no memory/CFI/loop/asynchronous
scope expands.

Previous model `arm64-bounded-clz-v32` adds scalar CLZ W/X only, with exact fixed-bit
admission, concrete width-masked leading-zero count, conservative unknown values,
raw stack-provenance rejection and unchanged flags/recovery scope. See CLZ.md and
CLZ_RESULTS.md. No memory, loop, CFI or asynchronous scope expands. Python report import
now registers the exact v32 model in the existing supported-finding admission
checks, matching native registration. Unknown model labels retain generic
wire-format handling; import acceptance is not semantic verification. See
V32_IMPORT_ADMISSION_RESULTS.md.

Previous model `arm64-bounded-sequential-loops-v31` admits at most two disjoint,
address-ordered natural loops. It retains the existing per-path state, shared
budget, all explored exits, unknown precedence and checked-PC recovery scope.
See `SEQUENTIAL_LOOPS.md` and `SEQUENTIAL_LOOPS_RESULTS.md`. Decoded loop count
is structural evidence, not an execution or termination claim.

Previous model `arm64-bounded-cfa-register-v30` adds only
`DW_CFA_def_cfa_register` (opcode `0x0d`) to the bounded FDE evaluator. It
switches an already-defined CFA base between SP and x29 while preserving its
unsigned bounded offset. Missing prior CFA, other registers, malformed operands,
unknown recovery, and any other unsupported CFI still decline. See
`CFA_REGISTER.md` and `CFA_REGISTER_RESULTS.md`. The previous
`arm64-bounded-loop-calls-v29` adds direct calls inside the v28
single-natural-loop subset when the existing framed-call target and ABI summary
apply. It checks recovery at original BL PCs; exact recurrence retains full
modeled state and whether a call occurred. See `LOOP_CALLS.md` and
`LOOP_CALLS_RESULTS.md`. Historical model sections below remain unchanged.

Previous model `arm64-bounded-loops-v28` added one natural loop with a conditional
backedge, adapting owned MacScope dominance/predecessor-closure code and scalar
loop witnesses. Complete path-local state recurrence closes safety exploration;
changing states are explored to exit or an unresolved budget. Calls inside the
loop in v28, setup/teardown participation and unsupported cycle shapes decline. No
termination or arithmetic-output claim is added. Contract/results:
`docs/BOUNDED_LOOPS.md`, `docs/BOUNDED_LOOPS_RESULTS.md`. Current app:
`dist/AIRS.app`; previous v27: `dist/high-multiply-v27/AIRS.app`. Earlier blocks
retain historical meanings.


Current model `arm64-bounded-high-multiply-v27` adds canonical SMULH/UMULH,
reusing owned MacScope decode/intrinsic operand handling and adding concrete
signed/unsigned high64 evaluation. Ra=31 is the bounded subset;noncanonical
spellings remain unresolved without an ISA-invalid claim. Unknown/provenance,
NZCV and recovery boundaries remain intact. Contract/results:
`docs/HIGH_MULTIPLY.md`, `docs/HIGH_MULTIPLY_RESULTS.md`. Current app:
`dist/AIRS.app`;previous v26:`dist/widening-multiply-v26/AIRS.app`. Earlier
sections retain historical meanings.

Current model `arm64-bounded-widening-multiply-v26` adds SMADDL/SMSUBL/
UMADDL/UMSUBL and SMULL/SMNEGL/UMULL/UMNEGL aliases,adapting owned MacScope
widening and accumulate algorithms. Factors project to signed/unsigned32;
accumulator/result remain64. Raw stack provenance is rejected before projection,
even in leaves. High-half multiplies remain unsupported. Contract/results:
`docs/WIDENING_MULTIPLY.md`, `docs/WIDENING_MULTIPLY_RESULTS.md`. Current app:
`dist/AIRS.app`;previous v25:`dist/multiply-v25/AIRS.app`. Earlier sections
retain historical meanings.

Current model `arm64-bounded-multiply-v25` adds bounded W/X MADD/MSUB and
MUL/MNEG aliases using adapted owned MacScope decoding and accumulate algorithms.
Exact controls,modular width,all-source unknown/provenance checks and unchanged
NZCV/recovery scope are explicit. Widening/high-half multiplies remain unsupported.
Contract/results:`docs/MULTIPLY.md`, `docs/MULTIPLY_RESULTS.md`. Current app:
`dist/AIRS.app`;previous v24:`dist/variable-shift-v24/AIRS.app`. Earlier sections
retain historical meanings.

Current model `arm64-bounded-variable-shift-v24` adds bounded W/X LSLV,
LSRV, ASRV and RORV, including register-count aliases. MacScope modulo-count,
signed/unsigned shift and rotate algorithms were adapted with exact controls,
conservative unknowns and provenance guards. Contract/results:
`docs/VARIABLE_SHIFT.md`, `docs/VARIABLE_SHIFT_RESULTS.md`. Current app:
`dist/AIRS.app`; previous v23:`dist/extract-v23/AIRS.app`. Earlier sections
retain historical meanings.

Current model `arm64-bounded-extract-v23` adds bounded W/X EXTR and immediate
ROR aliases using adapted owned MacScope algorithms and current guarded decoding.
Strict fixed controls, N/width, W shifts, concrete operands and provenance rules
retain conservative unknowns and unchanged checked scope. Contract/results:
`docs/EXTRACT.md`, `docs/EXTRACT_RESULTS.md`. Current app:`dist/AIRS.app`;
previous v22:`dist/bitfield-v22/AIRS.app`. Earlier sections are historical.

Current model `arm64-bounded-bitfield-v22` adds bounded W/X SBFM/BFM/UBFM
and extract/insert/shift/extend/clear aliases,retaining the legacy positive W LSL.
MacScope algorithms were adapted with strict encoding,width,merge and provenance
rules. Contract/results:`docs/BITFIELD.md`, `docs/BITFIELD_RESULTS.md`.
Current app:`dist/AIRS.app`;previous v21:`dist/conditional-select-v21/AIRS.app`.
Earlier sections retain historical meanings.

Current model `arm64-bounded-conditional-select-v21` adds X CSEL and W/X
CSINC/CSINV/CSNEG,including CSET/CSETM/CINC/CINV/CNEG aliases,while retaining W
CSEL. MacScope dispatch and false-arm transforms were adapted; NZCV and bounded
recovery identity rules remain explicit. Contract/results:
`docs/CONDITIONAL_SELECT.md`, `docs/CONDITIONAL_SELECT_RESULTS.md`.
Current app:`dist/AIRS.app`; previous v20:`dist/conditional-compare-v20/AIRS.app`.
Earlier sections retain historical meanings.

Current model `arm64-bounded-conditional-compare-v20` adds bounded W/X
CCMP/CCMN register and imm5 forms,EQ–LE predicates and literal NZCV fallback.
Unknown predicates remain conservative. Existing MacScope field decoding was
adapted; AIRS recovery boundaries remain intact. Contract/results:
`docs/CONDITIONAL_COMPARE.md`, `docs/CONDITIONAL_COMPARE_RESULTS.md`.
Current app:`dist/AIRS.app`; previous v19:`dist/carry-v19/AIRS.app`.
Earlier sections retain historical meanings.

Current model `arm64-bounded-carry-v19` adds bounded W/X ADC/ADCS/SBC/SBCS
register forms and NGC/NGCS aliases, with explicit incoming carry, borrow,
width and NZCV semantics. Unknown carry remains unknown. Exact semantics and
fresh/reused receipts: `docs/CARRY.md`, `docs/CARRY_RESULTS.md`. Current app:
`dist/AIRS.app`; previous v18:`dist/nonflag-register-v18/AIRS.app`.
Earlier sections retain historical model meanings.

Current model `arm64-bounded-nonflag-register-v18` adds bounded W/X AND/BIC/
ORR/ORN/EOR/EON register forms, LSL/LSR/ASR/ROR and MOV/MVN aliases, preserving
prior NZCV and the existing exact X MOV identity behavior. Exact semantics and
fresh/reused receipts are in `docs/NONFLAG_REGISTER.md` and
`docs/NONFLAG_REGISTER_RESULTS.md`. Current app: `dist/AIRS.app`; previous v17:
`dist/nonflag-immediate-v17/AIRS.app`. Earlier sections retain historical meanings.

Current model `arm64-bounded-nonflag-immediate-v17` adds bounded W/X AND, ORR
and EOR immediate and bitmask MOV aliases while preserving prior NZCV, including
unknown flags. Non-flag SP/WSP destinations remain unresolved. Exact semantics
and fresh/reused receipts are in `docs/NONFLAG_IMMEDIATE.md` and
`docs/NONFLAG_IMMEDIATE_RESULTS.md` from repository root. Current app:
`dist/AIRS.app`; previous v16: `dist/logical-immediate-v16/AIRS.app`.

Current model `arm64-bounded-logical-immediate-v16` adds bounded W/X
ANDS-immediate and TST with explicit repeated/rotated bitmask decoding. Exact
semantics and fresh/reused receipts are in `docs/LOGICAL_IMMEDIATE.md` and
`docs/LOGICAL_IMMEDIATE_RESULTS.md` from repository root. Earlier sections retain
historical model meanings. Current app: `dist/AIRS.app`; previous v15:
`dist/logical-flags-v15/AIRS.app`.

Current model `arm64-bounded-logical-flags-v15` adds bounded W/X ANDS/BICS
register forms and TST, with LSL/LSR/ASR/ROR operands. Exact semantics and fresh/
reused receipts are in `docs/LOGICAL_FLAGS.md` and `docs/LOGICAL_FLAGS_RESULTS.md`
from repository root. Earlier sections retain historical model meanings. Current
app: `dist/AIRS.app`; previous v14: `dist/extended-flags-v14/AIRS.app`.

Current model `arm64-bounded-extended-flags-v14` adds bounded extended-register
W/X ADDS/SUBS operands. Exact semantics and fresh/reused receipts are in
`docs/EXTENDED_FLAGS.md` and `docs/EXTENDED_FLAGS_RESULTS.md` from repository root.
Earlier sections retain historical model meanings. Current app: `dist/AIRS.app`;
previous v13: `dist/shifted-flags-v13/AIRS.app`.

Current model `arm64-bounded-shifted-flags-v13` adds bounded LSL/LSR/ASR
shifted operands to W/X ADDS/SUBS register forms. Exact semantics and fresh/reused
receipts are in `docs/SHIFTED_FLAGS.md` and `docs/SHIFTED_FLAGS_RESULTS.md` from
repository root. Earlier sections retain historical model meanings. Current app:
`dist/AIRS.app`; previous v12: `dist/register-flags-v12/AIRS.app`.

Current model `arm64-bounded-register-flags-v12` adds unshifted W/X ADDS and
SUBS register forms, including CMP/CMN aliases and ZR operands. Exact semantics
and fresh/reused evidence are in `docs/REGISTER_FLAGS.md` and
`docs/REGISTER_FLAGS_RESULTS.md` from repository root. Earlier sections retain
historical model meanings. Current app: `dist/AIRS.app`; prior v11:
`dist/flags-v11/AIRS.app`.

Current model `arm64-bounded-flags-v11` adds bounded W ADDS and X ADDS/SUBS
immediate flag producers, including CMN/CMP aliases. Exact semantics and fresh/
reused receipts are in `docs/FLAG_PRODUCERS.md` and
`docs/FLAG_PRODUCERS_RESULTS.md` from repository root. Earlier sections retain
historical model meanings. Current app: `dist/AIRS.app`; v10 is preserved at
`dist/conditions-v10/AIRS.app`.

Current model `arm64-bounded-conditions-v10` adds condition codes EQ through LE
(0–13) to bounded branches and W CSEL. Exact semantics and fresh/reused receipts,
including the completed v10 native overview/detail check after UI-control recovery,
are in `docs/CONDITION_CODES.md` and `docs/CONDITION_CODES_RESULTS.md` from repository
root. Earlier continuation sections retain historical model meanings.

Current model `arm64-bounded-conditional-v9` adds bounded GT/LE return teardown
transfers with recognized successors. Exact semantics and fresh/reused receipts
are in `docs/CONDITIONAL_TEARDOWNS.md` and
`docs/CONDITIONAL_TEARDOWNS_RESULTS.md` from repository root. Earlier continuation
sections retain historical model meanings.

Current model `arm64-bounded-suffixes-v8` adds bounded restore-prefix transfers
to shared return suffixes. Exact semantics and fresh/reused receipts are in
`docs/SHARED_SUFFIXES.md` and `docs/SHARED_SUFFIXES_RESULTS.md` from repository
root. Earlier continuation sections retain historical model meanings.

Current model `arm64-bounded-teardowns-v7` adds independently checked differing
contiguous return teardowns. Exact semantics and fresh/reused receipts are in
`docs/DIFFERING_TEARDOWNS.md` and `docs/DIFFERING_TEARDOWNS_RESULTS.md` from
repository root. Earlier continuation sections retain historical model meanings.

Current model `arm64-bounded-returns-v6` adds multiple RET terminals with identical
bounded teardowns. Exact semantics and fresh/reused evidence are in
`docs/MULTIPLE_RETURNS.md` and `docs/MULTIPLE_RETURNS_RESULTS.md` from repository
root. Earlier continuation sections retain their historical model meanings.

Current model `arm64-bounded-dwarf-cfg-v5` adds bounded FDE recovery at direct
calls through forward CFGs. The exact intersection and fresh/reused evidence
are recorded in `docs/DWARF_CFG.md` and `docs/DWARF_CFG_RESULTS.md` from repository
root. Earlier continuation sections below describe historical model subsets.

Current continuation: `arm64-bounded-calls-v4` adds bounded compact-frame direct
calls through forward CFGs. See `docs/CFG_CALLS.md` (from repository root) and
`docs/CFG_CALLS_RESULTS.md` for exact semantics, fresh evidence and reused receipts.
Older model sections below retain their historical scope.

## 1. What a result means

AIRS is a bounded static diagnostic model. It compares a supported
metadata rule with symbolic caller-recovery state derived from a supported
function shape. It does not prove arbitrary execution, runtime memory validity,
exception personality behavior or whole-binary correctness.

Each finding has three independent dimensions: coverage, verdict and scope.
Coverage reports metadata presence and, for CFI, bounded evaluation status. Verdict records the comparison outcome.
Scope states which observation class was checked. Never infer one dimension
from another, and never collapse unresolved into agreement.

### Verdict lattice used by the starter

| Condition | Result |
| --- | --- |
| Missing rule, unavailable boundary, unsupported instruction/format/model, uncertain recovered value, or budget exhaustion | Unresolved |
| Fully supported model, at least one known recovery discrepancy, and no unknown required recovery value | Supported inconsistency |
| Fully supported model, at least one justified observation, and all required recovery identities agree | Agreement within scope |

If a modeled observation has both a known discrepancy and an unknown required
recovery value, the starter reports unresolved. This is a deliberate conservative
precedence rule. Future versions may expose a local discrepancy alongside a
separate incomplete-analysis status, but must version and explain that change.

Input-table corruption is a separate parse error. A supported inconsistency
does not by itself establish which compiler, linker, assembly author or runtime
component is responsible.

## 2. Synchronous and asynchronous interpretation

Apple compact unwind is used for exception unwinding; its existence does not
promise valid recovery at every arbitrary stopped instruction. Prologue and
epilogue transitions can require different treatment in a sampling profiler or
debugger. The LLVM CFI-validation discussion and existing stack-unwinding work
make this distinction material to an auditor's claims. [R3, R5 in
REFERENCES.md](REFERENCES.md)

The starter therefore has two supported observation scopes:

* **`synchronous_call_sites`:** frame-mode or supported DWARF comparisons at listed modeled direct
  BL suspension states. BL writes its next PC into LR. The callee is summarized
  under the documented ABI assumptions before caller recovery is compared.
* **`modeled_leaf_body`:** frameless or supported DWARF leaf structural comparisons before identified
  body instructions, after supported setup and before supported teardown. This
  is explicitly not asynchronous unwind validation or proof that an exception
  will be raised at those instructions.

`checked_pcs` records the call instruction address for call observations and the
body instruction address for leaf observations. A runtime adapter must not
reinterpret these as raw sampled PCs or normalized return PCs without an explicit
mapping. No runtime slide is applied by the engine.

Frame-mode functions without a supported direct call are unresolved in v0.
Frameless functions containing a call are unresolved. A lone RET without a
distinct supported body state is unresolved. These limits are intentional, not
parser failures or evidence of bad code.

## 3. Identity and address spaces

| Name | Meaning | Representation |
| --- | --- | --- |
| Container file offset | Byte position in a thin/FAT input file | Integer; includes the selected slice offset where relevant |
| Slice-relative file offset | Byte position from the selected Mach-O header | Integer; used by load commands/sections internally |
| Preferred VM address | Unslid image virtual address | Internal integer; lowercase hexadecimal string on the wire |
| Image-relative offset | Preferred address minus `__TEXT.vmaddr` | Hexadecimal string on the wire |
| Runtime address | Preferred address plus a verified process slide | Outside the starter's input/output interpretation |

Use the `__TEXT` segment base for compact function offsets. A page-zero segment
must not become that base. UUID, architecture/subtype and selected-slice digest
identify the image; the full-container digest records the original container.
Equal filenames or equal numeric addresses across builds do not establish
identity. A UUID alone is not a replacement for an exact-byte match in handoff.

All ranges are half open: `[start, end)`. The end does not belong to the range.
The sentinel supplies the final compact range endpoint. A finding ID includes
schema/model identity, selected-slice digest, architecture and function range.
It is stable for the same bytes, not a cross-build source-function identifier.

## 4. Function boundaries and rule joins

The parser reads function starts independently from unwind entries. Preferred
provenance is `LC_FUNCTION_STARTS`. Names may come from symbols, but aliases do
not create duplicate functions and interior labels must not split authoritative
function-start ranges. Symbol-only fallback is displayed as weaker provenance.

Executable sections with embedded data or relocations are visibly qualified.
The starter's semantic checker accepts only exact `lc_function_starts`
provenance. A range inferred from compact metadata alone cannot prove a complete
function and does not receive a semantic finding.

For a known start, the next supported start in the same executable section or
that section's end bounds the candidate function. This is still a model of the
available layout. Full decoding, a recognized return, and allowed trailing NOP
padding are additional requirements; start metadata alone does not prove that
every byte in the candidate range is semantically reachable code.

A compact rule can cover more than one function. That is accepted. A function
spanning multiple compact rules requires PC-sensitive selection and is unresolved
in v0. Never assign the first rule to every PC and then report an apparent
discrepancy caused by that shortcut.

## 5. Symbolic state and ABI assumptions

The model begins with symbolic identities for entry SP and registers x0–x30.
It can represent a known constant, an original register identity with a constant
displacement, an entry-SP-relative address, or an explicit unknown. Stack storage
contains only values written by supported instructions to known allocated slots.

The required caller state is entry SP and original x19–x30 identities. Original
x30 means the function's caller-return identity, not an assertion that x30 is an
ordinary callee-saved register. A direct BL changes LR; later restoration must be
modeled explicitly. Symbols can have equal concrete values on some executions,
but different symbolic identities do not establish restoration for arbitrary
allowed entry states.

A direct callee is summarized as ABI-conforming: it preserves SP and x19–x29,
and does not modify the caller's unescaped allocated stack storage. Volatile
registers become unknown. After recording the BL suspension state, resuming from
the callee makes LR unknown until restored. Callee code is not analyzed, and a
BL into the current function's own range is not summarized this way.

Passing a derived stack address to an unmodeled call could allow caller storage
to change, so such escapes are unresolved. The normal FP frame-chain assumption
is stated separately; it is not permission to assume arbitrary unknown memory
cannot alias saved slots.

The decoder accepts only explicitly implemented forms. Unsupported instructions
are errors in the model, not implicit no-ops. Word-size changes, indirect calls,
PAC instructions, SIMD accesses, unfamiliar hints and general branches require
new semantics before they can contribute to a supported result. See
[DECODER_SCOPE.md](DECODER_SCOPE.md) for exact forms.

## 6. Recovery rules checked in v0

For ordinary ARM64 frame mode, the compact rule restores caller SP from FP+16,
caller FP from the saved word at FP, and caller LR from FP+8. Selected integer
pairs are recovered in the order defined by the format/implementation. The lower
numbered register is at the higher address: the first selected pair begins with
its lower register at FP−8 and its higher register at FP−16. Subsequent selected
pairs continue downward. [R1, R2](REFERENCES.md)

The model compares all required preserved identities. If a metadata pair is
omitted but those registers still contain their original values at the checked
state, omission alone is not a discrepancy. If the needed value changed and the
rule cannot recover its original identity, a fully known supported comparison
can report an inconsistency. If the saved location was never modeled, report an
unknown, not a guessed value.

For the supported frameless leaf subset, there are no saved-pair flags. The
encoded stack field gives stack size in units of 16 bytes; the comparison checks
that body SP plus that size recovers entry SP and that required register
identities remain available. [R1](REFERENCES.md)

Authenticated LR frame mode `0x05`, ordinary ARM64e/PAC behavior, SIMD saved
pairs and frameless saved-pair semantics remain unresolved. Preserve mode `0x05`
as its own metadata mode. It must not be decoded as ordinary `0x04` frame mode.

## 7. Complete-function requirements

A supported result requires all of the following:

1. Accepted ordinary ARM64 image and independent code-only function provenance.
2. One metadata rule covering the complete candidate function range.
3. Supported nonzero mode/encoding fields, with no unimplemented save semantics.
4. A nonempty aligned function within configured limits.
5. Complete decoding using the explicit whitelist.
6. A recognized RET x30; only NOP padding may follow it.
7. A supported setup/body/teardown shape with no unmodeled SP/FP transition in
   the body and at least one justified observation.
8. A complete modeled return restoring entry SP and original x19–x30.
9. No unknown value in any required recovery comparison.

These conditions establish the scope of a static comparison. They are not a
formal proof of actual control-flow reachability, runtime stack validity,
exception correctness or every possible interruption point.

## 8. Limits and uncertainty

Defaults are defined in `types.Limits`: 512 MiB input, 4,096 load commands,
4,096 sections, 50,000 functions, 200,000 unwind entries, 16,384 instructions
per function and 1,000,000 candidate instructions per audit. An additional cap
allows 256 observations per function, 32 retained evidence entries per function
and 8,192 evidence entries per report. The parser has
additional bounded FAT, symbol and decoded-name ceilings documented in code.
Native and imported audit reports are bounded to 64 MiB. Generated JSON is also
capped at 64 MiB before output commit; an oversized serialization produces a
clear error and no partial file. Effective limits are recorded in
`analysis_config.limits`. Baseline comparison identifies differing or missing
configurations as an interpretation note.

Observation exhaustion makes the function unresolved. Evidence-display
truncation does not stop recovery comparison: all collected values are checked,
any unknown still overrides mismatches, and a supported inconsistency retains a
concrete discrepancy. The report states when retained evidence is a sample.

A global analysis budget does not remove functions from the report. It produces
unresolved results for those that cannot be analyzed. Parser limits fail with
a stable input-error code before unsafe iteration. Limits may be configurable
in a later preview, but changing them must not change the meaning of a verdict.

Historical `arm64-linear-v1` preserves DWARF references without evaluating
FDEs. `arm64-linear-dwarf-v2` adds only the subset in [DWARF_CFI.md](DWARF_CFI.md):
exact FDE/function joins, bounded rows and supported recovery at the existing
observation scopes. Merely finding `__eh_frame` or an in-range offset still
establishes neither evaluated CFI nor an asynchronous promise. Other CFI remains
unresolved. Evaluated metadata coverage is separate from supported verdicts.

## 9. Report and comparison invariants

Summary counts must equal actual findings. Supported findings need checked PCs,
present metadata and compatible scope. Known-model imports additionally require
the exact architecture, boundary and encoding relationships that the analyzer
supports. Unknown future model strings are preserved; comparisons with the
current model are ambiguous rather than silently equivalent.

For exact bytes, numeric offsets identify the same function range. Equivalent
hexadecimal formatting must not create added/removed rows. Across builds,
unique symbol names are review candidates only. Unnamed and duplicate-name
functions need future identity work; no nearest-address heuristic is used.

Every handoff preserves the evidence's source model and address space. The
destination must verify exact selected-image identity before applying the range.
Imported-report validation is not a signature or a claim that the imported
analysis was actually run.

## 10. Changing the model

When adding a supported instruction or rule family, document its consumed state,
produced state, alias behavior, unknown propagation and observation scope. Add
reviewed owned examples and a meaningful boundary test. Changes that alter the
meaning of supported results require a new analysis-model version and explicit
comparison behavior. Keep schema versioning separate from analysis semantics.


## 11. Source annotations are independent evidence labels

Optional source_annotations v1 binds a companion dSYM to the original report's
container/selected-slice identity and maps existing function-entry preferred PCs.
It cannot change code identity, function boundaries, checked scope, denominator,
recovery evidence or verdicts. Missing/ambiguous source stays explicit; matching
a dSYM does not evaluate CFI. Available local source contents are not verified
against the build. No source label establishes cross-build function identity.
See [SOURCE_ANNOTATIONS.md](SOURCE_ANNOTATIONS.md) for the bounded format and
[C10_RESULTS.md](C10_RESULTS.md) for actual evidence.


## 12. Bounded v3 leaf control flow

`arm64-bounded-cfg-v3` retains the v2 linear/CFI rules and adds only the
instruction/path subset in [BOUNDED_CFG.md](BOUNDED_CFG.md). Both unknown
conditional successors are retained with separate states at reconvergence.
Agreement requires every conservative body path-state to recover caller
identities and every terminal state to restore them. A supported inconsistency
needs a known-reachable concrete mismatch; a possible-only bad path is unresolved.
Required unknowns and resource exhaustion still override discrepancies.

The new subset is forward-only compact-frameless leaf code, with one shared
setup/teardown shape and exact ordinary ARM64 subtype. W writes zero-extend
and cannot preserve full-X identity by assumption; partial stack writes
invalidate overlapping saved words. Calls, loops, indirect edges and DWARF CFG
remain unresolved. Scope stays modeled_leaf_body; no async/all-PC claim follows.
Historical model versions remain separately interpreted.
