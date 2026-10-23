First owned-image v38 qualification is now complete. See
../../docs/W_RBIT_OWNED_QUALIFICATION.md and qualification-v38.json. Historical
preparation/typed-only notes below retain their original scope; no repeat is
implied by their command proposals.

v38 implementation note: typed semantic/report qualification is now recorded in
../../docs/RBIT_W_RESULTS.md. The library itself remains uncompiled and unrun.
Original preparation expectations below describe the v37 baseline.

# Prepared scalar W RBIT example

Status: source and expectations only, 21 October 2026. Not assembled, linked,
disassembled, decoded, audited or executed. No model identity allocated and no
engine changes. The previous eight-function nonleaf input is preserved.

Selected family: exact scalar W RBIT. The retained nonleaf inventory did not
show a missing valid family; this is a new deliberately selected owned example,
not a newly discovered blocker in that library or a prevalence claim. Four leaf
functions contain eleven intended instruction words, with no calls, memory,
branches or new CFG theory. Explicit frameless compact records use AIRS's existing
0x02000000 leaf pattern. Final image boundaries/metadata must be checked in a
future authorized first qualification; source labels are not binary evidence.

## Retained source reuse

- AIRS tests/test_rbit_v33_integration.py retains W RBIT 0x5ac00008 followed by
  W CLZ 0x5ac01100 as an intentionally unsupported valid sequence. The prepared
  unknown_ctz body reuses it and appends RET.
- AIRS tests/test_clz.py retains X RBIT 0xdac00008 / X CLZ 0xdac01100 / RET;
  xrbit_control reuses that complete accepted sequence unchanged.
- AIRS fixtures/toolchain/coverage-candidates.c provides the existing CTZ probe
  motivation; this W example explicitly defines the zero case as 32, unlike C's
  undefined __builtin_ctz(0). No compiler lowering is assumed.
- AIRS fixtures/nonleaf-v35/nonleaf.S supplies the explicit compact-record layout;
  no retained fixture is edited.
- Read-only MacScope source: MacScope/Services/Disassembly/
  ARM64Decoder+DataProcessingRegister.swift, decodeDataProcessingOneSource,
  dispatches opcode2=0/opcode=0 as RBIT and selects W/X through sf. The owned
  Tests/CoreTests/Support/A64Oracle/MacIRConcreteEvaluator.swift scalar RBIT case
  masks width and reverses 32 bits for W. Its X one-source decoder test is context,
  not evidence that this new W packet has run. No third-party code was copied.

MacScope source root inspected read-only:
a new local development output parent/macscope/MacScope

## Expected results, not measurements

| Function | Current v37 expectation | Future bounded W support expectation |
| --- | --- | --- |
| wrbit_constant | unresolved at W RBIT | leaf agreement; x0 becomes 0x80000000 (zero upper half) |
| wrbit_unknown_ctz | unresolved at first W RBIT | leaf agreement; symbolic result remains unknown |
| wrbit_zero | unresolved at W RBIT | leaf agreement; x0 becomes zero, SP unchanged |
| xrbit_control | existing leaf agreement | unchanged leaf agreement |

Intended function sizes are 12, 12, 8 and 12 bytes; total 44 bytes/11 words.
No predicted addresses, binary hashes or measured checked-PC counts are invented.
With the existing audit policy, unsupported W bodies should remain metadata-only;
future agreement requires actual admission/recovery checks, not just decoding.

For independent arithmetic expectations, reverse the low 32 bit positions:
0 -> 0; 1 -> 0x80000000; 0x80000000 -> 1; 0xffffffff -> 0xffffffff;
0x01234567 -> 0xe6a2c480. W writes zero the upper 32 bits. Unknown values must not
become original-register identities. RBIT leaves NZCV unchanged. ZR is not SP.
These are proposed assertions to preserve, not executed checks.

## Future qualification boundary

Before adopting semantics, independently review the exact W decode mask, aliases,
ZR/discard behavior, upper-half zeroing, unknown/provenance handling, flags and
frame-writer registration. Preserve X behavior and refuse unrelated one-source,
SIMD, reserved and stack-derived inputs under their existing contracts. Allocate
a new model and register exact consumer admission only with a later authorized
implementation. This preparation does not modify old W-negative expectations.

A later specifically authorized bounded pass can assemble/link this one owned
source, independently disassemble it and run one inventory/audit with four-function
and small word/step limits and a timeout. Do not execute the target, rebuild the old
workload or repeat accepted checks. No build/run script is supplied or invoked now.
Release integration, signing, notarization, publication and installation remain
separate. MacScope is unchanged.

Implementation correction (v38): the constant setup now uses supported X MOVZ
(`mov x0, #1`), preserving the low32 input. The originally prepared W MOVZ
was outside AIRS admission. No binary was compiled to discover or fix this.
