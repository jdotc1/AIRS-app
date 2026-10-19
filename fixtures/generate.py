#!/usr/bin/env python3
"""Generate small, deterministic Mach-O *data fixtures*, never executed.

These are purpose-built parser/model examples, not runnable signed applications
or reproductions of any third-party defect. Instruction words are independently
specified. Assertions belong in tests; this generator does not call the analyzer.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import struct
import uuid

BASE = 0x100000000
TEXT_OFFSET = 0x1000
NOP = 0xD503201F
RET = 0xD65F03C0
BL_EXTERNAL = 0x94000400


@dataclass(frozen=True)
class Example:
    name: str
    words: tuple[int, ...]
    encoding: int
    expected: str
    explanation: str


CANONICAL = Example("_canonical_frame", (0xA9BF7BFD, 0x910003FD, NOP, BL_EXTERNAL, 0xA8C17BFD, RET), 0x04000000, "agreement", "Canonical FP/LR frame checked at a direct call")
LEAF = Example("_frameless_leaf", (0xD10083FF, NOP, 0x910083FF, RET), 0x02002000, "agreement", "32-byte leaf stack; comparison is explicitly limited to the modeled body")
PAIR = Example("_pair_saved", (0xD10083FF, 0xA9004FF4, 0xA9017BFD, 0x910043FD, 0xD28000F3, BL_EXTERNAL, 0xA9417BFD, 0xA9404FF4, 0x910083FF, RET), 0x04000001, "agreement", "x19 saved at FP-8 and x20 at FP-16; x19 is modified before the call")
MISSING_PAIR = Example("_pair_rule_missing", PAIR.words, 0x04000000, "inconsistency", "Synthetic metadata omits the saved pair needed to recover original x19")
SHIFTED_FP = Example("_shifted_frame_record", (0xA9BE7BFD, 0x910003FD, NOP, BL_EXTERNAL, 0xA8C27BFD, RET), 0x04000000, "inconsistency", "Synthetic frame metadata reconstructs the wrong caller SP for this explicitly restored frame")
CONDITIONAL = Example("_conditional_flow", (0xA9BF7BFD, 0x910003FD, 0x54000040, BL_EXTERNAL, 0xA8C17BFD, RET), 0x04000000, "unresolved", "Conditional control flow is outside the linear model")
DWARF = Example("_dwarf_fallback", LEAF.words, 0x03000000, "unresolved", "DWARF reference is recorded but no FDE interpreter is implemented")
NO_RULE = Example("_no_rule", (NOP, RET), 0, "unresolved", "Zero encoding means no compact rule; it does not establish a defect")
PAC = Example("_pointer_auth", (0xD503237F, 0xA9BF7BFD, 0x910003FD, BL_EXTERNAL, 0xA8C17BFD, 0xD50323FF, RET), 0x04000000, "unresolved", "Pointer authentication instructions are recognized as unsupported scope")


def align(value: int, boundary: int) -> int:
    return (value + boundary - 1) & -boundary


def uleb(value: int) -> bytes:
    result = bytearray()
    while value >= 0x80:
        result.append((value & 0x7f) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def make_unwind(entries: list[tuple[int, int]], end: int, *, compressed: bool) -> bytes:
    encodings = list(dict.fromkeys(encoding for _, encoding in entries))
    common = encodings[:2] if compressed else []
    local = encodings[2:] if compressed else []
    common_offset = 28
    index_offset = common_offset + len(common) * 4
    page_offset = index_offset + 24
    section = bytearray(struct.pack("<7I", 1, common_offset, len(common), index_offset, 0, index_offset, 2))
    section.extend(b"".join(struct.pack("<I", e) for e in common))
    section.extend(struct.pack("<6I", entries[0][0], page_offset, 0, end, 0, 0))
    if compressed:
        local_offset = 12 + len(entries) * 4
        page = bytearray(struct.pack("<I4H", 3, 12, len(entries), local_offset, len(local)))
        for address, encoding in entries:
            page.extend(struct.pack("<I", (encodings.index(encoding) << 24) | (address - entries[0][0])))
        page.extend(b"".join(struct.pack("<I", e) for e in local))
    else:
        page = bytearray(struct.pack("<I2H", 2, 8, len(entries)))
        for address, encoding in entries:
            page.extend(struct.pack("<2I", address, encoding))
    section.extend(page)
    return bytes(section)


def build_image(examples: tuple[Example, ...], *, compressed: bool = False, subtype: int = 0, include_unwind: bool = True, include_starts: bool = True, include_symbols: bool = True) -> bytes:
    text = bytearray()
    entries, addresses = [], []
    for example in examples:
        address = TEXT_OFFSET + len(text)
        entries.append((address, example.encoding))
        addresses.append(address)
        text.extend(struct.pack("<" + "I" * len(example.words), *example.words))
    unwind = make_unwind(entries, TEXT_OFFSET + len(text), compressed=compressed) if include_unwind else b""
    unwind_offset = align(TEXT_OFFSET + len(text), 16)
    # A terminator-only eh_frame is intentionally not an FDE. The v0 engine must
    # not infer DWARF validity just from a section or referenced offset existing.
    eh_frame = b"\0\0\0\0" if any(e.encoding & 0x0f000000 == 0x03000000 for e in examples) else b""
    eh_offset = align(unwind_offset + len(unwind), 8)
    starts = b""
    previous = 0
    if include_starts:
        for address in addresses:
            starts += uleb(address - previous)
            previous = address
        starts += b"\0"
    starts_offset = align(eh_offset + len(eh_frame), 8)
    symbols_offset = align(starts_offset + len(starts), 8)
    strings = bytearray(b"\0")
    symbols = bytearray()
    if include_symbols:
        for example, address in zip(examples, addresses):
            symbols.extend(struct.pack("<IBBHQ", len(strings), 0x0f, 1, 0, BASE + address))
            strings.extend(example.name.encode("utf-8") + b"\0")
    strings_offset = symbols_offset + len(symbols)
    total_size = strings_offset + len(strings)
    section_defs = [("__text", TEXT_OFFSET, len(text), 0x80000400)]
    if include_unwind:
        section_defs.append(("__unwind_info", unwind_offset, len(unwind), 0))
    if eh_frame:
        section_defs.append(("__eh_frame", eh_offset, len(eh_frame), 0x6800000b))
    segment_size = 72 + 80 * len(section_defs)
    segment = bytearray(struct.pack("<II16sQQQQiiII", 0x19, segment_size, b"__TEXT", BASE, align(total_size, 0x4000), 0, total_size, 7, 5, len(section_defs), 0))
    for name, offset, size, flags in section_defs:
        segment.extend(struct.pack("<16s16sQQIIIIIIII", name.encode(), b"__TEXT", BASE + offset, size, offset, 2, 0, 0, flags, 0, 0, 0))
    identity_seed = hashlib.sha256(bytes(text) + unwind + struct.pack("<I", subtype)).hexdigest()
    identity = uuid.uuid5(uuid.NAMESPACE_URL, "airs.synthetic/" + identity_seed)
    commands = [bytes(segment), struct.pack("<II16s", 0x1b, 24, identity.bytes)]
    if include_starts:
        commands.append(struct.pack("<4I", 0x26, 16, starts_offset, len(starts)))
    if include_symbols:
        commands.append(struct.pack("<6I", 0x2, 24, symbols_offset, len(examples), strings_offset, len(strings)))
    command_bytes = b"".join(commands)
    header = struct.pack("<8I", 0xfeedfacf, 0x0100000c, subtype, 6, len(commands), len(command_bytes), 0, 0)
    assert len(header) + len(command_bytes) <= TEXT_OFFSET
    result = bytearray(total_size)
    result[:len(header)] = header
    result[len(header):len(header) + len(command_bytes)] = command_bytes
    for offset, payload in ((TEXT_OFFSET, text), (unwind_offset, unwind), (eh_offset, eh_frame), (starts_offset, starts), (symbols_offset, symbols), (strings_offset, strings)):
        result[offset:offset + len(payload)] = payload
    return bytes(result)


def make_fat(arm64: bytes, arm64e: bytes, *, is64: bool) -> bytes:
    offsets = (0x4000, align(0x4000 + len(arm64), 0x4000))
    result = bytearray(offsets[1] + len(arm64e))
    struct.pack_into(">II", result, 0, 0xcafebabf if is64 else 0xcafebabe, 2)
    cursor = 8
    # Put arm64e first to ensure auto selection doesn't simply choose entry zero.
    for subtype, offset, payload in ((2, offsets[1], arm64e), (0, offsets[0], arm64)):
        fmt = ">IIQQII" if is64 else ">IIIII"
        values = (0x0100000c, subtype, offset, len(payload), 14, 0) if is64 else (0x0100000c, subtype, offset, len(payload), 14)
        struct.pack_into(fmt, result, cursor, *values)
        cursor += struct.calcsize(fmt)
        result[offset:offset + len(payload)] = payload
    return bytes(result)


def generate(destination: Path) -> dict:
    destination.mkdir(parents=True, exist_ok=True)
    mixed = (CANONICAL, LEAF, PAIR, MISSING_PAIR, SHIFTED_FP, CONDITIONAL, DWARF, NO_RULE, PAC)
    before = (CANONICAL, LEAF, PAIR)
    after = (CANONICAL, Example(LEAF.name, LEAF.words, 0x02004000, "inconsistency", "Synthetic encoding claims 64 stack bytes where the body has 32"), Example(PAIR.name, PAIR.words, 0x04000000, "inconsistency", "Synthetic pair flag is missing"))
    arm64 = build_image(before)
    arm64e = build_image(before, subtype=2)
    payloads = {
        "mixed-regular.macho": build_image(mixed),
        "mixed-compressed.macho": build_image(mixed, compressed=True),
        "before.macho": arm64,
        "after.macho": build_image(after),
        "arm64e.macho": arm64e,
        "universal32.macho": make_fat(arm64, arm64e, is64=False),
        "universal64.macho": make_fat(arm64, arm64e, is64=True),
        "no-unwind.macho": build_image(before, include_unwind=False),
        "symbol-boundaries.macho": build_image(before, include_starts=False),
        "metadata-only.macho": build_image(before, include_starts=False, include_symbols=False),
    }
    manifest = {"purpose": "Synthetic, non-executed parser and analysis examples; not third-party bug reproductions", "files": {name: {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)} for name, data in payloads.items()}, "mixed_expectations": {e.name: {"verdict": e.expected, "explanation": e.explanation} for e in mixed}}
    for name, data in payloads.items():
        (destination / name).write_bytes(data)
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "generated")
    args = parser.parse_args()
    manifest = generate(args.output)
    print(f"Generated {len(manifest['files'])} synthetic data fixtures in {args.output}")
