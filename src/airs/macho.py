"""Bounded, read-only parsing of final little-endian ARM64 Mach-O images.

No input is loaded or executed. Only LC_FUNCTION_STARTS and executable-section
symbols establish candidate function boundaries. Unused load-command payloads
remain opaque, but their command extents and recognized link-edit extents are
validated. Format definitions: Apple's mach-o/loader.h and mach-o/fat.h.

InputError offsets within a selected Mach-O are slice-relative; errors in a FAT
directory use container-relative offsets. Independent hard ceilings bound FAT
directories (256 slices), symbols (one million), and decoded symbol names.
"""
from __future__ import annotations

import hashlib
import struct
import uuid as uuid_module
from bisect import bisect_right

from .types import FunctionRange, InputError, Issue, Limits, MachOImage, Section

_U64_LIMIT = 1 << 64
_CPU_ARM64 = 0x0100000C
_ZEROFILL_TYPES = frozenset((1, 0x0C, 0x12))
_MAX_FAT_SLICES = 256
_MAX_SYMBOLS = 1_000_000
_MAX_NAME_BYTES = 4096
_MAX_TOTAL_NAME_BYTES = 16 * 1024 * 1024
_LINKEDIT_DATA_COMMANDS = frozenset((0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E,
                                     0x80000033, 0x80000034, 0x36, 0x37, 0x38))


def _extent(offset: int, size: int, total: int, code: str, label: str) -> None:
    if offset < 0 or size < 0 or offset > total or size > total - offset:
        raise InputError(code, f"{label} extends outside the available bytes", offset)


def _vm_extent(address: int, size: int, code: str, offset: int) -> None:
    if address < 0 or size < 0 or address >= _U64_LIMIT or size > _U64_LIMIT - address:
        raise InputError(code, "The VM address range overflows 64 bits", offset)


def _architecture(cpu: int, subtype: int) -> str | None:
    if cpu != _CPU_ARM64:
        return None
    base_subtype = subtype & 0x00FFFFFF
    if base_subtype in (0, 1):
        return "arm64"
    if base_subtype == 2:
        return "arm64e"
    return None


def _check_nonoverlap(ranges: list[tuple[int, int, int]], code: str, label: str) -> None:
    previous_end = -1
    for start, end, source in sorted(ranges):
        if start < previous_end:
            raise InputError(code, f"{label} ranges overlap", source)
        previous_end = end


def _slice(data: bytes, requested_arch: str) -> tuple[bytes, int, tuple[int, int] | None]:
    magic = data[:4]
    layouts = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
               b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if magic not in layouts:
        return data, 0, None
    endian, fat64 = layouts[magic]
    _extent(0, 8, len(data), "truncated_fat_header", "FAT header")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    if count == 0:
        raise InputError("empty_fat_container", "The FAT container has no slices", 4)
    if count > _MAX_FAT_SLICES:
        raise InputError("fat_slice_limit", "The FAT slice count exceeds the parser limit", 4)
    record_size = 32 if fat64 else 20
    table_end = 8 + count * record_size
    _extent(8, count * record_size, len(data), "truncated_fat_directory", "FAT directory")
    candidates = []
    ranges = []
    identities: set[tuple[int, int]] = set()
    for index in range(count):
        record = 8 + index * record_size
        fields = struct.unpack_from(endian + ("IIQQII" if fat64 else "IIIII"), data, record)
        cpu, subtype, offset, size, align = fields[:5]
        if fat64 and fields[5] != 0:
            raise InputError("fat_reserved_field", "A FAT64 reserved field is nonzero", record + 28)
        if align > (63 if fat64 else 31):
            raise InputError("fat_alignment", "A FAT slice has an invalid alignment exponent", record)
        if offset % (1 << align):
            raise InputError("fat_alignment", "A FAT slice does not satisfy its alignment", record)
        if offset < table_end or size < 4:
            raise InputError("fat_slice_extent", "A FAT slice is empty or overlaps its directory", record)
        _extent(offset, size, len(data), "fat_slice_extent", "FAT slice")
        ranges.append((offset, offset + size, record))
        identity = (cpu, subtype)
        if identity in identities:
            raise InputError("duplicate_fat_architecture", "The FAT directory repeats an architecture", record)
        identities.add(identity)
        arch = _architecture(cpu, subtype)
        if arch is not None and requested_arch in ("auto", arch):
            preference = (0 if arch == "arm64" else 1, 0 if subtype & 0xFFFFFF == 0 else 1, index)
            candidates.append((preference, offset, size, identity))
    _check_nonoverlap(ranges, "overlapping_fat_slices", "FAT slice")
    if not candidates:
        raise InputError("architecture_unavailable", f"No supported {requested_arch} slice is available")
    _, offset, size, identity = min(candidates)
    return data[offset:offset + size], offset, identity


def _function_starts(data: bytes, offset: int, size: int, base: int,
                     executable: tuple[Section, ...], limits: Limits) -> list[int]:
    if size == 0:
        return []
    end = offset + size
    cursor = offset
    address = base
    starts = []
    section_starts = [section.address for section in executable]
    while cursor < end:
        value_offset = cursor
        value = 0
        for index in range(10):
            if cursor >= end:
                raise InputError("truncated_function_start_uleb", "An LC_FUNCTION_STARTS value is truncated", value_offset)
            byte = data[cursor]
            cursor += 1
            if index == 9 and byte & 0xFE:
                raise InputError("function_start_uleb_overflow", "An LC_FUNCTION_STARTS value exceeds 64 bits", value_offset)
            value |= (byte & 0x7F) << (7 * index)
            if not byte & 0x80:
                break
        else:
            raise InputError("function_start_uleb_overflow", "An LC_FUNCTION_STARTS value exceeds 64 bits", value_offset)
        if value == 0:
            if any(data[cursor:end]):
                raise InputError("function_starts_trailing_data", "Nonzero bytes follow the function-start terminator", cursor)
            return starts
        if value >= _U64_LIMIT - address:
            raise InputError("function_start_overflow", "A function-start address overflows 64 bits", value_offset)
        address += value
        if address % 4:
            raise InputError("unaligned_function_start", "An ARM64 function start is not instruction aligned", value_offset)
        section_index = bisect_right(section_starts, address) - 1
        if section_index < 0 or address >= executable[section_index].end:
            raise InputError("function_start_not_executable", "A function start lies outside executable sections", value_offset)
        starts.append(address)
        if len(starts) > limits.max_functions:
            raise InputError("function_limit", "The function count exceeds the configured limit", value_offset)
    raise InputError("unterminated_function_starts", "LC_FUNCTION_STARTS has no zero terminator", end)


def _symbol_names(data: bytes, command: tuple[int, int, int, int] | None,
                  sections: tuple[Section, ...], limits: Limits) -> dict[int, str]:
    if command is None:
        return {}
    symoff, count, stroff, strsize = command
    if count > _MAX_SYMBOLS:
        raise InputError("symbol_limit", "The symbol count exceeds the parser limit", symoff)
    names: dict[int, tuple[int, str]] = {}
    name_cache: dict[int, str] = {}
    total_name_bytes = 0
    for index in range(count):
        record = symoff + index * 16
        strx, kind, section_number, _, address = struct.unpack_from("<IBBHQ", data, record)
        if strx >= strsize and (strx != 0 or strsize != 0):
            raise InputError("symbol_string_offset", "A symbol name offset lies outside its string table", record)
        if kind & 0xE0 or kind & 0x0E != 0x0E:
            continue
        if not 1 <= section_number <= len(sections):
            raise InputError("symbol_section_index", "A defined symbol has an invalid section index", record + 5)
        section = sections[section_number - 1]
        if not section.address <= address <= section.end:
            raise InputError("symbol_address_extent", "A defined symbol lies outside its declared section", record + 8)
        if not section.executable or address == section.end or (section.flags & 0xFF) in _ZEROFILL_TYPES:
            continue
        if address % 4:
            # Executable sections may also contain local byte labels. They cannot
            # serve as candidate ARM64 function starts, but are not format errors.
            continue
        if strx == 0:
            continue
        if strx not in name_cache:
            begin = stroff + strx
            name_end = data.find(b"\0", begin, min(stroff + strsize, begin + _MAX_NAME_BYTES + 1))
            if name_end == -1:
                code = "symbol_name_limit" if stroff + strsize - begin > _MAX_NAME_BYTES else "unterminated_symbol_name"
                raise InputError(code, "A symbol name is unterminated or exceeds the name-size limit", begin)
            total_name_bytes += name_end - begin
            if total_name_bytes > _MAX_TOTAL_NAME_BYTES:
                raise InputError("symbol_name_budget", "Decoded symbol names exceed the parser budget", begin)
            name_cache[strx] = data[begin:name_end].decode("utf-8", errors="replace")
        name = name_cache[strx]
        if not name:
            continue
        candidate = (0 if kind & 1 else 1, name)
        if address not in names or candidate < names[address]:
            names[address] = candidate
        if len(names) > limits.max_functions:
            raise InputError("function_limit", "The executable symbol count exceeds the configured function limit", record)
    return {address: name for address, (_, name) in names.items()}


def parse_macho(data: bytes, path: str = "<memory>", limits: Limits = Limits(),
                requested_arch: str = "auto") -> MachOImage:
    """Parse a bounded supported slice and independent function boundaries."""
    if requested_arch not in ("auto", "arm64", "arm64e"):
        raise InputError("invalid_architecture_request", "Architecture must be auto, arm64, or arm64e")
    for name in ("max_file_bytes", "max_load_commands", "max_sections", "max_functions"):
        value = getattr(limits, name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise InputError("invalid_limits", f"{name} must be a positive integer")
    if not isinstance(data, bytes):
        raise InputError("invalid_input_bytes", "parse_macho requires immutable bytes")
    if len(data) > limits.max_file_bytes:
        raise InputError("file_size_limit", "The input exceeds the configured file-size limit")
    _extent(0, 4, len(data), "truncated_magic", "Mach-O magic")
    selected, slice_offset, advertised = _slice(data, requested_arch)
    if selected[:4] != b"\xcf\xfa\xed\xfe":
        if selected[:4] in (b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe"):
            raise InputError("unsupported_macho_format", "Only little-endian 64-bit Mach-O images are supported", 0)
        raise InputError("unrecognized_magic", "The selected input is not a supported Mach-O image", 0)
    _extent(0, 32, len(selected), "truncated_macho_header", "Mach-O64 header")
    _, cpu, subtype, filetype, ncmds, sizeofcmds, _, reserved = struct.unpack_from("<IIIIIIII", selected)
    if advertised is not None and (cpu, subtype) != advertised:
        raise InputError("slice_identity_mismatch", "The selected Mach-O header disagrees with its FAT architecture record", 4)
    architecture = _architecture(cpu, subtype)
    if architecture is None or requested_arch not in ("auto", architecture):
        raise InputError("architecture_unavailable", "The selected Mach-O architecture is unsupported or was not requested", 4)
    if filetype not in (2, 6, 8):
        raise InputError("unsupported_file_type", "Only final MH_EXECUTE, MH_DYLIB, and MH_BUNDLE images are supported", 12)
    if reserved:
        raise InputError("macho_reserved_field", "The Mach-O64 reserved header field is nonzero", 28)
    if ncmds > limits.max_load_commands:
        raise InputError("load_command_limit", "The load-command count exceeds the configured limit", 16)
    if sizeofcmds % 8 or sizeofcmds < ncmds * 8:
        raise InputError("load_command_size", "The load-command byte count is inconsistent or unaligned", 20)
    _extent(32, sizeofcmds, len(selected), "load_command_extent", "Load-command region")
    command_end = 32 + sizeofcmds
    cursor = 32
    sections: list[Section] = []
    segment_vm_ranges: list[tuple[int, int, int]] = []
    segment_file_ranges: list[tuple[int, int, int]] = []
    section_vm_ranges: list[tuple[int, int, int]] = []
    section_file_ranges: list[tuple[int, int, int]] = []
    section_keys: set[tuple[str, str]] = set()
    preferred_base = None
    function_command = None
    symbol_command = None
    dynamic_symbol_command = None
    image_uuid = None
    issues: list[Issue] = []
    embedded_data: list[tuple[int, int]] = []
    data_in_code_seen = False
    relocated_sections: set[tuple[str, str]] = set()
    if architecture == "arm64e":
        issues.append(Issue("arm64e_metadata_only", "ARM64e pointer-authentication semantics are outside this analysis model"))

    for _ in range(ncmds):
        _extent(cursor, 8, command_end, "truncated_load_command", "Load-command header")
        command, command_size = struct.unpack_from("<II", selected, cursor)
        if command_size < 8 or command_size % 8:
            raise InputError("load_command_size", "A Mach-O64 load command has an invalid size or alignment", cursor + 4)
        _extent(cursor, command_size, command_end, "load_command_extent", "Load command")

        def exact(size: int) -> None:
            if command_size != size:
                raise InputError("load_command_size", f"Load command {command:#x} requires {size} bytes", cursor + 4)

        def payload_extent(offset: int, size: int, label: str) -> None:
            _extent(offset, size, len(selected), "linkedit_extent", label)
            if size and offset < command_end:
                raise InputError("linkedit_header_overlap", f"{label} overlaps the Mach-O header or load commands", offset)

        if command == 0x19:
            if command_size < 72:
                raise InputError("segment_command_size", "LC_SEGMENT_64 is shorter than its fixed header", cursor)
            fields = struct.unpack_from("<II16sQQQQiiII", selected, cursor)
            segname_raw, vmaddr, vmsize, fileoff, filesize, _, initprot, nsects, segflags = fields[2:]
            segname = segname_raw.split(b"\0", 1)[0].decode("ascii", errors="replace")
            if nsects > limits.max_sections - len(sections):
                raise InputError("section_limit", "The section count exceeds the configured limit", cursor + 64)
            if command_size != 72 + nsects * 80:
                raise InputError("segment_command_size", "The section count does not match LC_SEGMENT_64 size", cursor)
            _vm_extent(vmaddr, vmsize, "segment_vm_overflow", cursor + 24)
            _extent(fileoff, filesize, len(selected), "segment_file_extent", "Segment")
            if filesize > vmsize:
                raise InputError("segment_mapping_extent", "A segment has more file bytes than VM space", cursor)
            if segflags & 1:
                raise InputError("unsupported_segment_mapping", "SG_HIGHVM segment mappings are outside the supported format", cursor)
            if vmsize:
                segment_vm_ranges.append((vmaddr, vmaddr + vmsize, cursor))
            if filesize:
                segment_file_ranges.append((fileoff, fileoff + filesize, cursor))
            if segname == "__TEXT":
                if preferred_base is not None:
                    raise InputError("duplicate_text_segment", "The image has more than one __TEXT segment", cursor)
                preferred_base = vmaddr
            for section_index in range(nsects):
                section_offset = cursor + 72 + section_index * 80
                fields = struct.unpack_from("<16s16sQQIIIIIIII", selected, section_offset)
                name_raw, declared_segment_raw, address, size, offset, align, reloff, nreloc, flags = fields[:9]
                name = name_raw.split(b"\0", 1)[0].decode("ascii", errors="replace")
                declared_segment = declared_segment_raw.split(b"\0", 1)[0].decode("ascii", errors="replace")
                if declared_segment != segname:
                    raise InputError("section_segment_mismatch", "A section names a different containing segment", section_offset + 16)
                if (segname, name) in section_keys:
                    raise InputError("duplicate_section", "The image repeats a segment/section name", section_offset)
                section_keys.add((segname, name))
                _vm_extent(address, size, "section_vm_overflow", section_offset + 32)
                if address < vmaddr or address + size > vmaddr + vmsize:
                    raise InputError("section_vm_extent", "A section lies outside its segment's VM range", section_offset + 32)
                if align > 63 or address % (1 << align):
                    raise InputError("section_alignment", "A section has an invalid VM alignment", section_offset + 52)
                section = Section(segname, name, address, size, offset, flags)
                zerofill = flags & 0xFF in _ZEROFILL_TYPES
                if section.executable and (zerofill or not initprot & 4):
                    raise InputError("unbacked_executable_section", "An executable section is zerofill or its segment is not executable", section_offset)
                if not zerofill:
                    _extent(offset, size, len(selected), "section_file_extent", "Section")
                    if offset < fileoff or offset + size > fileoff + filesize:
                        raise InputError("section_file_extent", "A section lies outside its segment's file range", section_offset + 48)
                    if address - vmaddr != offset - fileoff:
                        raise InputError("section_mapping_mismatch", "A section's VM and file offsets disagree with its segment", section_offset)
                    if offset % (1 << align):
                        raise InputError("section_alignment", "A section has an invalid file alignment", section_offset + 48)
                    if size and offset < command_end:
                        raise InputError("section_header_overlap", "A file-backed section overlaps the Mach-O header or load commands", section_offset)
                    if size:
                        section_file_ranges.append((offset, offset + size, section_offset))
                payload_extent(reloff, nreloc * 8, "Section relocation table")
                if nreloc and section.executable:
                    issues.append(Issue("executable_relocations_present", "Executable section relocations are not interpreted", section_offset))
                    relocated_sections.add((section.segment, section.name))
                if size:
                    section_vm_ranges.append((address, address + size, section_offset))
                sections.append(section)
        elif command == 0x1:
            raise InputError("unsupported_segment_command", "A Mach-O64 image contains a 32-bit segment command", cursor)
        elif command == 0x2:
            exact(24)
            if symbol_command is not None:
                raise InputError("duplicate_symtab", "The image has duplicate LC_SYMTAB commands", cursor)
            symbol_command = struct.unpack_from("<IIII", selected, cursor + 8)
            symoff, count, stroff, strsize = symbol_command
            if count > _MAX_SYMBOLS:
                raise InputError("symbol_limit", "The symbol count exceeds the parser limit", cursor + 12)
            payload_extent(symoff, count * 16, "Symbol table")
            payload_extent(stroff, strsize, "Symbol string table")
        elif command == 0xB:
            exact(80)
            if dynamic_symbol_command is not None:
                raise InputError("duplicate_dysymtab", "The image has duplicate LC_DYSYMTAB commands", cursor)
            dynamic_symbol_command = (cursor, struct.unpack_from("<18I", selected, cursor + 8))
            values = dynamic_symbol_command[1]
            for pair, record_size in ((6, 8), (8, 56), (10, 4), (12, 4), (14, 8), (16, 8)):
                payload_extent(values[pair], values[pair + 1] * record_size, "Dynamic symbol auxiliary table")
        elif command == 0x1B:
            exact(24)
            if image_uuid is not None:
                raise InputError("duplicate_uuid", "The image has duplicate LC_UUID commands", cursor)
            image_uuid = str(uuid_module.UUID(bytes=selected[cursor + 8:cursor + 24]))
        elif command in _LINKEDIT_DATA_COMMANDS:
            exact(16)
            offset, size = struct.unpack_from("<II", selected, cursor + 8)
            payload_extent(offset, size, "Link-edit data")
            if command == 0x26:
                if function_command is not None:
                    raise InputError("duplicate_function_starts", "The image has duplicate LC_FUNCTION_STARTS commands", cursor)
                function_command = (offset, size)
            elif command == 0x29:
                if data_in_code_seen:
                    raise InputError("duplicate_data_in_code", "The image has duplicate LC_DATA_IN_CODE commands", cursor)
                data_in_code_seen = True
                if size % 8:
                    raise InputError("data_in_code_size", "LC_DATA_IN_CODE is not a complete array of records", offset)
                if size // 8 > limits.max_functions:
                    raise InputError("data_in_code_limit", "The data-in-code record count exceeds the configured limit", offset)
                for record in range(offset, offset + size, 8):
                    data_offset, data_size, _ = struct.unpack_from("<IHH", selected, record)
                    payload_extent(data_offset, data_size, "Embedded code data")
                    if data_size:
                        embedded_data.append((data_offset, data_offset + data_size))
        elif command in (0x22, 0x80000022):
            exact(48)
            values = struct.unpack_from("<10I", selected, cursor + 8)
            for index in range(0, 10, 2):
                payload_extent(values[index], values[index + 1], "Dyld information")
        elif command == 0x21:
            # A legacy encryption declaration must not fall through as opaque
            # metadata, even when padded to the Mach-O64 command alignment.
            raise InputError("unsupported_encryption_command", "LC_ENCRYPTION_INFO is outside the supported 64-bit format", cursor)
        elif command == 0x2C:
            exact(24)
            cryptoff, cryptsize, cryptid, _ = struct.unpack_from("<IIII", selected, cursor + 8)
            payload_extent(cryptoff, cryptsize, "Encryption range")
            if cryptid:
                raise InputError("encrypted_image", "Encrypted image bytes cannot be analyzed as instructions", cursor)
        elif command == 0x31:
            exact(40)
            offset, size = struct.unpack_from("<QQ", selected, cursor + 24)
            payload_extent(offset, size, "LC_NOTE data")
        elif command == 0x32:
            if command_size < 24:
                raise InputError("load_command_size", "LC_BUILD_VERSION is truncated", cursor)
            tool_count = struct.unpack_from("<I", selected, cursor + 20)[0]
            if tool_count > limits.max_load_commands or command_size != 24 + tool_count * 8:
                raise InputError("build_tool_count", "LC_BUILD_VERSION tool count disagrees with its extent", cursor + 20)
        cursor += command_size

    if cursor != command_end:
        raise InputError("load_command_count_mismatch", "The load commands do not fill sizeofcmds exactly", cursor)
    if preferred_base is None:
        raise InputError("missing_text_segment", "The image has no __TEXT segment for its preferred address base")
    for ranges, code, label in ((segment_vm_ranges, "overlapping_segments", "Segment VM"),
                                (segment_file_ranges, "overlapping_segments", "Segment file"),
                                (section_vm_ranges, "overlapping_sections", "Section VM"),
                                (section_file_ranges, "overlapping_sections", "Section file")):
        _check_nonoverlap(ranges, code, label)
    if dynamic_symbol_command is not None:
        location, values = dynamic_symbol_command
        if symbol_command is None:
            raise InputError("dysymtab_without_symtab", "LC_DYSYMTAB has no matching LC_SYMTAB", location)
        symbol_count = symbol_command[1]
        for index in range(0, 6, 2):
            if values[index] > symbol_count or values[index + 1] > symbol_count - values[index]:
                raise InputError("dysymtab_symbol_extent", "LC_DYSYMTAB names symbols outside LC_SYMTAB", location + 8 + index * 4)
    all_sections = tuple(sections)
    executable = tuple(sorted((section for section in sections if section.executable and section.size), key=lambda s: s.address))
    if not executable:
        issues.append(Issue("no_executable_sections", "No nonempty executable section is available"))
    names = _symbol_names(selected, symbol_command, all_sections, limits)
    starts = _function_starts(selected, *function_command, preferred_base, executable, limits) if function_command else []
    if starts:
        source = "lc_function_starts"
    else:
        issues.append(Issue("missing_function_starts" if function_command is None else "empty_function_starts",
                            "LC_FUNCTION_STARTS is absent or contains no function starts"))
        starts = sorted(names)
        source = "symbol_table"
        if starts:
            issues.append(Issue("symbol_boundary_fallback", "Executable symbols provide weaker candidate boundaries; local labels and omitted symbols may make function extents incomplete"))
    affected_sections: set[tuple[str, str]] = set()
    executable_by_file = tuple(sorted(executable, key=lambda item: item.file_offset))
    executable_file_offsets = [item.file_offset for item in executable_by_file]
    for begin, end in embedded_data:
        file_index = bisect_right(executable_file_offsets, begin) - 1
        if (file_index < 0
                or end > executable_by_file[file_index].file_offset + executable_by_file[file_index].size):
            raise InputError("data_in_code_not_executable", "An embedded-data range is outside executable sections", begin)
        containing = executable_by_file[file_index]
        affected_sections.add((containing.segment, containing.name))
    if embedded_data:
        issues.append(Issue("data_in_code_present", "Executable sections contain embedded data; affected function extents require metadata-only analysis", embedded_data[0][0]))
    section_addresses = [section.address for section in executable]
    functions = []
    for index, address in enumerate(starts):
        section = executable[bisect_right(section_addresses, address) - 1]
        end = section.end
        if index + 1 < len(starts) and starts[index + 1] < end:
            end = starts[index + 1]
        boundary_source = source + ("_with_embedded_data" if (section.segment, section.name) in affected_sections else "")
        if (section.segment, section.name) in relocated_sections:
            boundary_source += "_with_relocations"
        functions.append(FunctionRange(address, end, names.get(address, f"sub_{address:x}"), boundary_source))
    if not functions:
        issues.append(Issue("no_function_boundaries", "No independent function boundaries are available; compact ranges do not establish them"))
    container_digest = hashlib.sha256(data).hexdigest()
    return MachOImage(selected, path, container_digest,
                      container_digest if slice_offset == 0 and len(selected) == len(data) else hashlib.sha256(selected).hexdigest(),
                      slice_offset, len(selected), architecture, subtype, image_uuid, preferred_base,
                      filetype, all_sections, tuple(functions), tuple(issues))
