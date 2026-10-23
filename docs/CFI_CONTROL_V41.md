# Bounded CFI controls in model v41

`arm64-bounded-cfi-control-v41` composes the accepted v40 local-FDE
refusal behavior with fixed-width location advances and remembered recovery
state. Existing instruction, frame, provenance, CFG and compact-range semantics
remain inherited from v40.

`parse_eh_frame` and `program` expose keyword-only
`enable_cfi_controls=False`. Their default preserves historical v40 direct
parser behavior. The active engine opts in when constructing its shared table.
Direct auditor fallbacks remain historical; callers can supply an explicitly
opted-in table through the existing `cfi_table` parameter.

The opt-in supports `DW_CFA_advance_loc1/2/4` (`0x02/03/04`) with unsigned
little-endian fixed-width operands and code alignment exactly one. All advance
forms require a positive delta, ARM64 instruction alignment, no unsigned64 wrap,
and a location no later than the FDE end. An end row is legal; the end remains
outside the half-open selectable extent. Location changes in CIEs remain
unsupported.

`DW_CFA_remember_state` (`0x0a`) snapshots the complete supported CFA and
x19–x30 recovery rules by value. `DW_CFA_restore_state` (`0x0b`) pops that
recovery state at the current PC. It does not restore PC or alter the CIE-derived
initial rules used by primary register restore. Nested snapshots are bounded by
`Limits.max_cfi_state_depth` (default 64); zero disables pushes. Unconsumed
snapshots at FDE end are valid and never cross into another FDE.

Malformed fixed advances, invalid locations, stack underflow and stack-depth
exhaustion refuse the entire affected FDE. No supported-prefix rows survive.
The remaining opaque bytes reserve the existing global instruction/row budgets,
including a pending/final row, so refusal cannot bypass resource bounds. A
shared budget failure remains table-wide. Unsupported CIE controls and arbitrary
unsupported opcodes remain table-wide refusals. Structural record/header
preflight and overlap detection still include refused FDEs.

The adapted fixed-width parsing and push/pop algorithm derive from the pinned
MIT-licensed gimli excerpts in `third_party/gimli/`. AIRS supplies the bounded
register subset, positive/grid/range policy, conservative refusal and global
budget integration.

`tests/test_cfi_v41_integration.py` supplies literal positive rows, nested and
non-aliasing state, initial-rule restoration, fixed-width byte order, current-PC
restoration, unknown precedence, late failures, budgets, historical defaults and
unrelated-FDE preservation. These are authored tests; this implementation lane
has not executed tests or builds. Composed qualification is owned by the parent
integration lane. No existing receipt is represented as v41 runtime evidence.

Composed qualification subsequently passed the27-method Python selection,
both native builds and focused native admission/signature/lifecycle tests.
See PR5_CURRENT_BASELINE_RESULTS.md; the authoring-only note above records the
earlier lane checkpoint, and does not invalidate the later receipt.
