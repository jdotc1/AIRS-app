# Bounded scalar X UDIV

UDIV was introduced under model `arm64-bounded-udiv-v34`, following v33 RBIT.
It is retained in 0.3.1 model `arm64-bounded-x-stack-v35`; schema remains 1.

The decoder fixes every nonoperand bit with mask `0xffe0fc00` and value
`0x9ac00800`. Rd, Rn and Rm use the owned MacScope two-source field mapping.
Only scalar X UDIV is added; W UDIV and SDIV remain unresolved. MacScope's
`ARM64Decoder+DataProcessingRegister.decodeDataProcessingTwoSource` and
`MacIRBuilder` division intrinsic were inspected read-only. AIRS reuses its
existing register helpers, PathState, frame guard, recovery and report codecs;
no donor source or tests were changed or run.

Both incoming sources are captured before writing the destination. Either raw
stack-derived source rejects before masking, zero simplification or discard.
Both sources must be concrete to produce a constant. Original/unknown values
remain unknown, including symbolic x/x and unknown/zero. Concrete operands are
masked to unsigned 64 bits; a zero divisor writes zero, otherwise integer
quotient is used. Rn/Rm/Rd31 are ZR, not SP; aliases read both old inputs.
NZCV, memory and unrelated register state are preserved. Frame-body X29 writes
remain unsupported. No memory, loop, asynchronous or CFI scope expands.

Arm's Instruction Set Reference Guide, D2.182 (printed D2-860), describes the
unsigned quotient and unchanged flags:
https://documentation-service.arm.com/static/6245c734b059dc5ff9a8bdab
The 2025 Arm instruction reference additionally specifies a zero destination for
zero divisor (search-index excerpt; full PDF retrieval exceeded browser limit):
https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85

The complete retained independent O2 disassembly at
`maintainer-local accepted evidence`
is UDIV X0,X0,X1 at image-relative 0x3b8, RET at 0x3bc, ending 0x3c0.
The retained report independently bounds that function using LC_FUNCTION_STARTS
and records compact frameless encoding 0x02000000. The shared unwind range
starts at 0x380. Tests reuse the literal two instruction words, relocated to
synthetic VM 0x1000 with the same encoding. They do not parse or re-audit the old
library, verify its identity again, execute it, or claim whole-image coverage.

Exact v34 registration is added to all three Python and native admission lists.
Historical v32/v33 remain strict; unknown labels retain generic wire handling.
Import acceptance is not verification of a producer's semantic claims.
Focused semantic and native import receipts are reused. The release qualification
record distinguishes retained evidence from fresh packaging/distribution checks.
