"""New-model report integration using tiny typed inputs; parsers are substituted."""
from dataclasses import replace
import json
from pathlib import Path
import tempfile
from output_paths import output_root
import unittest
from unittest.mock import patch

from airs import ANALYSIS_MODEL_VERSION
from airs.engine import audit_path
from airs.report import dumps, load_report, validate_report
from airs.types import InputError, UnwindTable
from test_rbit_x_candidate import fixture, CTZ_WITNESS, RET, PRO, EPI, CALL, PAIR_PRO, PAIR_EPI, RBIT_X19_X0
from test_report_v32_admission_candidate import synthetic_report

V33 = 'arm64-bounded-rbit-v33'
OUTPUT = output_root()


def report_for(words, encoding=0x02000000, with_callee=False):
    image, function, entry = fixture(words, encoding, with_callee=with_callee)
    # Placeholder identities: no old source/export digests are recomputed.
    image = replace(image, container_sha256='1'*64, slice_sha256='2'*64)
    with tempfile.TemporaryDirectory(dir=OUTPUT) as directory:
        path = Path(directory) / 'synthetic-rbit.bin'
        path.write_bytes(image.data)
        with patch('airs.engine.parse_macho', return_value=image), patch('airs.engine.parse_compact_unwind', return_value=UnwindTable((entry,))):
            return audit_path(path)


class RBITV33IntegrationTests(unittest.TestCase):
    def test_new_model_report_and_serialized_complete_ctz_witness(self):
        report = report_for(CTZ_WITNESS)
        self.assertEqual(report['generator']['analysis_model_version'], ANALYSIS_MODEL_VERSION)
        finding = report['findings'][0]
        self.assertEqual((finding['verdict'], finding['scope']), ('agreement', 'modeled_leaf_body'))
        self.assertEqual(finding['checked_pcs'], ['0x1000', '0x1004'])
        output = OUTPUT / 'rbit-v39.json'
        output.write_text(dumps(report), encoding='utf-8')
        self.assertEqual(load_report(output), report)

    def test_new_model_stack_provenance_stays_unresolved(self):
        # ADD X0,SP,#0; RBIT X1,X0; RET.
        for words in ((0x910003e0, 0xdac00001, RET),):
            with self.subTest(words=words):
                report = report_for(words)
                finding = report['findings'][0]
                self.assertEqual(finding['verdict'], 'unresolved')
                self.assertEqual(finding['checked_pcs'], [])
                self.assertIs(validate_report(report), report)

    def test_new_model_call_report_preserves_concrete_recovery_witness(self):
        report = report_for((*PAIR_PRO, 0xd2800020, RBIT_X19_X0, CALL, *PAIR_EPI), encoding=0x04000000, with_callee=True)
        finding = report['findings'][0]
        self.assertEqual((finding['verdict'], finding['scope']), ('inconsistency', 'synchronous_call_sites'))
        self.assertEqual(finding['checked_pcs'], ['0x1018'])
        self.assertTrue(any(item.get('observed') == 'constant 0x8000000000000000' for item in finding['evidence']))
        self.assertIs(validate_report(report), report)

    def test_new_model_admission_is_exact_and_unknown_labels_stay_generic(self):
        for model in (V33, 'arm64-bounded-clz-v32'):
            report = synthetic_report(model)
            report['image']['cpu_subtype'] = 0x80000000
            with self.assertRaises(InputError): validate_report(report)
        future = synthetic_report(V33+'-future')
        future['image']['cpu_subtype'] = 0x80000000
        self.assertIs(validate_report(future), future)
