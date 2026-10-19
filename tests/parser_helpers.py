"""Small independently assembled inputs for parser tests; no inspected binaries.

Offsets supplied to unwind helpers are image-relative, whereas function_offsets
and symbol offsets supplied to build_macho are relative to its __text section.
The helpers deliberately use literal layouts rather than production parser code.
"""
from __future__ import annotations

import struct


def _uleb(value: int) -> bytes:
    result = bytearray()
    while value >= 0x80:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def build_macho(
    text: bytes = b"\xc0\x03\x5f\xd6",
    *,
    function_offsets: tuple[int, ...] | None = (0,),
    unwind_info: bytes | None = None,
    symbols: tuple[tuple[str, int], ...] = (),
    cpusubtype: int = 0,
    cputype: int = 0x0100000C,
    filetype: int = 2,
    base: int = 0x100000000,
    text_offset: int = 0x1000,
    extra_commands: tuple[bytes, ...] = (),
    include_uuid: bool = True,
) -> bytes:
    sections = [(b"__text", text_offset, text, 0x80000400)]
    payload = bytearray(text_offset)
    payload.extend(text)
    if unwind_info is not None:
        payload.extend(bytes((-len(payload)) % 4))
        sections.append((b"__unwind_info", len(payload), unwind_info, 0))
        payload.extend(unwind_info)
    commands = []
    if function_offsets is not None:
        payload.extend(bytes((-len(payload)) % 4))
        position = len(payload)
        previous = 0
        for relative in function_offsets:
            current = text_offset + relative
            payload.extend(_uleb(current - previous))
            previous = current
        payload.append(0)
        commands.append(struct.pack("<IIII", 0x26, 16, position, len(payload) - position))
    if symbols:
        payload.extend(bytes((-len(payload)) % 8))
        symoff = len(payload)
        strings = bytearray(b"\0")
        for name, relative in symbols:
            name_offset = len(strings)
            strings.extend(name.encode("utf-8") + b"\0")
            payload.extend(struct.pack("<IBBHQ", name_offset, 0x0F, 1, 0, base + text_offset + relative))
        stroff = len(payload)
        payload.extend(strings)
        commands.append(struct.pack("<IIIIII", 2, 24, symoff, len(symbols), stroff, len(strings)))
    if include_uuid:
        commands.append(struct.pack("<II", 0x1B, 24) + bytes(range(16)))
    commands.extend(extra_commands)
    segment_size = 72 + 80 * len(sections)
    segment = bytearray(struct.pack(
        "<II16sQQQQiiII", 0x19, segment_size, b"__TEXT", base,
        (len(payload) + 4095) & ~4095, 0, len(payload), 7, 5, len(sections), 0,
    ))
    for name, offset, content, flags in sections:
        segment.extend(struct.pack(
            "<16s16sQQIIIIIIII", name, b"__TEXT", base + offset,
            len(content), offset, 2, 0, 0, flags, 0, 0, 0,
        ))
    command_bytes = bytes(segment) + b"".join(commands)
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, cputype, cpusubtype, filetype,
                         1 + len(commands), len(command_bytes), 0, 0)
    if len(header) + len(command_bytes) > text_offset:
        raise ValueError("The synthetic header overlaps its __text section")
    payload[:len(header) + len(command_bytes)] = header + command_bytes
    return bytes(payload)


def build_fat(slices: tuple[bytes, ...], *, is64: bool = False, little: bool = False) -> bytes:
    endian = "<" if little else ">"
    entry_size = 32 if is64 else 20
    header = bytearray(struct.pack(endian + "II", 0xCAFEBABF if is64 else 0xCAFEBABE, len(slices)))
    payload = bytearray((8 + entry_size * len(slices) + 4095) & ~4095)
    for member in slices:
        payload.extend(bytes((-len(payload)) % 4096))
        offset = len(payload)
        cpu, subtype = struct.unpack_from("<II", member, 4)
        fields = (cpu, subtype, offset, len(member), 12)
        header.extend(struct.pack(endian + ("IIQQII" if is64 else "IIIII"),
                                  *(fields + (0,) if is64 else fields)))
        payload.extend(member)
    payload[:len(header)] = header
    return bytes(payload)


def regular_unwind(entries: tuple[tuple[int, int], ...], end: int, *,
                   personalities: tuple[int, ...] = ()) -> bytes:
    personality_offset = 28 if personalities else 0
    index_offset = 28 + 4 * len(personalities)
    index_count = 2 if entries else 1
    page_offset = index_offset + index_count * 12
    header = struct.pack("<IIIIIII", 1, 0, 0, personality_offset, len(personalities),
                         index_offset, index_count)
    payload = bytearray(header + b"".join(struct.pack("<I", p) for p in personalities))
    if entries:
        payload.extend(struct.pack("<III", entries[0][0], page_offset, 0))
    payload.extend(struct.pack("<III", end, 0, 0))
    if entries:
        payload.extend(struct.pack("<IHH", 2, 8, len(entries)))
        payload.extend(b"".join(struct.pack("<II", *e) for e in entries))
    return bytes(payload)


def compressed_unwind(entries: tuple[tuple[int, int], ...], end: int, *,
                      common: tuple[int, ...] = (), local: tuple[int, ...] = ()) -> bytes:
    if not entries:
        raise ValueError("Use regular_unwind for an empty synthetic table")
    common_offset = 28 if common else 0
    index_offset = 28 + 4 * len(common)
    page_offset = index_offset + 24
    first = entries[0][0]
    payload = bytearray(struct.pack("<IIIIIII", 1, common_offset, len(common), 0, 0,
                                    index_offset, 2))
    payload.extend(b"".join(struct.pack("<I", encoding) for encoding in common))
    payload.extend(struct.pack("<IIIIII", first, page_offset, 0, end, 0, 0))
    payload.extend(struct.pack("<IHHHH", 3, 12, len(entries), 12 + 4 * len(entries), len(local)))
    payload.extend(b"".join(struct.pack("<I", (index << 24) | (address - first))
                            for address, index in entries))
    payload.extend(b"".join(struct.pack("<I", encoding) for encoding in local))
    return bytes(payload)
