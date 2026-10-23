"""Device renumbering must preserve every other runtime metadata boundary."""
import copy
import importlib.util
import json
import os
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    'private_python', Path(__file__).resolve().parents[1] / 'scripts/prepare-private-python.py')
private_python = importlib.util.module_from_spec(spec)
spec.loader.exec_module(private_python)


class RuntimeMetadataReuseTests(unittest.TestCase):
    def setUp(self):
        self.saved = {
            'Python.framework': {'Python': [16777233, 101, 1024, 1000, 2000, 33188],
                                 'Versions': [16777233, 102, 128, 1001, 2001, 16877]},
            'Notices': {'License': [16777233, 103, 512, 1002, 2002, 33188]},
        }

    def compare(self, current):
        return private_python.compare_runtime_metadata(self.saved, current)

    def test_exact_metadata_preserves_existing_reuse(self):
        self.assertEqual(self.compare(copy.deepcopy(self.saved)), {'status': 'exact_metadata'})
        # Unchanged multi-device inventories retain the previous exact-equality behavior.
        self.saved['Notices']['License'][0] = 22
        self.assertEqual(self.compare(copy.deepcopy(self.saved)), {'status': 'exact_metadata'})

    def test_uniform_device_renumber_keeps_original_receipt(self):
        original = copy.deepcopy(self.saved)
        current = copy.deepcopy(self.saved)
        for records in current.values():
            for values in records.values():
                values[0] = 16777229
        self.assertEqual(self.compare(current), {'status': 'uniform_device_renumber',
                         'previous_device': 16777233, 'current_device': 16777229})
        self.assertEqual(self.saved, original)

    def test_each_nondevice_field_change_is_rejected(self):
        for group, records in self.saved.items():
            for index in range(1, 6):
                with self.subTest(group=group, field=index):
                    current = copy.deepcopy(self.saved)
                    current[group][next(iter(records))][index] += 1
                    with self.assertRaisesRegex(RuntimeError, 'beyond device identity'):
                        self.compare(current)

    def test_added_removed_or_empty_membership_is_rejected(self):
        for group in self.saved:
            for operation in ('add', 'remove', 'empty'):
                with self.subTest(group=group, operation=operation):
                    current = copy.deepcopy(self.saved)
                    if operation == 'add':
                        current[group]['extra'] = list(next(iter(current[group].values())))
                    elif operation == 'remove':
                        del current[group][next(iter(current[group]))]
                    else:
                        current[group] = {}
                    with self.assertRaisesRegex(RuntimeError, 'membership changed'):
                        self.compare(current)

    def test_partial_split_or_collapsed_device_changes_are_rejected(self):
        current = copy.deepcopy(self.saved)
        current['Notices']['License'][0] = 22
        with self.assertRaisesRegex(RuntimeError, 'uniform renumbering'):
            self.compare(current)
        self.saved['Notices']['License'][0] = 22
        current = copy.deepcopy(self.saved)
        for records in current.values():
            for values in records.values():
                values[0] = 33
        with self.assertRaisesRegex(RuntimeError, 'uniform renumbering'):
            self.compare(current)

    def test_invalid_record_or_group_is_rejected(self):
        for value in ([1, 2], [True, 101, 1024, 1000, 2000, 33188]):
            current = copy.deepcopy(self.saved)
            current['Python.framework']['Python'] = value
            with self.assertRaisesRegex(RuntimeError, 'invalid runtime metadata'):
                self.compare(current)
        with self.assertRaisesRegex(RuntimeError, 'inventory groups'):
            self.compare({'Python.framework': self.saved['Python.framework']})

    def test_saved_observed_metadata_pair_without_runtime_access(self):
        fixture = os.environ.get('AIRS_RUNTIME_METADATA_FIXTURE')
        if not fixture:
            self.skipTest('Saved diagnostic fixture not selected')
        fixture = Path(fixture)
        saved = json.loads((fixture / 'metadata-receipt-input.json').read_text())
        current = json.loads((fixture / 'metadata-current.json').read_text())
        before = copy.deepcopy(saved)
        result = private_python.compare_runtime_metadata(saved, current)
        self.assertEqual(result, {'status': 'uniform_device_renumber',
                         'previous_device': 16777233, 'current_device': 16777229})
        self.assertEqual(sum(map(len, current.values())), 3627)
        self.assertEqual(saved, before)
