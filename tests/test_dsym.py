from __future__ import annotations

import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest
import uuid

from airs.dsym import attach_dsym
from airs.dwarf_line import parse_lines

ROOT = Path(__file__).resolve().parents[1]
UUID = 'b50afa8b-ca39-4bd2-abfe-0340b413fa15'


def uleb(n):
    out = bytearray()
    while n >= 128:
        out.append((n & 127) | 128); n >>= 7
    out.append(n)
    return bytes(out)


def line_unit(*, start=0x100001000, end=0x100001018, line=7, directory='/owned', name='source.c', extra=b''):
    # Independent DWARF v4 table with set_address, advance_line, copy, end.
    header = bytes([1, 1, 1, 251, 14, 13]) + bytes([0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1])
    header += directory.encode() + b'\0\0' + name.encode() + b'\0\1\0\0\0'
    program = b'\0\11\2' + struct.pack('<Q', start) + b'\3' + bytes([line-1]) + b'\1' + extra
    program += b'\2' + uleb(end-start) + b'\0\1\1'
    body = struct.pack('<HI', 4, len(header)) + header + program
    return struct.pack('<I', len(body)) + body


def dsym_bytes(*, ident=UUID, subtype=0, sections=None):
    sections = sections if sections is not None else {'__debug_line':line_unit()}
    commands = []
    if ident:
        commands.append(struct.pack('<II', 0x1b, 24) + uuid.UUID(ident).bytes)
    start = 32 + (24 if ident else 0) + 72 + 80*len(sections)
    payload=bytearray(); rows=[]
    for name, data in sections.items():
        rows.append(struct.pack('<16s16sQQIIIIIIII',name.encode(),b'__DWARF',0,len(data),start+len(payload),0,0,0,0,0,0,0))
        payload.extend(data)
    commands.append(struct.pack('<II16sQQQQiiII',0x19,72+80*len(rows),b'__DWARF',0,len(payload),start,len(payload),7,3,len(rows),0)+b''.join(rows))
    cmds=b''.join(commands)
    return struct.pack('<8I',0xfeedfacf,0x100000c,subtype,10,len(commands),len(cmds),0,0)+cmds+payload


def fat(slices):
    offset=8+20*len(slices); rows=[]; data=b''
    for subtype, blob in slices:
        rows.append(struct.pack('>5I',0x100000c,subtype,offset,len(blob),0));offset+=len(blob);data+=blob
    return struct.pack('>2I',0xcafebabe,len(slices))+b''.join(rows)+data


class DsymTests(unittest.TestCase):
    def setUp(self):
        self.report=json.loads((ROOT/'examples/before.audit.json').read_text())
        self.report['image']['uuid']=UUID
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)

    def write(self, name='symbols', data=None):
        p=self.directory/name;p.write_bytes(dsym_bytes() if data is None else data);return p

    def test_matching_identity_adds_only_annotations(self):
        original=copy.deepcopy(self.report)
        result=attach_dsym(self.report,self.write())
        annotations=result.pop('source_annotations')
        self.assertEqual(result,original)
        self.assertEqual(self.report,original)
        self.assertEqual(annotations['status'],'matched')
        self.assertEqual(annotations['image_identity']['slice_sha256'],original['image']['slice_sha256'])
        self.assertNotEqual(annotations['attachment']['slice_sha256'],original['image']['slice_sha256'])
        first=annotations['functions'][0]
        self.assertEqual(first['status'],'mapped')
        self.assertEqual(first['locations'][0]['path'],'/owned/source.c')
        self.assertEqual(first['locations'][0]['line'],7)
        self.assertEqual(first['locations'][0]['source_status'],'missing')

    def test_stale_wrong_arch_missing_uuid_and_missing_files_are_explicit(self):
        self.assertEqual(attach_dsym(self.report,self.write(data=dsym_bytes(ident=str(uuid.uuid4()))))['source_annotations']['status'],'uuid_mismatch')
        self.assertEqual(attach_dsym(self.report,self.write('e',dsym_bytes(subtype=2)))['source_annotations']['status'],'architecture_mismatch')
        self.assertEqual(attach_dsym(self.report,self.write('no-uuid',dsym_bytes(ident=None)))['source_annotations']['status'],'missing_dsym_uuid')
        self.assertEqual(attach_dsym(self.report,self.directory/'absent')['source_annotations']['status'],'missing_dsym')
        self.report['image']['uuid']=None
        self.assertEqual(attach_dsym(self.report,self.write())['source_annotations']['status'],'missing_image_uuid')

    def test_fat_selects_exact_subtype_and_duplicate_candidates_are_ambiguous(self):
        p=self.write(data=fat([(2,dsym_bytes(subtype=2)),(0,dsym_bytes())]))
        a=attach_dsym(self.report,p)['source_annotations']
        self.assertEqual(a['status'],'matched');self.assertEqual(a['attachment']['cpu_subtype'],0)
        bundle=self.directory/'Owned.dSYM';folder=bundle/'Contents/Resources/DWARF';folder.mkdir(parents=True)
        (folder/'one').write_bytes(dsym_bytes());(folder/'two').write_bytes(dsym_bytes())
        self.assertEqual(attach_dsym(self.report,bundle)['source_annotations']['status'],'ambiguous_dsym')

    def test_stripped_unsupported_and_malformed_debug_data_do_not_attach_locations(self):
        for name,data,status in [('stripped',dsym_bytes(sections={}),'missing_line_table'),('bad',dsym_bytes(sections={'__debug_line':b'\x01'}),'invalid_debug_data'),('v5',dsym_bytes(sections={'__debug_line':struct.pack('<IH',2,5)}),'unsupported_debug_format')]:
            with self.subTest(name=name):
                a=attach_dsym(self.report,self.write(name,data))['source_annotations']
                self.assertEqual(a['status'],status);self.assertEqual(a['functions'],[])

    def test_overlap_and_duplicate_names_never_guess_by_symbol(self):
        self.report['findings'][1]['function']['name']=self.report['findings'][0]['function']['name']
        p=self.write(data=dsym_bytes(sections={'__debug_line':line_unit()+line_unit(line=9)}))
        a=attach_dsym(self.report,p)['source_annotations']
        self.assertEqual(a['functions'][0]['status'],'ambiguous_line')
        self.assertEqual(len(a['functions'][0]['locations']),2)
        self.assertEqual(a['functions'][0]['name_status'],'duplicate')
        self.assertEqual(a['functions'][1]['status'],'no_line_entry')

    def test_source_path_is_never_resolved_against_current_working_directory(self):
        p=self.write(data=dsym_bytes(sections={'__debug_line':line_unit(directory='relative')}))
        first=attach_dsym(self.report,p)['source_annotations']['functions'][0]
        self.assertEqual(first['locations'][0]['source_status'],'relative_path_unresolved')
        self.assertEqual(first['locations'][0]['path'],'relative/source.c')

    def test_import_rejects_stale_or_unbounded_annotation_envelopes(self):
        from airs.report import validate_report
        from airs.types import InputError
        attached=attach_dsym(self.report,self.write())
        for field,value in [('status',[]),('schema_version',2),('image_identity',{}),('functions',[]),('inline_chain','evaluated')]:
            changed=copy.deepcopy(attached);changed['source_annotations'][field]=value
            with self.subTest(field=field), self.assertRaises(InputError):validate_report(changed)
        changed=copy.deepcopy(attached)
        changed['source_annotations']['functions'][0]['name_status']='duplicate'
        with self.assertRaises(InputError):validate_report(changed)
        changed=copy.deepcopy(attached)
        changed['source_annotations']['functions'][0]['pc']=changed['findings'][0]['function']['end_address']
        with self.assertRaises(InputError):validate_report(changed)

    def test_cu_compilation_directory_is_scoped_to_its_line_table(self):
        from airs.dwarf_line import compilation_directories
        # CU root abbreviation: stmt_list sec_offset, comp_dir inline string.
        abbrev=bytes([1,0x11,0,0x10,0x17,0x1b,8,0,0,0])
        def cu(offset,directory):
            body=struct.pack('<HIB',4,0,8)+bytes([1])+struct.pack('<I',offset)+directory.encode()+b'\0'
            return struct.pack('<I',len(body))+body
        line=line_unit(directory='relative')
        sections={'__debug_info':cu(0,'/build/one')+cu(len(line),'/build/two'),'__debug_abbrev':abbrev}
        directories=compilation_directories(sections)
        rows=parse_lines(line+line,directories)
        self.assertEqual({r.path for r in rows},{'/build/one/relative/source.c','/build/two/relative/source.c'})

    def test_unsupported_second_unit_and_operation_index_never_yield_partial_mapping(self):
        data=line_unit()+struct.pack('<IH',2,5)
        a=attach_dsym(self.report,self.write(data=dsym_bytes(sections={'__debug_line':data})))['source_annotations']
        self.assertEqual(a['status'],'unsupported_debug_format');self.assertEqual(a['functions'],[])
        data=bytearray(line_unit());data[11]=2
        with self.assertRaises(ValueError):parse_lines(bytes(data),{})

    def test_unknown_annotation_identity_fields_are_preserved_as_additive_data(self):
        from airs.report import validate_report
        report=attach_dsym(self.report,self.write())
        report['source_annotations']['image_identity']['future_identity_note']='preserve'
        validate_report(report)
        self.assertEqual(report['source_annotations']['image_identity']['future_identity_note'],'preserve')

    def test_malformed_path_attribute_classes_and_empty_defined_file_decline(self):
        from airs.dwarf_line import compilation_directories
        body=struct.pack('<HIB',4,0,8)+bytes([1])
        info=struct.pack('<I',len(body))+body
        abbrev=bytes([1,0x11,0,0x10,0x19,0,0,0]) # stmt_list cannot be flag_present
        with self.subTest(case='attribute_class'), self.assertRaises(ValueError):
            compilation_directories({'__debug_info':info,'__debug_abbrev':abbrev})
        with self.subTest(case='empty_defined_file'), self.assertRaises(ValueError):
            parse_lines(line_unit(extra=b'\0\2\3\0'),{})

    def test_duplicate_cu_abbreviations_and_attributes_are_rejected(self):
        from airs.dwarf_line import compilation_directories
        body=struct.pack('<HIB',4,0,8)+bytes([1])+struct.pack('<I',0)
        info=struct.pack('<I',len(body))+body
        for abbrev in (bytes([1,0x11,0,0x10,0x17,0x10,0x17,0,0,0]),
                       bytes([1,0x11,0,0x10,0x17,0,0,1,0x11,0,0,0,0]),
                       bytes([1,0x11,0,0x10,0x17,0,0])):
            with self.subTest(abbrev=abbrev),self.assertRaises(ValueError):
                compilation_directories({'__debug_info':info,'__debug_abbrev':abbrev})

    def test_fat64_and_duplicate_selected_slices(self):
        blob=dsym_bytes()
        data=struct.pack('>2I',0xcafebabf,1)+struct.pack('>IIQQII',0x100000c,0,40,len(blob),0,0)+blob
        self.assertEqual(attach_dsym(self.report,self.write(data=data))['source_annotations']['status'],'matched')
        data=fat([(0,blob),(0,blob)])
        self.assertEqual(attach_dsym(self.report,self.write('duplicate',data))['source_annotations']['status'],'ambiguous_dsym')

    def test_gaps_available_sources_and_small_resource_budgets(self):
        from unittest.mock import patch
        code=self.directory/'source.c';code.write_text('owned source')
        data=line_unit(directory=str(self.directory))+line_unit(start=0x100001028,end=0x100001040)
        a=attach_dsym(self.report,self.write(data=dsym_bytes(sections={'__debug_line':data})))['source_annotations']
        self.assertEqual(a['functions'][0]['locations'][0]['source_status'],'available_unverified')
        self.assertEqual(a['functions'][1]['status'],'no_line_entry')
        with patch('airs.dwarf_line.MAX_ROWS',1):
            a=attach_dsym(self.report,self.write('budget'))['source_annotations']
        self.assertEqual(a['status'],'resource_limit');self.assertEqual(a['functions'],[])

    def test_line_table_intervals_are_half_open_and_unknown_effects_decline(self):
        rows=parse_lines(line_unit(),{})
        self.assertEqual((rows[0].start,rows[0].end),(0x100001000,0x100001018))
        with self.assertRaises(ValueError):parse_lines(line_unit(extra=b'\0\1\x7f'),{})
        with self.assertRaises(ValueError):parse_lines(line_unit()[:-1],{})


if __name__=='__main__':unittest.main()
