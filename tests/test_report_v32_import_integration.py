"""Serialized import coverage for the exact v32 registration correction."""
import json
import os
from pathlib import Path
import tempfile
import unittest

from airs.report import load_report
from airs.types import InputError
from test_report_v32_admission_candidate import synthetic_report, replace_mode, make_unresolved


class V32ImportIntegrationTests(unittest.TestCase):
    def load(self, report):
        root = os.environ.get('AIRS_TEST_OUTPUT_ROOT', str(Path(tempfile.gettempdir()) / 'AIRS-v32-admission-20261021'))
        with tempfile.TemporaryDirectory(dir=root) as folder:
            path = Path(folder) / 'new-synthetic-report.json'
            path.write_text(json.dumps(report), encoding='utf-8')
            return load_report(path)

    def test_serialized_v32_prohibited_claims_decline(self):
        for fault in ('arm64e', 'capability', 'boundary', 'scope', 'recovery', 'dwarf_coverage', 'dwarf_encoding'):
            with self.subTest(fault=fault):
                report = synthetic_report()
                finding = report['findings'][0]
                if fault == 'arm64e':
                    report['image'].update(architecture='arm64e', cpu_subtype=2)
                elif fault == 'capability':
                    report['image']['cpu_subtype'] = 0x80000000
                elif fault == 'boundary':
                    finding['function']['boundary_source'] = 'compact_unwind'
                elif fault == 'scope':
                    finding['scope'] = 'modeled_leaf_body'
                elif fault == 'recovery':
                    replace_mode(report, mode='frame', scope='synchronous_call_sites', encoding='0x4000100')
                elif fault == 'dwarf_coverage':
                    replace_mode(report, mode='dwarf', scope='synchronous_call_sites', encoding='0x3000004', coverage='dwarf_reference')
                else:
                    replace_mode(report, mode='dwarf', scope='synchronous_call_sites', encoding=None, coverage='dwarf_evaluated')
                with self.assertRaises(InputError) as caught:
                    self.load(report)
                self.assertEqual(caught.exception.code, 'invalid_report')

    def test_serialized_v32_supported_and_unresolved_reports_load(self):
        for mode in ('frame', 'frameless', 'dwarf', 'unresolved'):
            with self.subTest(mode=mode):
                report = synthetic_report()
                if mode == 'frameless':
                    replace_mode(report, mode=mode, scope='modeled_leaf_body', encoding='0x2001000')
                elif mode == 'dwarf':
                    replace_mode(report, mode=mode, scope='synchronous_call_sites', encoding='0x3000004', coverage='dwarf_evaluated')
                elif mode == 'unresolved':
                    make_unresolved(report)
                    report['image'].update(architecture='arm64e', cpu_subtype=2)
                report['future_annotation'] = {'note': 'preserved additive field'}
                self.assertEqual(self.load(report), report)

    def test_serialized_unknown_labels_keep_generic_policy(self):
        for model in ('future-owned-model', 'arm64-bounded-clz-v32-extra', 'future-owned-model-v35'):
            with self.subTest(model=model):
                report = synthetic_report(model)
                report['image']['cpu_subtype'] = 0x80000000
                report['findings'][0]['function']['boundary_source'] = 'future-boundary-kind'
                self.assertEqual(self.load(report), report)
                report['findings'][0]['checked_pcs'] = ['0x1010']
                with self.assertRaises(InputError) as caught:
                    self.load(report)
                self.assertEqual(caught.exception.code, 'invalid_report')

    def test_serialized_historical_models_retain_their_subtype_policy(self):
        historical = synthetic_report('arm64-linear-v1')
        historical['image']['cpu_subtype'] = 0x80000000
        self.assertEqual(self.load(historical), historical)
        previous = synthetic_report('arm64-bounded-sequential-loops-v31')
        previous['image']['cpu_subtype'] = 0x80000000
        with self.assertRaises(InputError) as caught:
            self.load(previous)
        self.assertEqual(caught.exception.code, 'invalid_report')
