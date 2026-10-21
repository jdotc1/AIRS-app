# Bounded SP-relative X stack slots

Development model: `arm64-bounded-x-stack-v35`, following accepted v34 UDIV.
Schema 1 and product version stay unchanged. This isolated lane is not a release.

## Selected addressing form

Only single-register scalar X STR/LDR with an unsigned scaled immediate and SP
base is admitted. The exact form mask is `0xffc00000`: STR `0xf9000000`, LDR
`0xf9400000`; Rn must be 31. The 12-bit immediate is multiplied by eight.
Every access must be aligned to eight bytes and wholly inside the currently
allocated frame, using a known entry-SP displacement. No writeback occurs.
Rt31 is ZR: a store writes zero, while a load discards its result only after
validating bounds and the complete known slot.

Other register bases (including FP), pre/post indexing, unscaled/register offsets,
byte/halfword/SIMD/atomic/external accesses remain outside this increment. Existing
W unsigned SP accesses and pair operations retain their prior contract. Unsupported
spellings decline without claiming that every such encoding is ISA-invalid.

The scalar size/opc/Rn/Rt and immediate scaling were adapted from the read-only
owned MacScope `ARM64Decoder+LoadsStores.swift` loadStoreScalarForm and
 decodeLoadStoreRegister. No MacScope source or tests were changed or run.
Arm's primary instruction reference describes the unsigned-offset form and X
scale of eight:
https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85
The reference was consulted through its search-index excerpt; full PDF retrieval
previously exceeded the browser limit. AIRS's bounded admission is narrower.

## Store effect

A full X store reads the current source (including original-register and derived
stack-pointer tags) and uses the existing PathState._store. Constant values are
projected to 64 bits. The helper invalidates every overlapping W cache entry and
updates the existing whole-slot memory/pointer marker through MachineState._store.
Neighbor slots remain independent. STR X29 is a read of X29, not a frame write.
An unknown stored value is retained as unknown; it cannot become a saved identity.

## Load effect

A load reads one complete, known existing 64-bit slot. Original, constant and
stack-derived values retain their identity/provenance. Uninitialized and unknown
whole slots decline, consistently with existing pair loads. Two W halves never
synthesize a whole saved tag, and a partial W overwrite makes the X identity
unavailable. No ordinary unknown-load propagation or byte reconstruction is added.

LDR X29 participates in the existing body frame-transition guard. This packet does
not admit arbitrary frame-body restoration sequences by suppressing that guard.
Full original X19/X29/X30 store/modify/load identity is separately tested at the
state-transfer level; supported whole-function frame recovery retains its existing
setup/body/teardown policies. NZCV and unrelated registers are unchanged.

## Lifetime, escape and control flow

Existing allocation/deallocation removes retired X slots, W caches and pointer
markers. Reallocation cannot resurrect prior saves. Stored derived stack pointers
remain visible to the BL escape guard, including after loads and state copies.
Strict call-state partial W writes into a pointer slot decline. A full X overwrite
with a nonpointer removes the marker only because the full pointer was replaced.
The existing copy and recurrence keys retain complete memory/word state. No new
join, loop theory, call summary or memory serialization is introduced. Function,
observation, instruction, path and total budgets still apply.

## Retained complete witnesses

The existing B6 O0 independent disassembly and report are reused from
`maintainer-local accepted evidence`. No library was rebuilt,
rehashed, re-disassembled, re-audited, loaded or executed for this work.

| Function | Retained image-relative extent | Complete body after allocating 16 bytes |
| --- | --- | --- |
| airs_clz64 | 0x3cc–0x3e8 | STR X0 SP+8; LDR X8 SP+8; CLZ X8; MOV X0,X8; deallocate; RET |
| airs_ctz64 | 0x400–0x420 | STR X0 SP+8; LDR X8 SP+8; RBIT X8; CLZ X8; MOV X0,X8; deallocate; RET |
| airs_udiv64 | 0x420–0x440 | STR X0 SP+8; STR X1 SP; LDR X8 SP+8; LDR X9 SP; UDIV X0,X8,X9; deallocate; RET |

All three use retained compact frameless encoding 0x02001000, shared from the
unwind range beginning 0x388; their independent LC_FUNCTION_STARTS extents are
retained in the old report. New tests use the complete literal words relocated to
synthetic VM 0x1000 and the same encoding. Report integration uses typed parser
substitutes and placeholder identity digests, not new Mach-O parser proof.

Exact v35 is registered in all three Python and native model admission lists.
Historical v34/v33/v32 remain strict; unknown models retain generic wire handling.
Import acceptance does not verify the producer's semantic claim. Observations
remain modeled_leaf_body or synchronous_call_sites, not asynchronous/all-PC claims.
Focused semantic/flow and native import receipts are reused. The release
qualification record distinguishes them from fresh packaging/distribution checks.
