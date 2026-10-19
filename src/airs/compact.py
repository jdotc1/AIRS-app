"""Read final ARM64 __unwind_info metadata with bounded structural checks.

The two-level layouts and encodings follow LLVM libunwind's public
mach-o/compact_unwind_encoding.h. Table ranges are independent of functions.
This parser records DWARF references; the separate bounded CFI layer evaluates them.
Personality, LSDA, and ARM64e/PAC semantics are not interpreted.
Source and issue offsets are relative to the selected Mach-O slice.
"""
from __future__ import annotations

import struct
from bisect import bisect_right

from .types import InputError, Issue, Limits, MachOImage, UnwindEntry, UnwindTable

_MODE_MASK = 0x0F000000
_FRAMELESS = 0x02000000
_DWARF = 0x03000000
_FRAME = 0x04000000
_PAUTH_FRAME = 0x05000000
_PAGE_BYTES = 4096
_U64_LIMIT = 1 << 64


def parse_compact_unwind(image: MachOImage, limits: Limits = Limits()) -> UnwindTable:
    """Return ordered preferred-VM metadata ranges, including zero encodings."""
    if (not isinstance(limits.max_unwind_entries, int) or isinstance(limits.max_unwind_entries, bool)
            or limits.max_unwind_entries < 1):
        raise InputError("invalid_limits", "max_unwind_entries must be a positive integer")
    section = image.section("__TEXT", "__unwind_info")
    if section is None or section.size == 0:
        return UnwindTable((), (Issue("missing_compact_unwind", "No nonempty __TEXT,__unwind_info section is available"),))
    origin = section.file_offset
    if section.flags & 0xFF in (1, 0x0C, 0x12):
        raise InputError("unwind_section_not_file_backed", "The compact-unwind section is zerofill", origin)
    if origin < 0 or section.size < 0 or origin > len(image.data) or section.size > len(image.data) - origin:
        raise InputError("unwind_section_extent", "The compact-unwind section extends outside the selected slice", origin)
    data = memoryview(image.data)[origin:origin + section.size]
    claims: list[tuple[int, int, str]] = []
    issues: list[Issue] = []
    issue_codes: set[str] = set()

    def fail(code: str, message: str, offset: int) -> None:
        raise InputError(code, message, origin + offset)

    def extent(offset: int, size: int, label: str) -> None:
        if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
            fail("unwind_extent", f"{label} extends outside __unwind_info", offset)

    def claim(offset: int, size: int, label: str, *, minimum: int = 28) -> None:
        extent(offset, size, label)
        if size:
            if offset < minimum or offset % 4:
                fail("unwind_array_offset", f"{label} has an invalid offset or alignment", offset)
            claims.append((offset, offset + size, label))

    def issue(code: str, message: str, offset: int | None = None) -> None:
        if code not in issue_codes:
            issues.append(Issue(code, message, None if offset is None else origin + offset))
            issue_codes.add(code)

    def address(function_offset: int, source: int) -> int:
        result = image.preferred_base + function_offset
        if image.preferred_base < 0 or result < 0 or result >= _U64_LIMIT:
            fail("unwind_address_overflow", "An image-relative metadata address overflows 64 bits", source)
        return result

    extent(0, 28, "Compact-unwind header")
    version, common_offset, common_count, personality_offset, personality_count, index_offset, index_count = struct.unpack_from("<7I", data)
    if version != 1:
        fail("unsupported_unwind_version", f"Compact-unwind version {version} is unsupported", 0)
    if common_count > 256:
        fail("unwind_encoding_limit", "Common encodings exceed the eight-bit index space", 8)
    if personality_count > 3:
        fail("unwind_personality_limit", "Personality entries exceed the two-bit nonzero index space", 16)
    if index_count > limits.max_unwind_entries + 1:
        fail("unwind_entry_limit", "The first-level index exceeds the configured entry limit", 24)
    claim(common_offset, common_count * 4, "Common encoding array")
    claim(personality_offset, personality_count * 4, "Personality array")
    claim(index_offset, index_count * 12, "First-level index")
    common = tuple(struct.unpack_from("<I", data, common_offset + index * 4)[0] for index in range(common_count))
    for index in range(personality_count):
        address(struct.unpack_from("<I", data, personality_offset + index * 4)[0], personality_offset + index * 4)
    if personality_count:
        issue("exception_metadata_only", "Personality and LSDA exception-handling semantics are not interpreted", personality_offset)
    indices = tuple(struct.unpack_from("<III", data, index_offset + index * 12) for index in range(index_count))
    if indices:
        if indices[-1][1] != 0:
            fail("unwind_sentinel", "The final first-level index entry must be a sentinel with no second-level page", index_offset + (index_count - 1) * 12 + 4)
        previous_offset = -1
        previous_lsda = -1
        for index, (function_offset, page_offset, lsda_offset) in enumerate(indices):
            location = index_offset + index * 12
            if function_offset <= previous_offset:
                fail("unwind_index_order", "First-level function offsets are not strictly increasing", location)
            if address(function_offset, location) % 4 and index < index_count - 1:
                fail("unwind_address_alignment", "A compact-unwind index address is not instruction aligned", location)
            if index < index_count - 1 and page_offset == 0:
                fail("unwind_missing_page", "A non-sentinel index entry has no second-level page", location + 4)
            if lsda_offset % 4 or lsda_offset < previous_lsda:
                fail("unwind_lsda_order", "LSDA index offsets are unaligned or decrease", location + 8)
            extent(lsda_offset, 0, "LSDA index boundary")
            previous_offset, previous_lsda = function_offset, lsda_offset

    raw_entries: list[tuple[int, int, int]] = []
    lsda_count = 0
    for index in range(max(0, index_count - 1)):
        function_low, page_offset, lsda_low = indices[index]
        function_high, _, lsda_high = indices[index + 1]
        if (lsda_high - lsda_low) % 8:
            fail("unwind_lsda_size", "An LSDA index range contains a partial record", lsda_low)
        count = (lsda_high - lsda_low) // 8
        lsda_count += count
        if lsda_count > limits.max_unwind_entries:
            fail("unwind_entry_limit", "LSDA records exceed the configured entry limit", lsda_low)
        claim(lsda_low, lsda_high - lsda_low, "LSDA index array")
        previous_lsda_function = -1
        for record in range(lsda_low, lsda_high, 8):
            lsda_function, lsda_reference = struct.unpack_from("<II", data, record)
            if not function_low <= lsda_function < function_high or lsda_function <= previous_lsda_function:
                fail("unwind_lsda_function_range", "An LSDA record has an unordered or out-of-range function offset", record)
            address(lsda_reference, record + 4)
            previous_lsda_function = lsda_function
        if count:
            issue("exception_metadata_only", "Personality and LSDA exception-handling semantics are not interpreted", lsda_low)
        claim(page_offset, 4, "Second-level page kind")
        kind = struct.unpack_from("<I", data, page_offset)[0]
        # Replace the provisional kind claim with the complete recognized header.
        claims.pop()
        if kind == 2:
            header_size, stride = 8, 8
            extent(page_offset, header_size, "Regular second-level header")
            _, entry_offset, entry_count = struct.unpack_from("<IHH", data, page_offset)
            encoding_offset = encoding_count = 0
            local: tuple[int, ...] = ()
        elif kind == 3:
            header_size, stride = 12, 4
            extent(page_offset, header_size, "Compressed second-level header")
            _, entry_offset, entry_count, encoding_offset, encoding_count = struct.unpack_from("<IHHHH", data, page_offset)
            if common_count + encoding_count > 256:
                fail("unwind_encoding_limit", "Shared and local encodings exceed the eight-bit index space", page_offset + 10)
            local = ()
        else:
            fail("unsupported_unwind_page_kind", f"Second-level page kind {kind} is unsupported", page_offset)
        claim(page_offset, header_size, "Second-level page header")
        if entry_count == 0:
            fail("unwind_empty_page", "A non-sentinel second-level page has no entries", page_offset + 6)
        if entry_count > limits.max_unwind_entries - len(raw_entries):
            fail("unwind_entry_limit", "Compact-unwind entries exceed the configured limit", page_offset + 6)
        if entry_offset < header_size or entry_offset + entry_count * stride > _PAGE_BYTES:
            fail("unwind_page_extent", "Second-level entries exceed their 4096-byte page or overlap its header", page_offset + 4)
        claim(page_offset + entry_offset, entry_count * stride, "Second-level entry array", minimum=page_offset + header_size)
        if kind == 3:
            if encoding_count:
                if encoding_offset < header_size or encoding_offset + encoding_count * 4 > _PAGE_BYTES:
                    fail("unwind_page_extent", "Local encodings exceed their 4096-byte page or overlap its header", page_offset + 8)
                claim(page_offset + encoding_offset, encoding_count * 4, "Local encoding array", minimum=page_offset + header_size)
                local = tuple(struct.unpack_from("<I", data, page_offset + encoding_offset + item * 4)[0] for item in range(encoding_count))
            else:
                # Empty-array offsets may be zero, but must still be bounded.
                if encoding_offset > _PAGE_BYTES:
                    fail("unwind_page_extent", "An empty local-encoding offset exceeds its page", page_offset + 8)
                extent(page_offset + encoding_offset, 0, "Empty local encoding array")
        previous_entry = -1
        for item in range(entry_count):
            location = page_offset + entry_offset + item * stride
            if kind == 2:
                function_offset, encoding = struct.unpack_from("<II", data, location)
            else:
                word = struct.unpack_from("<I", data, location)[0]
                function_offset = function_low + (word & 0xFFFFFF)
                encoding_index = word >> 24
                if encoding_index < common_count:
                    encoding = common[encoding_index]
                elif encoding_index - common_count < len(local):
                    encoding = local[encoding_index - common_count]
                else:
                    fail("unwind_encoding_index", "A compressed entry references an absent encoding", location)
            if item == 0 and function_offset != function_low:
                fail("unwind_page_first_entry", "A page's first entry disagrees with its first-level index", location)
            if not function_low <= function_offset < function_high or function_offset <= previous_entry:
                fail("unwind_entry_order", "Second-level function offsets are unordered or outside their first-level range", location)
            if address(function_offset, location) % 4:
                fail("unwind_address_alignment", "A metadata range is not ARM64 instruction aligned", location)
            if (encoding >> 28) & 3 > personality_count:
                fail("unwind_personality_index", "An encoding references an absent personality entry", location)
            raw_entries.append((function_offset, encoding, location))
            previous_entry = function_offset

    previous_end = 28
    for begin, end, label in sorted(claims):
        if begin < previous_end:
            fail("unwind_overlapping_tables", f"{label} overlaps another structural table", begin)
        previous_end = end
    if not raw_entries:
        issue("empty_compact_unwind", "The compact-unwind section contains no metadata ranges")
        return UnwindTable((), tuple(issues))
    executable = tuple(sorted((item for item in image.sections if item.executable and item.size), key=lambda item: item.address))
    if not executable:
        fail("unwind_without_executable_sections", "Compact-unwind ranges have no executable section", raw_entries[0][2])
    section_starts = [item.address for item in executable]
    minimum_address = executable[0].address
    maximum_address = max(item.end for item in executable)
    sentinel = address(indices[-1][0], index_offset + (index_count - 1) * 12)
    # Apple ld can emit a terminal boundary one byte beyond __text.
    # It is metadata, not an instruction start; retain its exact value.
    if not minimum_address < sentinel or sentinel - 1 > maximum_address:
        fail("unwind_sentinel_range", "The final sentinel lies outside the executable-section address envelope", index_offset + (index_count - 1) * 12)
    entries = []
    eh_frame = image.section("__TEXT", "__eh_frame")
    for index, (relative, encoding, location) in enumerate(raw_entries):
        start = address(relative, location)
        end = address(raw_entries[index + 1][0], raw_entries[index + 1][2]) if index + 1 < len(raw_entries) else sentinel
        if start >= end or not minimum_address <= start < maximum_address:
            fail("unwind_function_range", "A compact-unwind range is empty or outside executable addresses", location)
        executable_index = bisect_right(section_starts, start) - 1
        if encoding and (executable_index < 0 or start >= executable[executable_index].end):
            fail("unwind_function_range", "A nonzero compact rule starts outside executable sections", location)
        entries.append(UnwindEntry(start, end, encoding, origin + location))
        mode = encoding & _MODE_MASK
        if encoding == 0:
            issue("no_unwind_rule_ranges", "Zero-encoding ranges have no compact unwind rule", location)
        elif mode == _DWARF:
            issue("dwarf_metadata_only", "This metadata parser records an FDE reference; see the finding for bounded CFI evaluation status", location)
            dwarf_offset = encoding & 0xFFFFFF
            if eh_frame is None or dwarf_offset >= eh_frame.size:
                issue("dwarf_reference_unavailable", "A referenced DWARF FDE is unavailable within __TEXT,__eh_frame", location)
        elif mode == _PAUTH_FRAME:
            issue("pauth_metadata_only", "Authenticated-LR frame mode has separate pointer-authentication semantics that are not checked", location)
        elif mode not in (_FRAME, _FRAMELESS):
            issue("unknown_unwind_mode", "An unknown compact-unwind mode is retained without semantic interpretation", location)
        if encoding & 0x70000000:
            issue("exception_metadata_only", "Personality and LSDA exception-handling semantics are not interpreted", location)
    return UnwindTable(tuple(entries), tuple(issues))
