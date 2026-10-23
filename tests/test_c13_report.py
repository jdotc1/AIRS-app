"""Historical CFI contract, current engine integration and report compatibility."""
import copy
from dataclasses import replace
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from airs import ANALYSIS_MODEL_VERSION
from airs.engine import audit_path
from airs.report import validate_report
from airs.diff import compare_reports
from airs.types import InputError, Limits
from test_dwarf_cfi import eh_image
from parser_helpers import build_macho, regular_unwind

ROOT=Path(__file__).resolve().parents[1]

class C13ReportTests(unittest.TestCase):
    def report(self, limits=Limits()):
        image, fn, entry=eh_image()
        image=replace(image,container_sha256='a'*64,slice_sha256='b'*64)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'owned.macho'; path.write_bytes(image.data)
            with patch('airs.engine.parse_macho',return_value=image), patch('airs.engine.parse_compact_unwind') as compact:
                from airs.types import UnwindTable
                compact.return_value=UnwindTable((entry,))
                return audit_path(path,limits=limits)

    def test_engine_emits_new_model_evaluated_coverage_and_cfi_evidence(self):
        report=validate_report(self.report())
        self.assertEqual(report['generator']['analysis_model_version'],ANALYSIS_MODEL_VERSION)
        self.assertEqual(report['summary']['agreement_count'],1)
        self.assertEqual(report['findings'][0]['coverage'],'dwarf_evaluated')
        self.assertTrue(any(e['code']=='dwarf_cfi_row' for e in report['findings'][0]['evidence']))

    def test_old_model_still_rejects_supported_dwarf_and_new_model_checks_relationships(self):
        report=self.report()
        mutations=(('model','arm64-linear-v1'),('coverage','dwarf_reference'),('mode','frame'),
                   ('encoding','0x04000000'),('boundary','symbol_table'),('arch','arm64e'),('subtype',0x80000000))
        for key,value in mutations:
            item=copy.deepcopy(report)
            if key=='model':item['generator']['analysis_model_version']=value
            elif key=='boundary':item['findings'][0]['function']['boundary_source']=value
            elif key=='arch':item['image']['architecture']=value
            elif key=='subtype':item['image']['cpu_subtype']=value
            else:item['findings'][0][key]=value
            with self.subTest(key=key),self.assertRaises(InputError):validate_report(item)

    def test_historical_reports_and_model_mismatch_comparison_are_preserved(self):
        old=json.loads((ROOT/'examples/mixed.audit.json').read_text())
        self.assertIs(validate_report(old),old)
        new=copy.deepcopy(old);new['generator']['analysis_model_version']='arm64-linear-dwarf-v2'
        comparison=compare_reports(old,new)
        self.assertFalse(comparison['comparison']['model_compatible'])

    def test_real_macho_pipeline_uses_eh_frame_without_mocked_parsers(self):
        # Rehouse independently literal CFI at a known final-image section address.
        from test_dwarf_cfi import CIE,FRAME_CFI,record
        text=struct.pack('<6I',0xa9bf7bfd,0x910003fd,0xd503201f,0x94000400,0xa8c17bfd,0xd65f03c0)
        # CIE record20 bytes. Actual compact reference must point exactly at20.
        cie=record(bytes(4)+CIE)
        unwind=regular_unwind(((0x1000,0x03000000|len(cie)),),0x1018)
        base=0x100000000
        data=build_macho(text,unwind_info=unwind)
        eh_offset=(len(data)+7)&~7
        fde=record(struct.pack('<IqQ',len(cie)+4,(base+0x1000)-(base+eh_offset+len(cie)+8),len(text))+b'\0'+FRAME_CFI)
        eh=cie+fde
        data=bytearray(build_macho(text,unwind_info=unwind))
        nsects=struct.unpack_from('<I',data,32+64)[0]
        oldsize=struct.unpack_from('<I',data,36)[0]
        cmdbytes=struct.unpack_from('<I',data,20)[0]
        after=32+oldsize
        extra=struct.pack('<16s16sQQIIIIIIII',b'__eh_frame',b'__TEXT',base+eh_offset,len(eh),eh_offset,3,0,0,0,0,0,0)
        data[after:32+cmdbytes+80]=extra+data[after:32+cmdbytes]
        struct.pack_into('<I',data,36,oldsize+80);struct.pack_into('<I',data,32+64,nsects+1)
        struct.pack_into('<I',data,20,cmdbytes+80)
        data.extend(bytes(eh_offset-len(data)));data.extend(eh)
        struct.pack_into('<Q',data,32+48,len(data))
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'fixture';path.write_bytes(data)
            report=validate_report(audit_path(path))
        self.assertEqual(report['summary']['agreement_count'],1)

    def test_budget_declines_preserve_dwarf_reference_coverage(self):
        for changes in ({'max_total_instructions':0},{'max_total_evidence':0}):
            with self.subTest(changes=changes):
                finding=self.report(replace(Limits(),**changes))['findings'][0]
                self.assertEqual(finding['verdict'],'unresolved')
                self.assertEqual(finding['coverage'],'dwarf_reference')
