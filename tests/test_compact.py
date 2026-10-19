from __future__ import annotations

import struct
import unittest
from dataclasses import replace

from parser_helpers import build_macho, compressed_unwind, regular_unwind
from airs.compact import parse_compact_unwind
from airs.macho import parse_macho
from airs.types import InputError, Limits


def change(data: bytes, offset: int, format_: str, *values: int) -> bytes:
    result = bytearray(data)
    struct.pack_into(format_, result, offset, *values)
    return bytes(result)


def image_with(table: bytes, *, size: int = 32):
    return parse_macho(build_macho(bytes(size), unwind_info=table))


class CompactTests(unittest.TestCase):
    def assert_error(self, code: str, table: bytes, **kwargs: object) -> InputError:
        with self.assertRaises(InputError) as caught:
            parse_compact_unwind(image_with(table), **kwargs)
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    def test_regular_pages_keep_zero_encodings_and_use_segment_base(self):
        blob = regular_unwind(((0x1000, 0x04000000), (0x1008, 0), (0x1010, 0x02000000)), 0x1018)
        image = parse_macho(build_macho(bytes(24), function_offsets=(0, 4, 8, 12, 16, 20), unwind_info=blob))
        table = parse_compact_unwind(image)
        self.assertEqual([(entry.start, entry.end, entry.encoding) for entry in table.entries],
                         [(0x100001000, 0x100001008, 0x04000000),
                          (0x100001008, 0x100001010, 0),
                          (0x100001010, 0x100001018, 0x02000000)])
        self.assertEqual(len(image.functions), 6)
        self.assertIn("no_unwind_rule_ranges", {issue.code for issue in table.issues})
        for entry in table.entries:
            self.assertLess(entry.source_offset, image.slice_size)

    def test_compressed_pages_resolve_common_and_local_encodings(self):
        blob = compressed_unwind(((0x1000, 0), (0x1008, 1)), 0x1010,
                                  common=(0x04000001,), local=(0x02002000,))
        table = parse_compact_unwind(image_with(blob))
        self.assertEqual([entry.encoding for entry in table.entries], [0x04000001, 0x02002000])
        self.assertEqual(table.entries[1].start, 0x100001008)

    def test_regular_and_compressed_pages_share_one_final_sentinel(self):
        blob = (struct.pack("<7I", 1, 28, 1, 0, 0, 32, 3)
                + struct.pack("<I", 0x04000000)
                + struct.pack("<9I", 0x1000, 68, 0, 0x1008, 84, 0, 0x1010, 0, 0)
                + struct.pack("<IHHII", 2, 8, 1, 0x1000, 0x04000000)
                + struct.pack("<IHHHHII", 3, 12, 1, 16, 1, 0x01000000, 0x02000000))
        table = parse_compact_unwind(image_with(blob))
        self.assertEqual([entry.end for entry in table.entries], [0x100001008, 0x100001010])
        self.assertEqual([entry.encoding for entry in table.entries], [0x04000000, 0x02000000])

    def test_missing_and_empty_optional_metadata_are_issues(self):
        for image in (parse_macho(build_macho()), image_with(b""),
                      image_with(struct.pack("<7I", 1, 0, 0, 0, 0, 0, 0)),
                      image_with(regular_unwind((), 0))):
            with self.subTest(size=image.slice_size):
                table = parse_compact_unwind(image)
                self.assertEqual(table.entries, ())
                self.assertTrue(table.issues)

    def test_dwarf_and_pauth_are_retained_as_metadata_only(self):
        blob = regular_unwind(((0x1000, 0x03000004), (0x1008, 0x05003000), (0x1010, 0x01000000)), 0x1018)
        table = parse_compact_unwind(image_with(blob))
        self.assertEqual([entry.encoding for entry in table.entries], [0x03000004, 0x05003000, 0x01000000])
        self.assertTrue({"dwarf_metadata_only", "dwarf_reference_unavailable", "pauth_metadata_only", "unknown_unwind_mode"}
                        <= {issue.code for issue in table.issues})

    def test_personality_and_lsda_semantics_are_not_inferred(self):
        blob = regular_unwind(((0x1000, 0x54000000),), 0x1008, personalities=(0x1010,))
        table = parse_compact_unwind(image_with(blob))
        self.assertIn("exception_metadata_only", {issue.code for issue in table.issues})

    def test_bounded_lsda_array_is_read_structurally(self):
        blob = (struct.pack("<7I", 1, 0, 0, 0, 0, 28, 2)
                + struct.pack("<6I", 0x1000, 60, 52, 0x1008, 0, 60)
                + struct.pack("<II", 0x1000, 0x1010)
                + struct.pack("<IHHII", 2, 8, 1, 0x1000, 0x44000000))
        table = parse_compact_unwind(image_with(blob))
        self.assertEqual(len(table.entries), 1)
        self.assertIn("exception_metadata_only", {issue.code for issue in table.issues})
        self.assert_error("unwind_lsda_function_range", change(blob, 52, "<I", 0x100C))

    def test_header_version_and_extent_are_checked(self):
        self.assert_error("unwind_extent", bytes(4))
        blob = regular_unwind(((0x1000, 0x04000000),), 0x1008)
        self.assert_error("unsupported_unwind_version", change(blob, 0, "<I", 2))
        self.assert_error("unwind_extent", change(blob, 20, "<I", len(blob) + 4))

    def test_array_counts_and_offsets_are_bounded(self):
        blob = regular_unwind(((0x1000, 0x04000000),), 0x1008)
        self.assert_error("unwind_encoding_limit", change(blob, 8, "<I", 257))
        self.assert_error("unwind_personality_limit", change(blob, 16, "<I", 4))
        self.assert_error("unwind_entry_limit", change(blob, 24, "<I", 0xFFFFFFFF))
        self.assert_error("unwind_array_offset", change(blob, 4, "<II", 4, 1))
        self.assert_error("unwind_overlapping_tables", change(blob, 4, "<II", 28, 1))

    def test_sentinel_and_first_level_order_are_enforced(self):
        blob = regular_unwind(((0x1000, 0x04000000),), 0x1008)
        self.assert_error("unwind_sentinel", change(blob, 44, "<I", 52))
        self.assert_error("unwind_index_order", change(blob, 40, "<I", 0x1000))
        self.assert_error("unwind_missing_page", change(blob, 32, "<I", 0))
        self.assert_error("unwind_sentinel_range", change(blob, 40, "<I", 0x2000))

    def test_regular_page_kind_order_and_extent_are_enforced(self):
        blob = regular_unwind(((0x1000, 0x04000000), (0x1008, 0x02000000)), 0x1010)
        self.assert_error("unsupported_unwind_page_kind", change(blob, 52, "<I", 99))
        self.assert_error("unwind_page_first_entry", change(blob, 60, "<I", 0x1004))
        self.assert_error("unwind_entry_order", change(blob, 68, "<I", 0x1000))
        self.assert_error("unwind_page_extent", change(blob, 58, "<H", 512))
        self.assert_error("unwind_empty_page", change(blob, 58, "<H", 0))

    def test_compressed_encoding_index_and_local_array_overlap_are_enforced(self):
        blob = compressed_unwind(((0x1000, 0),), 0x1008, common=(0x04000000,))
        self.assert_error("unwind_encoding_index", change(blob, 68, "<I", 0x01000000))
        local = compressed_unwind(((0x1000, 0),), 0x1008, local=(0x04000000,))
        self.assert_error("unwind_overlapping_tables", change(local, 60, "<H", 12))
        self.assert_error("unwind_encoding_limit", change(blob, 66, "<H", 256))

    def test_missing_personality_is_a_structural_reference_error(self):
        self.assert_error("unwind_personality_index", regular_unwind(((0x1000, 0x14000000),), 0x1008))

    def test_lsda_offsets_and_partial_records_are_checked(self):
        blob = regular_unwind(((0x1000, 0x04000000),), 0x1008)
        self.assert_error("unwind_lsda_order", change(blob, 48, "<I", 1))
        self.assert_error("unwind_lsda_size", change(blob, 48, "<I", 4))
        self.assert_error("unwind_extent", change(blob, 48, "<I", 0xFFFFFFFC))

    def test_metadata_address_alignment_and_overflow_are_checked(self):
        blob = regular_unwind(((0x1000, 0x04000000),), 0x1008)
        self.assert_error("unwind_address_alignment", change(blob, 28, "<I", 0x1001))
        image = replace(image_with(blob), preferred_base=(1 << 64) - 0x1000)
        with self.assertRaises(InputError) as caught:
            parse_compact_unwind(image)
        self.assertEqual(caught.exception.code, "unwind_address_overflow")

    def test_terminal_boundary_can_be_one_byte_past_code_without_rounding(self):
        for builder in (
            lambda end: regular_unwind(((0x1000, 0x02000000),), end),
            lambda end: compressed_unwind(((0x1000, 0),), end, common=(0x02000000,)),
        ):
            table = parse_compact_unwind(image_with(builder(0x1021)))
            self.assertEqual(table.entries[-1].end, 0x100001021)
            self.assert_error("unwind_sentinel_range", builder(0x1022))
        # The terminal exception never relaxes instruction-entry alignment.
        self.assert_error("unwind_address_alignment",
                          regular_unwind(((0x1000, 0x02000000), (0x1005, 0)), 0x1021))

    def test_entry_budget_is_checked_before_decoding_page(self):
        blob = regular_unwind(((0x1000, 0x04000000), (0x1008, 0x02000000), (0x1010, 0)), 0x1018)
        self.assert_error("unwind_entry_limit", blob, limits=replace(Limits(), max_unwind_entries=2))
        self.assert_error("invalid_limits", blob, limits=replace(Limits(), max_unwind_entries=0))

    def test_section_extent_is_rechecked_for_direct_api_use(self):
        image = image_with(regular_unwind(((0x1000, 0x04000000),), 0x1008))
        with self.assertRaises(InputError) as caught:
            parse_compact_unwind(replace(image, data=image.data[:16]))
        self.assertEqual(caught.exception.code, "unwind_section_extent")

    def test_all_structural_truncations_raise_input_errors(self):
        blob = compressed_unwind(((0x1000, 0), (0x1008, 1)), 0x1010,
                                  common=(0x04000000,), local=(0x02000000,))
        for length in range(1, len(blob)):
            with self.subTest(length=length):
                with self.assertRaises(InputError):
                    parse_compact_unwind(image_with(blob[:length]))


if __name__ == "__main__":
    unittest.main()
