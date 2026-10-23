"""CFI controls through real Mach-O parsing, auditing, and report admission.

All machine code and metadata are owned literal fixtures, read only as bytes.
The fixture builder is independent of the production parsers and CFI evaluator.
"""
from dataclasses import replace
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest

from airs.engine import audit_path
from airs.report import dumps, load_report, validate_report
from airs.types import InputError, Limits
from parser_helpers import regular_unwind
from test_audit import FRAME
from test_cfi_v41_integration import CONTROL_FRAME_CFI
from test_dwarf_cfi import CIE, record
from test_report_v32_admission_candidate import replace_mode, synthetic_report


MODEL = 'arm64-bounded-cfi-control-v41'
TEXT_START = 0x100001000


def control_macho(program=CONTROL_FRAME_CFI):
    """A complete final ARM64 Mach-O with three literal __TEXT sections."""
    base = 0x100000000
    text = struct.pack('<6I', *FRAME)
    cie = record(bytes(4)+CIE)
    fde_offset = len(cie)
    fde = record(struct.pack('<IqQ', fde_offset+4,
                             TEXT_START-(base+0x3000+fde_offset+8), len(text))+b'\0'+program)
    compact = regular_unwind(((0x1000, 0x03000000 | fde_offset),), 0x1000+len(text))
    sections = ((b'__text', 0x1000, text, 0x80000400),
                (b'__unwind_info', 0x2000, compact, 0),
                (b'__eh_frame', 0x3000, cie+fde, 0))
    # LC_FUNCTION_STARTS: unsigned LEB delta0x1000 then the zero terminator.
    payload = bytearray(0x4000)
    payload.extend(b'\x80\x20\x00')
    segment = bytearray(struct.pack('<II16sQQQQiiII', 0x19, 72+80*3, b'__TEXT',
                                    base, 0x5000, 0, len(payload), 7, 5, 3, 0))
    for name, offset, content, flags in sections:
        payload[offset:offset+len(content)] = content
        segment.extend(struct.pack('<16s16sQQIIIIIIII', name, b'__TEXT', base+offset,
                                   len(content), offset, 2, 0, 0, flags, 0, 0, 0))
    commands = bytes(segment)+struct.pack('<IIII', 0x26, 16, 0x4000, 3)
    commands += struct.pack('<II', 0x1b, 24)+bytes(range(16))
    header = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 3, len(commands), 0, 0)
    payload[:len(header+commands)] = header+commands
    return bytes(payload)


def report_for(program=CONTROL_FRAME_CFI, *, limits=Limits()):
    with tempfile.TemporaryDirectory(prefix='airs-cfi-control-', dir=os.environ.get('AIRS_TEST_OUTPUT_ROOT')) as directory:
        path = Path(directory)/'owned-cfi-control.macho'
        path.write_bytes(control_macho(program))
        return audit_path(path, limits=limits)


def dwarf_admission(model=MODEL):
    report = synthetic_report(model)
    replace_mode(report, mode='dwarf', scope='synchronous_call_sites',
                 encoding='0x03000014', coverage='dwarf_evaluated')
    return report


class CFIControlV41EmissionTests(unittest.TestCase):
    def test_complete_macho_emits_v41_and_round_trips(self):
        report = report_for()
        self.assertEqual(report['generator']['analysis_model_version'], MODEL)
        self.assertEqual(report['analysis_config']['limits']['max_cfi_state_depth'], 64)
        finding = report['findings'][0]
        self.assertEqual((finding['verdict'], finding['coverage'], finding['scope']),
                         ('agreement', 'dwarf_evaluated', 'synchronous_call_sites'))
        self.assertEqual(finding['function']['boundary_source'], 'lc_function_starts')
        self.assertEqual(finding['checked_pcs'], ['0x10000100c'])
        self.assertEqual((report['summary']['function_count'], report['summary']['agreement_count']), (1, 1))
        artifact_root = os.environ.get('AIRS_TEST_OUTPUT_ROOT')
        if artifact_root:
            witness = Path(artifact_root) / 'v41-emitted-audit.json'
            if witness.exists():
                raise AssertionError('First emitted witness already exists; refuse overwrite')
            witness.write_text(dumps(report))
        with tempfile.TemporaryDirectory(dir=artifact_root) as directory:
            path = Path(directory)/'cfi-control-v41.json'
            path.write_text(dumps(report))
            self.assertEqual(load_report(path), report)

    def test_control_stream_can_disagree_and_late_unsupported_stays_unresolved(self):
        bad = CONTROL_FRAME_CFI.replace(b'\x9e\x01', b'\x9e\x02')
        finding = report_for(bad)['findings'][0]
        self.assertEqual((finding['verdict'], finding['coverage']), ('inconsistency', 'dwarf_evaluated'))
        self.assertTrue(any(e.get('expected') == 'original x30' and e.get('observed') == 'original x29'
                            for e in finding['evidence']))
        late = report_for(bad+b'\x0f')['findings'][0]
        self.assertEqual((late['verdict'], late['coverage'], late['checked_pcs']),
                         ('unresolved', 'dwarf_reference', []))

    def test_state_budget_failure_is_reported_as_unresolved(self):
        report = report_for(limits=replace(Limits(), max_cfi_state_depth=0))
        finding = report['findings'][0]
        self.assertEqual((finding['verdict'], finding['coverage'], finding['reason_codes']),
                         ('unresolved', 'dwarf_reference', ['dwarf_cfi_unsupported']))
        self.assertEqual(report['analysis_config']['limits']['max_cfi_state_depth'], 0)
        self.assertIs(validate_report(report), report)

    def test_exact_v41_admission_rejects_untrusted_dwarf_claims(self):
        for model in (MODEL, 'arm64-bounded-x-stack-v35'):
            valid = dwarf_admission(model)
            self.assertIs(validate_report(valid), valid)
            for fault in ('subtype', 'boundary', 'coverage', 'encoding', 'scope'):
                report = dwarf_admission(model)
                finding = report['findings'][0]
                if fault == 'subtype':
                    report['image']['cpu_subtype'] = 0x80000000
                elif fault == 'boundary':
                    finding['function']['boundary_source'] = 'compact_unwind'
                elif fault == 'coverage':
                    finding['coverage'] = 'dwarf_reference'
                elif fault == 'encoding':
                    finding['encoding'] = '0x04000000'
                else:
                    finding['scope'] = 'metadata_only'
                with self.subTest(model=model, fault=fault), self.assertRaises(InputError):
                    validate_report(report)

    def test_v41_compact_registration_keeps_prior_recovery_guards(self):
        for fault in ('subtype', 'boundary', 'scope', 'simd'):
            report = synthetic_report(MODEL)
            finding = report['findings'][0]
            if fault == 'subtype':
                report['image']['cpu_subtype'] = 0x80000000
            elif fault == 'boundary':
                finding['function']['boundary_source'] = 'compact_unwind'
            elif fault == 'scope':
                finding['scope'] = 'modeled_leaf_body'
            else:
                finding['encoding'] = '0x04000100'
            with self.subTest(fault=fault), self.assertRaises(InputError):
                validate_report(report)

    def test_historical_import_is_preserved_without_relabeling(self):
        root = Path(__file__).resolve().parents[1]
        path = root/'native/Tests/AIRSCoreTests/Fixtures/x-stack-v35-clz.json'
        historical = json.loads(path.read_text())
        self.assertEqual(load_report(path), historical)
        self.assertEqual(historical['generator']['analysis_model_version'], 'arm64-bounded-x-stack-v35')
        future = dwarf_admission(MODEL+'-future')
        future['image']['cpu_subtype'] = 0x80000000
        self.assertIs(validate_report(future), future)
        # v1 never had evaluated CFI, even after v36 is registered.
        with self.assertRaises(InputError):
            validate_report(dwarf_admission('arm64-linear-v1'))


if __name__ == '__main__':
    unittest.main()
