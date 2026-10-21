"""Small, explicit ARM64 decoder and symbolic integer/stack model.

This module interprets owned instruction bytes as data. It is deliberately not
a general disassembler or emulator: unrecognized effects raise ModelError.
See docs/DECODER_SCOPE.md for the observation and ABI assumptions.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import heapq
import struct


MASK64 = (1 << 64) - 1
NOP = 0xD503201F
RET_X30 = 0xD65F03C0


class ModelError(ValueError):
    def __init__(self, code: str, message: str, address: int | None = None):
        super().__init__(message)
        self.code, self.address = code, address


# Single-destination effects shared by legacy and CFG frame-body admission.
# Loads write Rd; stores/compares/branches do not. Pair data/base effects remain
# explicit below. Adding a decoder family must classify its FP-writing effect.
_FP_DESTINATION_KINDS = frozenset((
    'add', 'sub', 'mov', 'movz', 'movn', 'xudiv',
    'xrbit', 'wclz', 'xclz', 'wadc', 'wadcs', 'wsbc',
    'wsbcs', 'xadc', 'xadcs', 'xsbc', 'xsbcs', 'wadd',
    'wadds', 'wsubs', 'xadds', 'xsubs', 'wadds_reg', 'wsubs_reg',
    'xadds_reg', 'xsubs_reg', 'wadds_ext', 'wsubs_ext', 'xadds_ext', 'xsubs_ext',
    'smulh', 'umulh', 'smaddl', 'smsubl', 'umaddl', 'umsubl',
    'wmadd', 'wmsub', 'xmadd', 'xmsub', 'wlslv', 'wlsrv',
    'wasrv', 'wrorv', 'xlslv', 'xlsrv', 'xasrv', 'xrorv',
    'wextr', 'xextr', 'wsbfm', 'wbfm', 'wubfm', 'xsbfm',
    'xbfm', 'xubfm', 'wlsl', 'wcsel', 'wcsinc', 'wcsinv',
    'wcsneg', 'xcsel', 'xcsinc', 'xcsinv', 'xcsneg', 'xldr',
    'wldr', 'wands', 'wbics', 'xands', 'xbics', 'wands_imm',
    'xands_imm', 'wand_imm', 'worr_imm', 'weor_imm', 'xand_imm', 'xorr_imm',
    'xeor_imm', 'wand_reg', 'wbic_reg', 'worr_reg', 'worn_reg', 'weor_reg',
    'weon_reg', 'xand_reg', 'xbic_reg', 'xorr_reg', 'xorn_reg', 'xeor_reg',
    'xeon_reg',
))


@dataclass(frozen=True)
class Instruction:
    address: int
    word: int
    kind: str
    rd: int = 0
    rn: int = 0
    rt2: int = 0
    immediate: int = 0
    addressing: str = ""

    @property
    def changes_sp(self) -> bool:
        return ((self.kind in ("add", "sub") and self.rd == 31) or
                (self.kind in ("stp", "ldp") and self.rn == 31 and
                 self.addressing != "offset"))

    @property
    def changes_fp(self) -> bool:
        return ((self.kind in _FP_DESTINATION_KINDS and self.rd == 29) or
                (self.kind == "ldp" and 29 in (self.rd, self.rt2)) or
                (self.kind in ("stp", "ldp") and self.rn == 29 and
                 self.addressing != "offset"))


def _signed(value: int, bits: int) -> int:
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def decode_instruction(word: int, address: int = 0) -> Instruction:
    """Decode one exact whitelisted 32-bit word, or reject its effects."""
    if not 0 <= word <= 0xFFFFFFFF:
        raise ModelError("invalid_instruction_word", "An instruction is not a 32-bit word", address)
    if word == NOP:
        return Instruction(address, word, "nop")
    if word == RET_X30:
        return Instruction(address, word, "ret", rn=30)
    if word in (0xD503233F, 0xD503237F, 0xD50323BF, 0xD50323FF,
                0xD50320FF, 0xD65F0BFF, 0xD65F0FFF):
        raise ModelError("unsupported_pauth", "Pointer authentication is outside the integer model", address)
    if word & 0xFC000000 == 0x94000000:
        return Instruction(address, word, "bl", immediate=_signed(word & 0x03FFFFFF, 26) * 4)

    pair_forms = {
        0xA9000000: ("stp", "offset"), 0xA9800000: ("stp", "pre"),
        0xA8800000: ("stp", "post"), 0xA9400000: ("ldp", "offset"),
        0xA9C00000: ("ldp", "pre"), 0xA8C00000: ("ldp", "post"),
    }
    form = pair_forms.get(word & 0xFFC00000)
    if form:
        kind, addressing = form
        rd, rn, rt2 = word & 31, (word >> 5) & 31, (word >> 10) & 31
        if rn not in (29, 31):
            raise ModelError("unsupported_memory_base", "Integer pair access must use SP or FP", address)
        if kind == "ldp" and rd == rt2:
            raise ModelError("ambiguous_pair_registers", "LDP with overlapping destinations is unsupported", address)
        if addressing != "offset" and rn != 31 and rn in (rd, rt2):
            raise ModelError("ambiguous_writeback", "Pair writeback overlaps a transferred register", address)
        return Instruction(address, word, kind, rd, rn, rt2,
                           _signed((word >> 15) & 0x7F, 7) * 8, addressing)

    immediate_form = word & 0xFF800000
    if immediate_form in (0x91000000, 0xD1000000):
        immediate = ((word >> 10) & 0xFFF) << (12 if word & (1 << 22) else 0)
        return Instruction(address, word, "add" if immediate_form == 0x91000000 else "sub",
                           word & 31, (word >> 5) & 31, immediate=immediate)
    if word & 0xFFE0FFE0 == 0xAA0003E0:
        # ORR Xd, XZR, Xm, LSL #0: the 64-bit MOV register alias only.
        return Instruction(address, word, "mov", word & 31, (word >> 16) & 31)
    if immediate_form in (0xD2800000, 0x92800000):
        immediate = ((word >> 5) & 0xFFFF) << (((word >> 21) & 3) * 16)
        return Instruction(address, word, "movz" if immediate_form == 0xD2800000 else "movn",
                           word & 31, immediate=immediate)

    if (word & 0x7C000000 == 0x14000000 or word & 0xFE000000 == 0xD6000000 or
            word & 0xFF000010 == 0x54000000 or
            word & 0x7E000000 in (0x34000000, 0x36000000)):
        raise ModelError("unsupported_control_flow", "Only direct BL and RET x30 control flow is modeled", address)
    raise ModelError("unsupported_instruction", f"Instruction {word:#010x} has no modeled effects", address)


def decode_function(code: bytes, start: int, max_instructions: int) -> tuple[Instruction, ...]:
    """Require a complete aligned range, one RET x30, and only NOPs after it."""
    if start % 4 or not code or len(code) % 4:
        raise ModelError("unaligned_function_range", "Function bytes must form a nonempty aligned ARM64 range", start)
    if len(code) // 4 > max_instructions:
        raise ModelError("function_instruction_limit", "Function exceeds the configured instruction limit", start)
    result: list[Instruction] = []
    returned = False
    for index, (word,) in enumerate(struct.iter_unpack("<I", code)):
        address = start + index * 4
        if returned and word != NOP:
            raise ModelError("non_nop_after_return", "Only NOP padding is supported after the first RET x30", address)
        instruction = decode_instruction(word, address)
        result.append(instruction)
        returned |= instruction.kind == "ret"
    if not returned:
        raise ModelError("missing_supported_return", "Complete function has no recognized RET x30", start)
    return tuple(result)


@dataclass(frozen=True)
class Value:
    """An entry identity, constant, entry-SP displacement, or explicit unknown."""
    kind: str
    value: int | str = 0
    displacement: int = 0

    @property
    def known(self) -> bool:
        return self.kind != "unknown"

    def add(self, amount: int) -> Value:
        if not self.known:
            return self
        if self.kind == "constant":
            return Value("constant", (int(self.value) + amount) & MASK64)
        return Value(self.kind, self.value, self.displacement + amount)

    def describe(self) -> str:
        if self.kind == "unknown":
            return f"unknown ({self.value})"
        if self.kind == "constant":
            return f"constant {int(self.value):#x}"
        base = "entry SP" if self.kind == "stack" else f"original x{self.value}"
        return base if self.displacement == 0 else f"{base}{self.displacement:+d}"


def original(register: int) -> Value:
    return Value("original", register)


ENTRY_SP = Value("stack")
ZERO = Value("constant")


@dataclass
class MachineState:
    registers: list[Value] = field(default_factory=lambda: [original(i) for i in range(31)])
    sp: Value = ENTRY_SP
    memory: dict[int, Value] = field(default_factory=dict)
    _memory_offsets: list[int] = field(default_factory=list, init=False, repr=False)
    _stack_pointer_slots: set[int] = field(default_factory=set, init=False, repr=False)

    def __post_init__(self) -> None:
        self._memory_offsets = list(self.memory)
        heapq.heapify(self._memory_offsets)
        self._stack_pointer_slots = {offset for offset, value in self.memory.items() if value.kind == "stack"}

    def copy(self) -> MachineState:
        return MachineState(self.registers.copy(), self.sp, self.memory.copy())

    def read_register(self, register: int) -> Value:
        return ZERO if register == 31 else self.registers[register]

    def _write_register(self, register: int, value: Value) -> None:
        if register != 31:
            self.registers[register] = value

    def _set_sp(self, value: Value, address: int) -> None:
        if value.kind != "stack":
            raise ModelError("unknown_stack_pointer", "SP is not a known entry-SP displacement", address)
        if value.displacement > 0 or value.displacement % 16:
            raise ModelError("unmodeled_stack_alignment", "SP must remain aligned within the current allocated frame", address)
        self.sp = value
        # Deallocated bytes cannot silently remain a source of saved identities.
        while self._memory_offsets and self._memory_offsets[0] < value.displacement:
            offset = heapq.heappop(self._memory_offsets)
            self.memory.pop(offset, None)
            self._stack_pointer_slots.discard(offset)

    def _store(self, offset: int, value: Value) -> None:
        if offset not in self.memory:
            heapq.heappush(self._memory_offsets, offset)
        self.memory[offset] = value
        if value.kind == "stack":
            self._stack_pointer_slots.add(offset)
        else:
            self._stack_pointer_slots.discard(offset)

    def _memory_offset(self, base: Value, instruction: Instruction, size: int = 16) -> int:
        if base.kind != "stack":
            raise ModelError("unknown_memory_address", "Memory base is not a known entry-SP displacement", instruction.address)
        offset = base.displacement
        if offset % 8 or offset < self.sp.displacement or offset + size > 0:
            raise ModelError("memory_outside_modeled_frame", "Memory access is outside the known allocated stack frame", instruction.address)
        return offset

    def apply(self, instruction: Instruction) -> None:
        """Apply a whitelisted effect. BL leaves the modeled suspension state."""
        kind, address = instruction.kind, instruction.address
        if kind in ("nop", "ret"):
            return
        if kind in ("add", "sub"):
            source = self.sp if instruction.rn == 31 else self.read_register(instruction.rn)
            value = source.add(instruction.immediate if kind == "add" else -instruction.immediate)
            if instruction.rd == 31:
                self._set_sp(value, address)
            else:
                self._write_register(instruction.rd, value)
            return
        if kind == "mov":
            self._write_register(instruction.rd, self.read_register(instruction.rn))
            return
        if kind in ("movz", "movn"):
            value = instruction.immediate if kind == "movz" else (~instruction.immediate & MASK64)
            self._write_register(instruction.rd, Value("constant", value))
            return
        if kind in ("stp", "ldp"):
            base = self.sp if instruction.rn == 31 else self.read_register(instruction.rn)
            adjusted = base.add(instruction.immediate)
            location = base if instruction.addressing == "post" else adjusted
            if instruction.addressing == "pre":
                if instruction.rn == 31:
                    self._set_sp(adjusted, address)
                else:
                    self._write_register(instruction.rn, adjusted)
            offset = self._memory_offset(location, instruction)
            if kind == "stp":
                self._store(offset, self.read_register(instruction.rd))
                self._store(offset + 8, self.read_register(instruction.rt2))
            else:
                if offset not in self.memory or offset + 8 not in self.memory:
                    raise ModelError("unknown_stack_read", "Pair load reads a stack slot without a modeled store", address)
                first, second = self.memory[offset], self.memory[offset + 8]
                if not first.known or not second.known:
                    raise ModelError("unknown_stack_read", "Pair load reads an unknown saved value", address)
                self._write_register(instruction.rd, first)
                self._write_register(instruction.rt2, second)
            if instruction.addressing == "post":
                if instruction.rn == 31:
                    self._set_sp(adjusted, address)
                else:
                    self._write_register(instruction.rn, adjusted)
            return
        if kind == "bl":
            if any(value.kind == "stack" for value in self.registers[:29]) or self._stack_pointer_slots:
                raise ModelError("stack_address_escapes_call", "A derived stack address may escape to an unmodeled callee", address)
            for register in range(19):
                self.registers[register] = Value("unknown", f"x{register} after direct call")
            # BL writes its next PC to LR. The snapshot is taken after this write.
            self.registers[30] = Value("constant", address + 4)
            return
        raise ModelError("unsupported_effect", "No symbolic effect exists for this instruction", address)

    def resume_after_call(self) -> None:
        # A normal callee return does not promise preservation of caller-saved LR.
        self.registers[30] = Value("unknown", "LR after unmodeled callee return")
