# Gimli CFI control subset

AIRS translates selected Gimli code into the bounded Python evaluator in
`src/airs/dwarf_cfi.py`. This is source reuse, without a Rust, FFI, or package
dependency. The retained Rust excerpts are review material and are not compiled.

## Source and license

- Project: [gimli-rs/gimli](https://github.com/gimli-rs/gimli).
- Commit: `478f07ad90e91bb8b061ec33ef4bd3a8448839e1`.
- Source: [`src/read/cfi.rs` at that commit](https://github.com/gimli-rs/gimli/blob/478f07ad90e91bb8b061ec33ef4bd3a8448839e1/src/read/cfi.rs).
- Source Git blob: `f1c3ead9d7bfff9df1354de498ae51742153a6f8`.
- License selected for this reuse: MIT, from the upstream MIT OR Apache-2.0 choice.
- [`LICENSE-MIT` at that commit](https://github.com/gimli-rs/gimli/blob/478f07ad90e91bb8b061ec33ef4bd3a8448839e1/LICENSE-MIT)
  is retained verbatim beside this file, including its copyright and permission
  notice. Its Git blob is `e69282e381bc07152cc7598f21f3162e4bbb1f22`.

The source fragments below are retained verbatim in `cfi-control-excerpts.rs`,
with their original line ranges identified.

| Pinned upstream code | Translation in AIRS |
| --- | --- |
| `CallFrameInstruction::parse`, lines 3392–3410 | Read the unsigned fixed-width operand of `DW_CFA_advance_loc1`, `advance_loc2`, or `advance_loc4`; feed the decoded delta to the existing bounded location transition. |
| `CallFrameInstruction::parse`, lines 3444–3446 | Recognize `DW_CFA_remember_state` and `DW_CFA_restore_state`. |
| `UnwindContext::push_row` and `pop_row`, lines 2215–2231 | Copy the supported CFA and register rules when pushing, enforce capacity and underflow, then pop that recovery state. |
| `UnwindTable::evaluate`, lines 2568–2577 | Restore the saved recovery state while preserving the current instruction location. AIRS keeps PC outside its saved state to enforce this directly. |

## AIRS adaptations and limits

Gimli is a general DWARF library. This translated subset retains AIRS's much
narrower ARM64 Mach-O contract. The operand byte order is fixed to little endian;
code alignment remains exactly 1. AIRS rejects zero, unaligned, overflowing, and
out-of-FDE advances. It requires the existing exact CIE header, explicit CFA,
supported register set, exact compact-unwind/FDE join, and independent function
extent. CIE state-stack operations are rejected because AIRS's CIE interface
exports a single initial row, not a state stack.

AIRS adds a configurable `max_cfi_state_depth` budget, default 64; every control
opcode also consumes the existing instruction budget. The existing row budget
bounds materialized rows. State snapshots copy only the already-supported CFA
and x19–x30 rules. No DWARF expression, pointer encoding, ISA instruction,
asynchronous observation, or selected-binary execution is added.

The full instruction stream is validated before any FDE is used. A supported
prefix cannot hide a late unsupported opcode, truncation, stack underflow, or
budget exhaustion. Pending saved states at FDE end are allowed and discarded;
they never initialize another FDE. Primary `DW_CFA_restore` continues to select
the post-CIE initial register rule, independently of the remembered-state stack.

Importing the complete Rust library would require new build/runtime machinery
and would duplicate AIRS's existing narrow reader. The small translated control
family closes a concrete parsing gap while preserving the standard-library-only
core. This reuse does not claim Gimli's full DWARF coverage or independent
certification of AIRS results.
