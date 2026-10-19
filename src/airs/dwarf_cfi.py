"""Bounded Apple ordinary-ARM64 __eh_frame subset; no expressions or execution.

The selected compilation-system convention retains integer registers for absent
rules (LLVM libunwind kRegisterUnused), including current LR for a leaf. This is
not the generic DWARF undefined default. Explicit undefined is always unknown.
"""
from __future__ import annotations

from bisect import bisect_right
from dataclasses import dataclass
import struct

from .arm64 import MachineState, Value
from .types import FunctionRange, InputError, Limits, MachOImage


def fail(message: str) -> None:
    raise InputError('dwarf_cfi_unsupported', message)


class Reader:
    def __init__(self, data: bytes, start: int, end: int):
        self.data, self.pos, self.end = data, start, end

    def take(self, size: int) -> bytes:
        if size < 0 or self.pos + size > self.end:
            fail('Truncated __eh_frame operand or record')
        value = self.data[self.pos:self.pos+size]
        self.pos += size
        return value

    def byte(self) -> int:
        return self.take(1)[0]

    def uleb(self) -> int:
        result = 0
        for shift in range(0, 70, 7):
            byte = self.byte()
            result |= (byte & 127) << shift
            if not byte & 128:
                if result >= 1 << 64:
                    fail('CFI ULEB operand exceeds 64 bits')
                return result
        fail('CFI ULEB operand is unterminated or too long')


@dataclass(frozen=True)
class Row:
    pc: int
    cfa: tuple[int, int]
    rules: dict[int, tuple[str, int]]

    def recover(self, state: MachineState) -> dict[str, Value]:
        register, offset = self.cfa
        base = state.sp if register == 31 else state.registers[register]
        cfa = base.add(offset)
        result = {'SP': cfa}
        for register, (kind, displacement) in self.rules.items():
            if kind == 'same':
                value = state.registers[register]
            elif kind == 'undefined':
                value = Value('unknown', 'DW_CFA_undefined')
            else:
                location = cfa.add(displacement)
                if (location.kind != 'stack' or location.displacement % 8
                        or location.displacement < state.sp.displacement or location.displacement + 8 > 0):
                    value = Value('unknown', 'CFI read is outside the modeled allocated frame')
                else:
                    value = state.memory.get(location.displacement, Value('unknown', 'CFI slot has no modeled store'))
            result[f'x{register}'] = value
        return result

    def describe(self) -> str:
        register, offset = self.cfa
        base = 'SP' if register == 31 else f'x{register}'
        rules = ', '.join(f'x{reg}='+('CFA'+f'{value:+d}'+' memory' if kind == 'offset' else kind)
                          for reg,(kind,value) in self.rules.items() if kind != 'same')
        return f'CFA={base}{offset:+d}; '+(rules or 'x19–x30 retained in registers')


@dataclass(frozen=True)
class FDE:
    offset: int
    cie_offset: int
    start: int
    end: int
    rows: tuple[Row, ...]

    def row_at(self, pc: int) -> Row:
        if not self.start <= pc < self.end:
            fail('The requested CFI PC is outside the half-open FDE')
        index = bisect_right([row.pc for row in self.rows], pc) - 1
        return self.rows[index]


@dataclass(frozen=True)
class CFITable:
    fdes: dict[int, FDE]
    overlapping: frozenset[int]

    def select(self, offset: int, function: FunctionRange) -> FDE:
        fde = self.fdes.get(offset)
        if fde is None:
            fail('Compact DWARF offset does not identify an exact FDE record start')
        if offset in self.overlapping:
            fail('Overlapping FDE ranges make PC selection ambiguous')
        if (fde.start, fde.end) != (function.start, function.end):
            fail('The referenced FDE does not exactly match the independent function extent')
        return fde


class Budget:
    def __init__(self, limits: Limits):
        self.limits, self.operations, self.rows = limits, 0, 0

    def instruction(self) -> None:
        self.operations += 1
        if self.operations > self.limits.max_cfi_instructions:
            fail('CFI instruction budget exhausted')

    def row(self) -> None:
        self.rows += 1
        if self.rows > self.limits.max_cfi_rows:
            fail('CFI row budget exhausted')


def program(reader: Reader, start: int, end: int, initial: Row | None, budget: Budget) -> tuple[Row, ...]:
    """Read the ENTIRE stream; no supported prefix can hide a later unknown."""
    pc = start
    cfa = initial.cfa if initial else None
    rules = dict(initial.rules) if initial else {reg: ('same', 0) for reg in range(19,31)}
    rows: list[Row] = []

    def save() -> None:
        if cfa is None:
            fail('No explicit supported CFA definition is available')
        row = Row(pc, cfa, rules.copy())
        if rows and rows[-1].pc == pc:
            rows[-1] = row
        else:
            budget.row()
            rows.append(row)

    def reg(number: int) -> int:
        if not 19 <= number <= 30:
            fail('CFI register rule is outside x19–x30')
        return number

    while reader.pos < reader.end:
        budget.instruction()
        opcode = reader.byte()
        family, operand = opcode & 0xc0, opcode & 0x3f
        if family == 0x40:
            if initial is None or not operand:
                fail('Location changes in CIEs and zero advances are outside this subset')
            save()
            pc += operand  # code alignment factor is exactly 1
            if pc > end or pc % 4:
                fail('CFI location advance is outside the FDE or ARM64 instruction grid')
        elif family == 0x80:
            number = reg(operand)
            displacement = reader.uleb() * -8
            if displacement < -(1 << 63):
                fail('CFI stack offset overflows signed 64 bits')
            rules[number] = ('offset', displacement)
        elif family == 0xc0:
            if initial is None:
                fail('A restore in a CIE has no supported initial rule')
            number = reg(operand)
            rules[number] = initial.rules[number]
        elif opcode == 0:
            continue
        elif opcode in (7,8):
            rules[reg(reader.uleb())] = ('undefined' if opcode == 7 else 'same', 0)
        elif opcode == 12:
            number, offset = reader.uleb(), reader.uleb()
            if number not in (29,31) or offset >= 1 << 63:
                fail('CFA requires x29 or SP and a bounded unsigned offset')
            cfa = (number, offset)
        elif opcode == 13:
            number = reader.uleb()
            if cfa is None or number not in (29, 31):
                fail('CFA register update lacks a supported definition or register')
            cfa = (number, cfa[1])
        elif opcode == 14:
            offset = reader.uleb()
            if cfa is None or offset >= 1 << 63:
                fail('CFA offset update lacks a supported definition or overflows')
            cfa = (cfa[0],offset)
        else:
            fail(f'CFI opcode {opcode:#x} is outside the supported subset')
    save()
    return tuple(rows)


def parse_eh_frame(image: MachOImage, limits: Limits = Limits()) -> CFITable:
    section = image.section('__TEXT','__eh_frame')
    if section is None or not section.size:
        fail('No nonempty __TEXT,__eh_frame section is available')
    if section.size > limits.max_cfi_bytes or section.flags & 0xff in (1,12,18):
        fail('CFI section is oversized or not file backed')
    if section.file_offset < 0 or section.file_offset + section.size > len(image.data):
        fail('CFI section extends outside the selected slice')
    data = image.data[section.file_offset:section.file_offset+section.size]
    records: dict[int, tuple[int,int]] = {}
    reader = Reader(data,0,len(data))
    while reader.pos < reader.end:
        offset = reader.pos
        length = int.from_bytes(reader.take(4),'little')
        if length == 0:
            if any(reader.take(reader.end-reader.pos)):
                fail('Nonzero bytes follow the __eh_frame terminator')
            break
        if length == 0xffffffff or length < 4 or length > reader.end-reader.pos:
            fail('Unsupported DWARF64 or malformed __eh_frame record length')
        if len(records) >= limits.max_cfi_records:
            fail('CFI record budget exhausted')
        end = reader.pos + length
        identifier = int.from_bytes(reader.take(4),'little')
        records[offset] = (end,identifier)
        reader.pos = end
    budget = Budget(limits)
    cies: dict[int,Row] = {}
    for offset,(end,identifier) in records.items():
        if identifier:
            continue
        reader = Reader(data,offset+8,end)
        # Exact layout deliberately limits augmentations, alignment and RA column.
        if reader.take(9) != b'\x01zR\0\x01\x78\x1e\x01\x10':
            fail('Only CIEv1 zR, code1/data-8, RA30, pcrel-pointer64 is supported')
        cies[offset] = program(reader,0,0,None,budget)[-1]
    fdes = {}
    for offset,(end,identifier) in records.items():
        if not identifier:
            continue
        cie_offset = offset + 4 - identifier
        if cie_offset >= offset or cie_offset not in cies:
            fail('FDE backward CIE pointer does not identify an earlier exact CIE')
        reader = Reader(data,offset+8,end)
        displacement = struct.unpack('<q',reader.take(8))[0]
        start = section.address + offset + 8 + displacement
        size = int.from_bytes(reader.take(8),'little')
        if not (0 <= start < start+size < 1 << 64) or start % 4 or size % 4:
            fail('FDE address range is empty, overflows or is not ARM64 aligned')
        if reader.uleb() != 0:
            fail('Nonempty FDE augmentation is outside this subset')
        rows = program(reader,start,start+size,cies[cie_offset],budget)
        fdes[offset] = FDE(offset,cie_offset,start,start+size,rows)
    # Ordered interval sweep: flag every overlapping FDE without quadratic joins.
    overlapping = set()
    previous = None
    for fde in sorted(fdes.values(),key=lambda item:(item.start,item.end)):
        if previous and fde.start < previous.end:
            overlapping.update((previous.offset,fde.offset))
        if previous is None or fde.end > previous.end:
            previous = fde
    return CFITable(fdes,frozenset(overlapping))
