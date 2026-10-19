"""Shared internal contracts. Addresses are preferred (unslid) VM addresses.

Only report serialization converts addresses to hexadecimal strings. File offsets
on Section are relative to the selected Mach-O slice, never the FAT container.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Limits:
    max_file_bytes: int = 512 * 1024 * 1024
    max_load_commands: int = 4096
    max_sections: int = 4096
    max_functions: int = 50_000
    max_unwind_entries: int = 200_000
    max_instructions_per_function: int = 16_384
    max_total_instructions: int = 1_000_000
    max_observations_per_function: int = 256
    max_evidence_per_function: int = 32
    max_total_evidence: int = 8192
    max_cfi_bytes: int = 8 * 1024 * 1024
    max_cfi_records: int = 4096
    max_cfi_instructions: int = 200_000
    max_cfi_rows: int = 50_000
    max_cfg_steps_per_function: int = 4096
    max_cfg_paths_per_function: int = 64
    max_total_cfg_steps: int = 100_000

    def __post_init__(self) -> None:
        if any(type(value) is not int or value < 0 for value in self.__dict__.values()):
            raise InputError("invalid_limits", "Every resource limit must be a nonnegative integer")


class InputError(ValueError):
    """Expected input/format/limit error, with a stable machine-readable code."""

    def __init__(self, code: str, message: str, offset: int | None = None):
        super().__init__(message)
        self.code = code
        self.offset = offset


@dataclass(frozen=True)
class Issue:
    code: str
    message: str
    offset: int | None = None


@dataclass(frozen=True)
class Section:
    segment: str
    name: str
    address: int
    size: int
    file_offset: int
    flags: int = 0

    @property
    def end(self) -> int:
        return self.address + self.size

    @property
    def executable(self) -> bool:
        return self.name == "__text" or bool(self.flags & 0x80000400)


@dataclass(frozen=True)
class FunctionRange:
    start: int
    end: int
    name: str
    boundary_source: str

    @property
    def size(self) -> int:
        return self.end - self.start


@dataclass(frozen=True)
class MachOImage:
    data: bytes = field(repr=False)
    path: str
    container_sha256: str
    slice_sha256: str
    slice_offset: int
    slice_size: int
    architecture: str
    cpu_subtype: int
    uuid: str | None
    preferred_base: int
    file_type: int
    sections: tuple[Section, ...]
    functions: tuple[FunctionRange, ...]
    issues: tuple[Issue, ...] = ()

    def section(self, segment: str, name: str) -> Section | None:
        return next((s for s in self.sections if s.segment == segment and s.name == name), None)

    def bytes_at(self, address: int, size: int) -> bytes:
        if size < 0:
            raise InputError("negative_size", "A byte request has a negative size")
        for section in self.sections:
            if section.address <= address and address + size <= section.end:
                if (section.flags & 0xff) in (0x1, 0xC, 0x12):
                    raise InputError("unmapped_bytes", "The requested section is zero filled, not file backed")
                offset = section.file_offset + address - section.address
                if offset < 0 or offset + size > len(self.data):
                    raise InputError("unmapped_bytes", "The requested VM range is not file backed", offset)
                return self.data[offset:offset + size]
        raise InputError("unmapped_address", f"No section contains VM range {address:#x}+{size:#x}")


@dataclass(frozen=True)
class UnwindEntry:
    start: int
    end: int
    encoding: int
    source_offset: int


@dataclass(frozen=True)
class UnwindTable:
    entries: tuple[UnwindEntry, ...]
    issues: tuple[Issue, ...] = ()


@dataclass(frozen=True)
class Evidence:
    code: str
    message: str
    address: int | None = None
    expected: str | None = None
    observed: str | None = None


@dataclass(frozen=True)
class AuditResult:
    verdict: str  # agreement | inconsistency | unresolved
    coverage: str  # compact | dwarf_reference | dwarf_evaluated | none | unavailable
    mode: str  # frame | frameless | dwarf | pauth_frame | none | unknown
    scope: str  # synchronous_call_sites | modeled_leaf_body | metadata_only
    reason_codes: tuple[str, ...]
    checked_pcs: tuple[int, ...] = ()
    evidence: tuple[Evidence, ...] = ()
    limitations: tuple[str, ...] = ()
    instruction_count: int = 0
    cfg_steps: int = 0
