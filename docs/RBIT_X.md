# X-only RBIT — bounded v33 contract

RBIT was introduced under model arm64-bounded-rbit-v33 and is retained in
0.3.1 model arm64-bounded-x-stack-v35. Report schema remains 1.

## Instruction and state semantics

Admit only words satisfying word & 0xfffffc00 == 0xdac00000. Rn and Rd are the
five-bit register operands; register 31 means ZR and never SP. W RBIT, SIMD forms,
CLS/REV families and reserved/neighbor spellings gain no support from this rule.

The transfer reads its incoming source before writing the destination. Concrete
integers are projected to 64 bits, and all 64 bits are reversed. Existing X-register
write/discard behavior handles aliases and XZR. NZCV and unrelated state are
unchanged. Original/unknown values produce unknown output; derived stack-address
provenance raises rbit_stack_address_not_modeled even if the result is discarded.
No stack arithmetic, stack-memory access or recovery inference is introduced.

The existing framed CFG body guard includes RBIT writes to X29. Modified
callee-saved registers must still recover correctly. Concrete call-site mismatch,
unknown recovery, possible-only path uncertainty, later unknown precedence,
resource limits and unsupported instructions retain their existing outcomes.
Findings remain scoped to original checked call PCs or explicitly modeled leaf
body observations. No asynchronous/all-PC guarantee is added.

## Model and consumers

Both Python and native supported-finding admission explicitly register the exact
v33 identity, retaining historical model labels. Suffix and other future labels
remain generic imports, not registered v33 semantics. The existing model-specific
ordinary subtype, independent boundary, encoding/mode/scope and DWARF conditions
apply. Finding identities already include the model identifier through the
unchanged engine report assembler.

The supplied candidate is reused directly: decoder, state transfer and X29 guard,
plus its focused tests and accepted 23-method semantic receipt. Two old CLZ
expectations change because X RBIT is now supported; W RBIT remains the negative
neighbor. Unknown-model tests use a future v34-shaped label now that v33 is assigned.

## Evidence and limits

The complete retained typed CTZ sequence is RBIT X8,X0; CLZ X0,X8; RET.
Agreement concerns bounded unwind recovery rather than a verified numeric CTZ
result for unknown arguments. Focused semantic, report and native import receipts
are reused. See RELEASE_NOTES.md and the release qualification record for the
current cumulative v35 observation and distribution limits. Target binaries are
read as data, never executed by the analyzer.
