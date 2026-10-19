from __future__ import annotations

import hashlib
import struct
import unittest
from dataclasses import replace

from parser_helpers import build_fat, build_macho, regular_unwind
from airs.macho import parse_macho
from airs.types import InputError, Limits


def command_offset(data: bytes, wanted: int) -> int:
    cursor = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, cursor)
        if command == wanted:
            return cursor
        cursor += size
    raise AssertionError(f"Missing synthetic command {wanted:#x}")


def mutate(data: bytes, offset: int, format_: str, *values: int) -> bytes:
    changed = bytearray(data)
    struct.pack_into(format_, changed, offset, *values)
    return bytes(changed)


def starts_payload(payload: bytes) -> bytes:
    original = build_macho()
    command = command_offset(original, 0x26)
    begin = struct.unpack_from("<I", original, command + 8)[0]
    changed = bytearray(original[:begin] + payload)
    struct.pack_into("<I", changed, command + 12, len(payload))
    struct.pack_into("<Q", changed, 80, len(changed))
    return bytes(changed)


class MachOTests(unittest.TestCase):
    def assert_error(self, code: str, data: bytes, **kwargs: object) -> InputError:
        with self.assertRaises(InputError) as caught:
            parse_macho(data, **kwargs)
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    def test_final_image_uses_text_segment_base_and_independent_starts(self):
        data = build_macho(bytes(16), function_offsets=(0, 8), symbols=(("_second", 8),))
        image = parse_macho(data, "/owned/synthetic")
        self.assertEqual(image.preferred_base, 0x100000000)
        self.assertEqual(image.section("__TEXT", "__text").address, 0x100001000)
        self.assertEqual([(f.start, f.end) for f in image.functions],
                         [(0x100001000, 0x100001008), (0x100001008, 0x100001010)])
        self.assertEqual(image.functions[1].name, "_second")
        self.assertTrue(all(f.boundary_source == "lc_function_starts" for f in image.functions))
        self.assertEqual(image.bytes_at(0x100001008, 4), bytes(4))
        self.assertEqual(image.container_sha256, hashlib.sha256(data).hexdigest())
        self.assertEqual(image.slice_sha256, image.container_sha256)
        self.assertEqual(image.uuid, "00010203-0405-0607-0809-0a0b0c0d0e0f")

    def test_supported_final_file_types(self):
        for filetype in (2, 6, 8):
            with self.subTest(filetype=filetype):
                self.assertEqual(parse_macho(build_macho(filetype=filetype)).file_type, filetype)

    def test_fat_layouts_prefer_ordinary_arm64_and_allow_explicit_arm64e(self):
        arm64e, arm64 = build_macho(cpusubtype=0x80000002), build_macho()
        for fat64 in (False, True):
            for little in (False, True):
                with self.subTest(fat64=fat64, little=little):
                    data = build_fat((arm64e, arm64), is64=fat64, little=little)
                    image = parse_macho(data)
                    self.assertEqual(image.architecture, "arm64")
                    self.assertEqual(image.data, arm64)
                    self.assertEqual(image.slice_sha256, hashlib.sha256(arm64).hexdigest())
                    self.assertNotEqual(image.container_sha256, image.slice_sha256)
                    self.assertEqual(data[image.slice_offset:image.slice_offset + image.slice_size], image.data)
                    authenticated = parse_macho(data, requested_arch="arm64e")
                    self.assertEqual(authenticated.cpu_subtype, 0x80000002)
                    self.assertIn("arm64e_metadata_only", {i.code for i in authenticated.issues})

    def test_fat_validates_selected_slice_identity(self):
        data = build_fat((build_macho(),))
        self.assert_error("slice_identity_mismatch", mutate(data, 12, ">I", 2))

    def test_fat_validates_unselected_slice_extent(self):
        data = build_fat((build_macho(cputype=0x01000007), build_macho()))
        self.assert_error("fat_slice_extent", mutate(data, 20, ">I", len(data)))

    def test_fat_rejects_overlapping_slices(self):
        data = build_fat((build_macho(cpusubtype=2), build_macho()))
        first_offset = struct.unpack_from(">I", data, 16)[0]
        self.assert_error("overlapping_fat_slices", mutate(data, 36, ">I", first_offset))

    def test_fat_directory_and_alignment_are_bounded(self):
        self.assert_error("fat_slice_limit", struct.pack(">II", 0xCAFEBABE, 257))
        self.assert_error("empty_fat_container", struct.pack(">II", 0xCAFEBABE, 0))
        data = build_fat((build_macho(),))
        self.assert_error("fat_alignment", mutate(data, 24, ">I", 32))
        self.assert_error("truncated_fat_directory", data[:16])

    def test_architecture_and_nonfinal_formats_are_explicitly_rejected(self):
        self.assert_error("architecture_unavailable", build_macho(), requested_arch="arm64e")
        self.assert_error("architecture_unavailable", build_macho(cputype=0x01000007))
        self.assert_error("architecture_unavailable", build_macho(cpusubtype=9))
        self.assert_error("unsupported_file_type", build_macho(filetype=1))
        self.assert_error("unsupported_macho_format", b"\xfe\xed\xfa\xcf" + bytes(28))
        self.assert_error("invalid_architecture_request", build_macho(), requested_arch="x86_64")

    def test_compact_entries_do_not_create_functions(self):
        data = build_macho(function_offsets=None, unwind_info=regular_unwind(((0x1000, 0x02000000),), 0x1004))
        image = parse_macho(data)
        self.assertEqual(image.functions, ())
        self.assertIn("no_function_boundaries", {i.code for i in image.issues})

    def test_symbol_fallback_is_visible_and_aliases_are_deterministic(self):
        data = build_macho(bytes(16), function_offsets=None,
                           symbols=(("_z_alias", 0), ("_a_alias", 0), ("_next", 8)))
        image = parse_macho(data)
        self.assertEqual([f.name for f in image.functions], ["_a_alias", "_next"])
        self.assertEqual([f.size for f in image.functions], [8, 8])
        self.assertTrue(all(f.boundary_source == "symbol_table" for f in image.functions))
        self.assertIn("symbol_boundary_fallback", {i.code for i in image.issues})

    def test_function_starts_take_precedence_over_internal_symbols(self):
        image = parse_macho(build_macho(bytes(16), function_offsets=(0, 8),
                                        symbols=(("_first", 0), ("L_internal", 4), ("_second", 8))))
        self.assertEqual([f.start & 0xFFFF for f in image.functions], [0x1000, 0x1008])

    def test_empty_optional_function_table_is_not_a_format_error(self):
        for data in (build_macho(function_offsets=()), starts_payload(b"")):
            with self.subTest(size=len(data)):
                image = parse_macho(data)
                self.assertEqual(image.functions, ())
                self.assertIn("empty_function_starts", {i.code for i in image.issues})

    def test_function_starts_are_aligned_executable_and_bounded(self):
        self.assert_error("unaligned_function_start", build_macho(bytes(8), function_offsets=(1,)))
        self.assert_error("function_start_not_executable", build_macho(bytes(8), function_offsets=(16,)))
        self.assert_error("function_limit", build_macho(bytes(12), function_offsets=(0, 4, 8)),
                          limits=replace(Limits(), max_functions=2))

    def test_uleb_payload_has_bounded_length_overflow_and_terminator(self):
        cases = (("function_start_uleb_overflow", b"\x80" * 10),
                 ("truncated_function_start_uleb", b"\x80"),
                 ("function_start_overflow", b"\xff" * 9 + b"\x01\x00"),
                 ("unterminated_function_starts", b"\x80\x20"),
                 ("function_starts_trailing_data", b"\x80\x20\x00\x01"))
        for code, payload in cases:
            with self.subTest(code=code):
                self.assert_error(code, starts_payload(payload))

    def test_load_command_count_size_and_extent_are_checked(self):
        data = build_macho()
        self.assert_error("load_command_size", mutate(data, 36, "<I", 0))
        self.assert_error("load_command_count_mismatch", mutate(data, 16, "<I", 1))
        self.assert_error("load_command_extent", data[:40])
        self.assert_error("load_command_size", mutate(data, 20, "<I", 7))

    def test_configured_resource_limits_are_checked_before_iteration(self):
        data = build_macho()
        self.assert_error("file_size_limit", data, limits=replace(Limits(), max_file_bytes=32))
        self.assert_error("load_command_limit", data, limits=replace(Limits(), max_load_commands=1))
        with_unwind = build_macho(unwind_info=regular_unwind((), 0))
        self.assert_error("section_limit", with_unwind, limits=replace(Limits(), max_sections=1))
        self.assert_error("invalid_limits", data, limits=replace(Limits(), max_functions=0))
        self.assert_error("invalid_input_bytes", bytearray(data))

    def test_section_extents_mapping_and_containing_segment_are_checked(self):
        data = build_macho()
        self.assert_error("section_file_extent", mutate(data, 104 + 48, "<I", len(data) + 4))
        self.assert_error("section_mapping_mismatch", mutate(data, 104 + 32, "<Q", 0x100001004))
        self.assert_error("section_segment_mismatch", mutate(data, 104 + 16, "<16s", b"__DATA"))
        self.assert_error("section_alignment", mutate(data, 104 + 52, "<I", 0xFFFFFFFF))
        self.assert_error("unbacked_executable_section", mutate(data, 104 + 64, "<I", 1))

    def test_segment_overflow_and_file_extent_are_checked(self):
        data = build_macho()
        self.assert_error("segment_vm_overflow", mutate(data, 32 + 24, "<Q", (1 << 64) - 4))
        self.assert_error("segment_file_extent", mutate(data, 32 + 48, "<Q", len(data) + 1))

    def test_symbol_string_and_section_references_are_validated(self):
        data = build_macho(symbols=(("_name", 0),))
        command = command_offset(data, 2)
        symoff, _, _, strsize = struct.unpack_from("<IIII", data, command + 8)
        self.assert_error("symbol_string_offset", mutate(data, symoff, "<I", strsize))
        self.assert_error("symbol_section_index", mutate(data, symoff + 5, "<B", 10))
        self.assert_error("symbol_address_extent", mutate(data, symoff + 8, "<Q", 0))
        self.assert_error("unterminated_symbol_name", data[:-1] + b"A")
        self.assert_error("symbol_limit", mutate(data, command + 12, "<I", 1_000_001))

    def test_embedded_data_marks_affected_boundaries_unresolved(self):
        record = struct.pack("<IHH", 0x1000, 4, 1)
        command = struct.pack("<IIII", 0x29, 16, 0x1008, 8)
        image = parse_macho(build_macho(bytes(8), unwind_info=record, extra_commands=(command,)))
        self.assertEqual(image.functions[0].boundary_source, "lc_function_starts_with_embedded_data")
        self.assertIn("data_in_code_present", {issue.code for issue in image.issues})

    def test_duplicate_embedded_data_commands_cannot_multiply_parser_work(self):
        record = struct.pack("<IHH", 0x1000, 4, 1)
        command = struct.pack("<IIII", 0x29, 16, 0x1008, 8)
        self.assert_error("duplicate_data_in_code", build_macho(bytes(8), unwind_info=record,
                                                                extra_commands=(command, command)))

    def test_executable_relocations_make_function_boundary_scope_explicit(self):
        data = build_macho(bytes(8), unwind_info=bytes(8))
        image = parse_macho(mutate(data, 104 + 56, "<II", 0x1008, 1))
        self.assertEqual(image.functions[0].boundary_source, "lc_function_starts_with_relocations")
        self.assertIn("executable_relocations_present", {issue.code for issue in image.issues})

    def test_encrypted_bytes_are_never_treated_as_instructions(self):
        command = struct.pack("<6I", 0x2C, 24, 0x1000, 4, 1, 0)
        self.assert_error("encrypted_image", build_macho(extra_commands=(command,)))

    def test_truncation_surfaces_stable_input_errors(self):
        data = build_macho()
        lengths = list(range(64)) + [100, 184, 200, 224, 4095, 4096, len(data) - 1]
        for length in lengths:
            with self.subTest(length=length):
                with self.assertRaises(InputError) as caught:
                    parse_macho(data[:length])
                self.assertIsInstance(caught.exception.code, str)


if __name__ == "__main__":
    unittest.main()
