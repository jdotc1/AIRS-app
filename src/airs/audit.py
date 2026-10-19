"""Conservative comparison of compact rules with a bounded ARM64 function."""
from __future__ import annotations

from functools import partial

from .arm64 import ENTRY_SP, Instruction, MachineState, ModelError, Value, decode_function, original
from .types import AuditResult, Evidence, FunctionRange, InputError, Limits, MachOImage, UnwindEntry
from .dwarf_cfi import CFITable, parse_eh_frame


# Format constants, independently used from LLVM's compact_unwind_encoding.h.
UNWIND_ARM64_MODE_MASK = 0x0F000000
UNWIND_ARM64_MODE_FRAMELESS = 0x02000000
UNWIND_ARM64_MODE_DWARF = 0x03000000
UNWIND_ARM64_MODE_FRAME = 0x04000000
UNWIND_ARM64_MODE_FRAME_PAUTH_LR = 0x05000000
UNWIND_ARM64_FRAMELESS_STACK_SIZE_MASK = 0x00FFF000
UNWIND_ARM64_FRAME_X19_X20_PAIR = 0x00000001
UNWIND_ARM64_FRAME_X21_X22_PAIR = 0x00000002
UNWIND_ARM64_FRAME_X23_X24_PAIR = 0x00000004
UNWIND_ARM64_FRAME_X25_X26_PAIR = 0x00000008
UNWIND_ARM64_FRAME_X27_X28_PAIR = 0x00000010
INTEGER_PAIRS = ((0x01, 19, 20), (0x02, 21, 22), (0x04, 23, 24),
                 (0x08, 25, 26), (0x10, 27, 28))
INTEGER_PAIR_MASK = 0x0000001F
SIMD_PAIR_MASK = 0x00000F00
COMMON_FLAGS_MASK = 0xF0000000

MODEL_LIMITATIONS = (
    "Only the documented, bounded integer instruction subset is interpreted.",
    "Checks describe selected modeled states; they do not establish whole-function or asynchronous unwind correctness.",
    "SIMD, pointer authentication, CFI outside the bounded subset, personality and LSDA semantics are outside this model.",
)
CALL_LIMITATION = "Direct callees are summarized as ABI-conforming returns preserving SP, x19–x29 and unescaped allocated stack storage; callees are not analyzed."
LEAF_LIMITATION = "Leaf observations are states before identified body instructions, excluding recognized prologue and epilogue transitions."


def encoding_mode(encoding: int) -> str:
    if encoding == 0:
        return "none"
    return {
        UNWIND_ARM64_MODE_FRAME: "frame", UNWIND_ARM64_MODE_FRAMELESS: "frameless",
        UNWIND_ARM64_MODE_DWARF: "dwarf", UNWIND_ARM64_MODE_FRAME_PAUTH_LR: "pauth_frame",
    }.get(encoding & UNWIND_ARM64_MODE_MASK, "unknown")


def _evidence_limit_note(total: int, retained: int) -> tuple[str, ...]:
    if retained >= total:
        return ()
    return (f"Evidence display truncated: retained {retained} of {total} entries, including any summary entry.",)


def _unresolved(code: str, message: str, *, mode: str, evidence_limit: int, coverage: str = "compact",
                address: int | None = None, instruction_count: int = 0,
                scope: str = "metadata_only", evidence: tuple[Evidence, ...] = (),
                total_evidence: int | None = None) -> AuditResult:
    all_retained = (Evidence(code, message, address),) + evidence
    retained = all_retained[:evidence_limit]
    total = len(all_retained) if total_evidence is None else total_evidence
    return AuditResult("unresolved", coverage, mode, scope, (code,),
                       evidence=retained,
                       limitations=MODEL_LIMITATIONS + _evidence_limit_note(total, len(retained)),
                       instruction_count=instruction_count)


def _setup(instruction: Instruction) -> bool:
    return ((instruction.kind == "sub" and instruction.rd == instruction.rn == 31) or
            (instruction.kind == "add" and instruction.rd == 29 and instruction.rn == 31) or
            (instruction.kind == "stp" and (instruction.addressing == "offset" or
                                           (instruction.addressing == "pre" and instruction.immediate < 0))))


def _teardown(instruction: Instruction) -> bool:
    return (instruction.kind == "ldp" or
            (instruction.kind == "add" and instruction.rd == 31 and instruction.rn in (29, 31)) or
            (instruction.kind == "mov" and 19 <= instruction.rd <= 30))


def _body_window(instructions: tuple[Instruction, ...], return_index: int) -> tuple[int, int]:
    """Find a single recognizable setup/body/teardown shape without using metadata."""
    body_start = 0
    for index in range(return_index):
        instruction = instructions[index]
        if _setup(instruction):
            body_start = index + 1
        elif instruction.kind != "nop":
            break
    body_end = return_index
    for index in range(return_index - 1, -1, -1):
        instruction = instructions[index]
        if _teardown(instruction):
            body_end = index
        elif instruction.kind != "nop":
            break
    return body_start, body_end


def _recover(state: MachineState, encoding: int, mode: str) -> dict[str, Value]:
    recovered = {f"x{register}": state.registers[register] for register in range(19, 31)}
    if mode == "frameless":
        size = ((encoding & UNWIND_ARM64_FRAMELESS_STACK_SIZE_MASK) >> 12) * 16
        recovered["SP"] = state.sp.add(size)
        return recovered
    fp = state.registers[29]
    recovered["SP"] = fp.add(16)
    if fp.kind != "stack":
        recovered["x29"] = Value("unknown", "FP does not identify a modeled frame record")
        recovered["x30"] = Value("unknown", "FP does not identify a modeled frame record")
        return recovered

    def saved(offset: int) -> Value:
        if offset < state.sp.displacement or offset + 8 > 0 or offset % 8:
            return Value("unknown", "unwind read is outside the modeled allocated frame")
        return state.memory.get(offset, Value("unknown", f"no modeled store at entry SP{offset:+d}"))

    recovered["x29"] = saved(fp.displacement)
    recovered["x30"] = saved(fp.displacement + 8)
    # LLVM loads the LOWER numbered register from the HIGHER address.
    slot = fp.displacement - 8
    for flag, lower, higher in INTEGER_PAIRS:
        if encoding & flag:
            recovered[f"x{lower}"] = saved(slot)
            recovered[f"x{higher}"] = saved(slot - 8)
            slot -= 16
    return recovered


def audit_function(image: MachOImage, function: FunctionRange, entry: UnwindEntry | None,
                   limits: Limits = Limits(), *, cfi_table: CFITable | InputError | None = None) -> AuditResult:
    """Compare only complete supported functions and justified observations."""
    evidence_limit = max(0, limits.max_evidence_per_function)
    observation_limit = max(0, limits.max_observations_per_function)
    unresolved = partial(_unresolved, evidence_limit=evidence_limit)
    if entry is None:
        return unresolved("missing_unwind_metadata", "No unwind metadata range covers this function", mode="none", coverage="none")
    mode = encoding_mode(entry.encoding)
    if mode == "dwarf":
        unresolved = partial(_unresolved, evidence_limit=evidence_limit, coverage="dwarf_reference")
    if not entry.start <= function.start < function.end <= entry.end:
        return unresolved("metadata_range_incomplete", "One metadata range does not contain the entire function", mode=mode)
    if entry.encoding == 0:
        return unresolved("empty_unwind_rule", "The metadata range explicitly contains no compact unwind rule", mode="none", coverage="none")
    if mode == "pauth_frame" or image.architecture == "arm64e":
        return unresolved("pointer_authentication_not_modeled", "ARM64e and authenticated LR frame recovery are outside this model", mode=mode)
    if image.architecture != "arm64":
        return unresolved("unsupported_architecture", "Integer semantic checking requires ordinary ARM64", mode=mode, coverage="unavailable")
    if mode not in ("frame", "frameless", "dwarf"):
        return unresolved("unsupported_unwind_mode", "The compact encoding has no supported ARM64 recovery mode", mode=mode)
    if function.boundary_source != "lc_function_starts":
        return unresolved("untrusted_function_boundary", "The available boundary source does not establish a complete code-only function", mode=mode)
    if mode != "dwarf" and entry.encoding & SIMD_PAIR_MASK:
        return unresolved("simd_saved_pairs_not_modeled", "The compact encoding requests SIMD register recovery", mode=mode)
    allowed = COMMON_FLAGS_MASK | UNWIND_ARM64_MODE_MASK | INTEGER_PAIR_MASK
    if mode == "frameless":
        allowed |= UNWIND_ARM64_FRAMELESS_STACK_SIZE_MASK
    elif mode == "dwarf":
        allowed |= 0x00ffffff
    if not 0 <= entry.encoding <= 0xFFFFFFFF or entry.encoding & ~allowed:
        return unresolved("unsupported_encoding_bits", "Compact encoding contains bits outside this model's documented fields", mode=mode)
    if mode == "frameless" and entry.encoding & INTEGER_PAIR_MASK:
        return unresolved("frameless_saved_pairs_not_modeled", "Frameless saved-register pairs are not interpreted", mode=mode)

    fde = None
    coverage = "compact"
    if mode == "dwarf":
        if image.cpu_subtype not in (0,1):
            return unresolved("unsupported_dwarf_cpu_subtype", "CFI checking requires an exact supported ordinary ARM64 subtype", mode=mode, coverage="dwarf_reference")
        coverage = "dwarf_reference"
        unresolved = partial(_unresolved, evidence_limit=evidence_limit, coverage=coverage)
        try:
            if isinstance(cfi_table, InputError):
                raise cfi_table
            table = cfi_table if cfi_table is not None else parse_eh_frame(image, limits)
            fde = table.select(entry.encoding & 0xffffff, function)
        except InputError as error:
            return unresolved(error.code, str(error), mode=mode)
        coverage = "dwarf_evaluated"
        unresolved = partial(_unresolved, evidence_limit=evidence_limit, coverage=coverage)

    # Check the limit before requesting bytes, even for a very large mapped range.
    if function.size > limits.max_instructions_per_function * 4:
        return unresolved("function_instruction_limit", "Function exceeds the configured instruction limit", mode=mode)
    instruction_count = 0
    try:
        instructions = decode_function(image.bytes_at(function.start, function.size), function.start,
                                       limits.max_instructions_per_function)
        instruction_count = len(instructions)
        return_index = next(index for index, instruction in enumerate(instructions) if instruction.kind == "ret")
        body_start, body_end = _body_window(instructions, return_index)
        if body_start >= body_end:
            raise ModelError("no_supported_observation", "No distinct supported body state can be identified", function.start)
        for index in range(body_start, body_end):
            instruction = instructions[index]
            if instruction.changes_sp or instruction.changes_fp:
                raise ModelError("unmodeled_frame_transition", "Stack or frame-pointer transition occurs inside the modeled body", instruction.address)

        has_calls = any(instruction.kind == "bl" for instruction in instructions)
        if mode == "frameless" and has_calls:
            raise ModelError("frameless_nonleaf_not_modeled", "Frameless checking is restricted to leaf functions", function.start)
        if mode == "frame" and not has_calls:
            raise ModelError("no_supported_observation", "Frame-mode comparison requires a supported direct-call observation", function.start)
        leaf_observations = mode == "frameless" or (mode == "dwarf" and not has_calls)
        state = MachineState()
        cfi_evidence: list[Evidence] = []
        # Save only 13 immutable recovery values per observation, not copies of
        # the entire stack map. Independently bound the observation count.
        observations: list[tuple[int, dict[str, Value]]] = []

        def observe(pc: int) -> None:
            if len(observations) >= observation_limit:
                raise ModelError("observation_limit", f"Function requires more than the configured {observation_limit} modeled observations", pc)
            if fde is not None:
                row = fde.row_at(pc)
                recovered = row.recover(state)
                if len(cfi_evidence) < evidence_limit:
                    cfi_evidence.append(Evidence("dwarf_cfi_row", f"FDE __eh_frame+{fde.offset:#x}, CIE +{fde.cie_offset:#x}, row at {row.pc:#x}",
                                                 pc, "entry SP and original x19–x30", row.describe()))
            else:
                recovered = _recover(state, entry.encoding, mode)
            observations.append((pc, recovered))

        for index, instruction in enumerate(instructions[:return_index]):
            if leaf_observations and body_start <= index < body_end:
                observe(instruction.address)
            if instruction.kind == "bl":
                target = instruction.address + instruction.immediate
                if function.start <= target < function.end:
                    raise ModelError("intra_function_call_not_modeled", "A BL target lies inside the current function range", instruction.address)
            state.apply(instruction)
            if instruction.kind == "bl":
                observe(instruction.address)
                state.resume_after_call()

        expected_return = {"SP": ENTRY_SP, **{f"x{register}": original(register) for register in range(19, 31)}}
        actual_return = {"SP": state.sp, **{f"x{register}": state.registers[register] for register in range(19, 31)}}
        unrestored = [register for register, expected in expected_return.items() if actual_return[register] != expected]
        if unrestored:
            raise ModelError("unmodeled_return_state", "The complete modeled return does not restore entry identities for " + ", ".join(unrestored), instructions[return_index].address)
        if not observations:
            raise ModelError("no_supported_observation", "No justified comparison state was found", function.start)
    except ModelError as error:
        return unresolved(error.code, str(error), mode=mode, address=error.address, instruction_count=instruction_count)

    scope = "modeled_leaf_body" if leaf_observations else "synchronous_call_sites"
    mismatches: list[Evidence] = []
    unknowns: list[Evidence] = []
    mismatch_count = unknown_count = 0
    for pc, recovered in observations:
        for register, expected in expected_return.items():
            actual = recovered[register]
            if not actual.known:
                unknown_count += 1
                # The unresolved summary occupies one evidence slot. Continue
                # examining every recovery even after display storage is full.
                if len(unknowns) < max(0, evidence_limit - 1):
                    unknowns.append(Evidence("unknown_recovery_value", f"Recovery of {register} depends on an unknown value", pc,
                                             expected.describe(), actual.describe()))
            elif actual != expected:
                mismatch_count += 1
                if len(mismatches) < evidence_limit:
                    mismatches.append(Evidence("caller_state_mismatch", f"The unwind rule does not recover the original {register} identity", pc,
                                               expected.describe(), actual.describe()))
    if unknown_count:
        return unresolved("unknown_recovery_value", f"{unknown_count} requested caller values cannot be recovered within the model", mode=mode,
                          scope=scope, instruction_count=instruction_count, evidence=tuple(unknowns),
                          total_evidence=unknown_count + 1)
    pcs = tuple(pc for pc, _ in observations)
    limitations = MODEL_LIMITATIONS + ((LEAF_LIMITATION,) if leaf_observations else (CALL_LIMITATION,))
    if fde is not None:
        limitations += ("CFI uses Apple/LLVM unchanged-register defaults; only the exact supported CIE/FDE and listed PCs are evaluated.",)
    if evidence_limit == 0:
        return unresolved("evidence_limit", "The configured evidence limit cannot retain a concrete recovery result", mode=mode,
                          scope=scope, instruction_count=instruction_count, total_evidence=1 + mismatch_count)
    if mismatch_count:
        limitations += _evidence_limit_note(mismatch_count + (len(observations) if fde is not None else 0), min(evidence_limit, len(mismatches) + len(cfi_evidence)))
        return AuditResult("inconsistency", coverage, mode, scope, ("caller_state_mismatch",), pcs,
                           tuple((mismatches + cfi_evidence)[:evidence_limit]), limitations, instruction_count)
    if fde is not None:
        limitations += _evidence_limit_note(1 + len(observations), min(evidence_limit, 1 + len(cfi_evidence)))
    evidence = (Evidence("caller_state_recovered", "The unwind rule recovers entry SP and original x19–x30 at every listed modeled observation"),)
    return AuditResult("agreement", coverage, mode, scope, ("supported_model_agreement",), pcs,
                       tuple((list(evidence) + cfi_evidence)[:evidence_limit]), limitations, instruction_count)
