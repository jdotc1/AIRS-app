"""Synthetic saved-annotation extent admission; no artifact bytes are read."""
import unittest

from airs.debug_macho import MAX_DEBUG_BYTES
from airs.dsym import IDENTITY_KEYS, validate_annotations
from airs.types import InputError


def envelope(offset=0, size=32):
    image = {
        'architecture': 'arm64', 'cpu_subtype': 0,
        'uuid': 'b50afa8b-ca39-4bd2-abfe-0340b413fa15',
        'slice_sha256': '1' * 64, 'container_sha256': '2' * 64,
        'preferred_base': '0x1000', 'slice_offset': 0, 'slice_size': 32,
    }
    report = {'image': image, 'findings': []}
    annotations = {
        'schema_version': 1, 'status': 'matched',
        'image_identity': {key: image[key] for key in IDENTITY_KEYS},
        'attachment': {
            'path': '/synthetic/owned.dSYM', 'architecture': 'arm64',
            'cpu_subtype': 0, 'uuid': image['uuid'], 'slice_sha256': '3' * 64,
            'slice_offset': offset, 'slice_size': size,
        },
        'inline_chain': 'not_evaluated', 'functions': [],
        'message': 'Synthetic envelope only; no artifact verified.', 'limitations': [],
    }
    return annotations, report


class DsymBoundaryRegressionTests(unittest.TestCase):
    def test_rejects_slices_too_small_for_a_macho_header(self):
        for size in (0, 1, 31):
            with self.subTest(size=size), self.assertRaises(InputError) as error:
                validate_annotations(*envelope(size=size))
            self.assertEqual(error.exception.code, 'invalid_source_annotations')

    def test_rejects_slice_extent_past_debug_container_budget(self):
        for offset, size in ((MAX_DEBUG_BYTES, 32), (1, MAX_DEBUG_BYTES),
                             (MAX_DEBUG_BYTES - 31, 32)):
            with self.subTest(offset=offset, size=size), self.assertRaises(InputError):
                validate_annotations(*envelope(offset, size))

    def test_retains_exact_bounded_endpoint_and_minimum_header(self):
        for offset, size in ((0, 32), (0, MAX_DEBUG_BYTES),
                             (MAX_DEBUG_BYTES - 32, 32)):
            with self.subTest(offset=offset, size=size):
                annotations, report = envelope(offset, size)
                validate_annotations(annotations, report)
                self.assertEqual(annotations['attachment']['slice_offset'], offset)
                self.assertEqual(annotations['attachment']['slice_size'], size)
