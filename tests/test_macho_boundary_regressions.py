"""Bounded encryption-command dispatch cases using synthetic byte images."""
from __future__ import annotations

import struct
import unittest

from parser_helpers import build_fat, build_macho
from airs.macho import parse_macho
from airs.types import InputError


def legacy_encryption_image(cryptid: int) -> bytes:
    # The legacy structure has five fields. Add explicit alignment padding to
    # reach the generic Mach-O64 command boundary; this must not make its
    # encryption declaration opaque to the reader.
    command = struct.pack("<6I", 0x21, 24, 0x1000, 4, cryptid, 0)
    return build_macho(extra_commands=(command,))


def legacy_command_offset(data: bytes) -> int:
    cursor = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, cursor)
        if command == 0x21:
            return cursor
        cursor += size
    raise AssertionError("Synthetic image has no legacy encryption command")


class MachOBoundaryRegressionTests(unittest.TestCase):
    def assert_legacy_refused(self, data: bytes, expected_offset: int) -> None:
        with self.assertRaises(InputError) as caught:
            parse_macho(data)
        self.assertEqual(caught.exception.code, "unsupported_encryption_command")
        self.assertEqual(caught.exception.offset, expected_offset)

    def test_legacy_encrypted_command_cannot_produce_function_candidates(self):
        data = legacy_encryption_image(1)
        self.assert_legacy_refused(data, legacy_command_offset(data))

    def test_legacy_clear_command_remains_outside_supported_format(self):
        data = legacy_encryption_image(0)
        self.assert_legacy_refused(data, legacy_command_offset(data))

    def test_fat_legacy_command_error_stays_slice_relative(self):
        selected = legacy_encryption_image(1)
        expected_offset = legacy_command_offset(selected)
        for fat64 in (False, True):
            with self.subTest(fat64=fat64):
                data = build_fat((build_macho(cputype=0x01000007), selected),
                                 is64=fat64)
                self.assert_legacy_refused(data, expected_offset)

    def test_64_bit_clear_encryption_command_preserves_vm_and_file_mapping(self):
        text = bytes.fromhex("1f2003d5c0035fd6")
        command = struct.pack("<6I", 0x2C, 24, 0x1000, len(text), 0, 0)
        image = parse_macho(build_macho(text, extra_commands=(command,)))
        section = image.section("__TEXT", "__text")
        self.assertEqual(section.file_offset, 0x1000)
        self.assertEqual(section.address, 0x100001000)
        self.assertEqual(image.bytes_at(section.address, len(text)), text)
        self.assertEqual([(item.start, item.end, item.boundary_source)
                          for item in image.functions],
                         [(0x100001000, 0x100001008, "lc_function_starts")])


if __name__ == "__main__":
    unittest.main()
