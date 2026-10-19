"""Literal owned CFI, independent of production encoding/decoder helpers."""
from dataclasses import replace
import struct
import unittest

from airs import dwarf_cfi
from airs.arm64 import MachineState, ENTRY_SP, original
from airs.types import InputError, Limits, Section
from test_audit import fixture, FRAME, LEAF, BASE

EH_ADDRESS = BASE + 0x400
CIE = b'\x01zR\0\x01\x78\x1e\x01\x10\x0c\x1f\0'
FRAME_CFI = bytes.fromhex('440e109d029e01440c1d104c0c1f00ddde0000')
LEAF_CFI = bytes.fromhex('440e20480e0000')


def record(body):
    return struct.pack('<I', len(body)) + body


def eh_image(words=FRAME, program=FRAME_CFI, *, cie=CIE, fde_start=BASE, span=None, tail=b''):
    image, function, entry = fixture(words, 0x03000000)
    c = record(bytes(4) + cie)
    offset = len(c)
    # pcrel ptr-sized field; the range uses the format nibble only.
    body = struct.pack('<IqQ', offset + 4, fde_start - (EH_ADDRESS + offset + 8), span or function.size) + b'\0' + program
    eh = c + record(body) + tail
    section = Section('__TEXT', '__eh_frame', EH_ADDRESS, len(eh), len(image.data))
    image = replace(image, data=image.data + eh, sections=image.sections + (section,))
    return image, function, replace(entry, encoding=0x03000000 | offset)


def fde_for(args):
    image, function, entry = args
    return dwarf_cfi.parse_eh_frame(image).select(entry.encoding & 0xffffff, function)


class CFIReaderTests(unittest.TestCase):
    def test_owned_frame_rows_and_half_open_selection(self):
        fde = fde_for(eh_image())
        self.assertEqual(fde.row_at(BASE).cfa, (31, 0))
        self.assertEqual(fde.row_at(BASE+4).cfa, (31, 16))
        row = fde.row_at(BASE+8)
        self.assertEqual(row.cfa, (29, 16))
        self.assertEqual(row.rules[29], ('offset', -16))
        self.assertEqual(row.rules[30], ('offset', -8))
        self.assertEqual(fde.row_at(BASE+20).rules[30], ('same', 0))
        with self.assertRaises(InputError): fde.row_at(BASE+24)

    def test_leaf_rows_and_target_initial_defaults(self):
        fde = fde_for(eh_image(LEAF, LEAF_CFI))
        self.assertEqual(fde.row_at(BASE+4).cfa, (31, 32))
        self.assertTrue(all(rule == ('same', 0) for rule in fde.row_at(BASE).rules.values()))

    def test_bounded_cfa_register_update_retains_offset_at_exact_pc(self):
        # The instruction at BASE+8 establishes FP; only then can CFA use it.
        program = FRAME_CFI.replace(b'\x0c\x1d\x10', b'\x0d\x1d')
        fde = fde_for(eh_image(program=program))
        self.assertEqual(fde.row_at(BASE+4).cfa, (31, 16))
        self.assertEqual(fde.row_at(BASE+8).cfa, (29, 16))
        for invalid in (b'\x0d\x1c', b'\x0d\x20', b'\x0d', b'\x0d\x80'*11):
            with self.subTest(invalid=invalid), self.assertRaises(InputError):
                fde_for(eh_image(program=invalid))
        with self.assertRaises(InputError):
            fde_for(eh_image(cie=CIE[:-3]+b'\x0d\x1d', program=b'\0'))

    def test_exact_record_and_exact_function_extent_required(self):
        args = eh_image()
        image, function, entry = args
        table = dwarf_cfi.parse_eh_frame(image)
        for offset, fn in ((0,function),(entry.encoding & 0xffffff | 1,function),
                           (entry.encoding & 0xffffff,replace(function,end=function.end-4))):
            with self.subTest(offset=offset,fn=fn), self.assertRaises(InputError): table.select(offset,fn)
        with self.assertRaises(InputError): fde_for(eh_image(fde_start=BASE-4,span=28))

    def test_unsupported_cfi_even_after_observation_declines_entire_fde(self):
        for opcode in (b'\x0f',b'\x2d',b'\x0a',b'\x09',b'\x02'):
            with self.subTest(opcode=opcode),self.assertRaises(InputError):
                fde_for(eh_image(program=FRAME_CFI+opcode))

    def test_unsupported_cie_and_pointer_encodings_decline(self):
        variants=(CIE.replace(b'zR',b'zS'), CIE.replace(b'\x01z',b'\x03z'),
                  CIE.replace(b'\x01\x78',b'\x02\x78'), CIE.replace(b'\x78\x1e',b'\x78\x1d'),
                  CIE.replace(b'\x01\x10\x0c',b'\x01\x9b\x0c'))
        for cie in variants:
            with self.subTest(cie=cie),self.assertRaises(InputError): fde_for(eh_image(cie=cie))

    def test_truncation_bad_cie_reference_and_leb_overflow_decline(self):
        for program in (b'\x0c\x1f',b'\x0e'+b'\x80'*11,b'\x9e',b'\x7f'):
            with self.subTest(program=program),self.assertRaises(InputError): fde_for(eh_image(program=program))
        image,fn,entry=eh_image()
        data=bytearray(image.data); section=image.sections[-1]; off=entry.encoding&0xffffff
        struct.pack_into('<I',data,section.file_offset+off+4,off+3)
        with self.assertRaises(InputError): fde_for((replace(image,data=bytes(data)),fn,entry))
        with self.assertRaises(InputError): fde_for(eh_image(tail=b'\x01'))

    def test_unmodeled_register_and_missing_cfa_decline(self):
        for program in (b'\x0c\x00\x10',b'\x90\x01',b'\x08\x40'):
            with self.subTest(program=program),self.assertRaises(InputError): fde_for(eh_image(program=program))
        with self.assertRaises(InputError): fde_for(eh_image(cie=CIE[:-3],program=b'\0'))

    def test_explicit_same_undefined_and_restore_use_post_cie_rules(self):
        fde=fde_for(eh_image(program=b'\x07\x1e\x44\x08\x1e\x44\xde'))
        self.assertEqual(fde.row_at(BASE).rules[30],('undefined',0))
        self.assertEqual(fde.row_at(BASE+4).rules[30],('same',0))
        self.assertEqual(fde.row_at(BASE+8).rules[30],('same',0))
        fde=fde_for(eh_image(cie=CIE+b'\x9e\x01',program=b'\x08\x1e\x44\xde'))
        self.assertEqual(fde.row_at(BASE+4).rules[30],('offset',-8))

    def test_resource_limits_and_ambiguous_fdes_decline(self):
        args=eh_image(); image,fn,entry=args
        for changes in ({'max_cfi_bytes':1},{'max_cfi_records':1},{'max_cfi_instructions':1},{'max_cfi_rows':1}):
            with self.subTest(changes=changes),self.assertRaises(InputError):
                dwarf_cfi.parse_eh_frame(image,replace(Limits(),**changes))
        section=image.sections[-1]; eh=image.data[section.file_offset:]
        offset=len(eh); body=struct.pack('<IqQ',offset+4,BASE-(EH_ADDRESS+offset+8),fn.size)+b'\0'+FRAME_CFI
        extended=eh+record(body)
        image=replace(image,data=image.data[:section.file_offset]+extended,
                      sections=image.sections[:-1]+(replace(section,size=len(extended)),))
        with self.assertRaises(InputError): fde_for((image,fn,entry))

class CFIRecoveryTests(unittest.TestCase):
    def check(self, *args, limits=Limits(), **kwargs):
        from airs.audit import audit_function
        return audit_function(*eh_image(*args,**kwargs),limits=limits)

    def test_frame_at_bl_and_leaf_before_body_recover_complete_caller(self):
        frame=self.check(); leaf=self.check(LEAF,LEAF_CFI)
        self.assertEqual((frame.verdict,frame.coverage,frame.scope,frame.checked_pcs),
                         ('agreement','dwarf_evaluated','synchronous_call_sites',(BASE+12,)))
        self.assertEqual((leaf.verdict,leaf.coverage,leaf.scope,leaf.checked_pcs),
                         ('agreement','dwarf_evaluated','modeled_leaf_body',(BASE+4,)))
        self.assertTrue(any('FDE' in e.message and 'CFA=x29+16' in (e.observed or '') for e in frame.evidence))

    def test_register_update_recovers_from_fp_and_retains_unknown_boundary(self):
        program = FRAME_CFI.replace(b'\x0c\x1d\x10', b'\x0d\x1d')
        self.assertEqual(self.check(program=program).verdict, 'agreement')
        bad = program.replace(b'\x0e\x10', b'\x0e\x00')
        result = self.check(program=bad)
        self.assertEqual(result.verdict, 'unresolved')
        self.assertEqual(result.reason_codes, ('unknown_recovery_value',))

    def test_bad_cfa_or_swapped_saved_lr_has_concrete_recovery_evidence(self):
        # Use SP mismatch while all saved reads remain allocated/known: offset0
        bad=FRAME_CFI.replace(b'\x0c\x1d\x10',b'\x0c\x1d\x00').replace(b'\x9d\x02\x9e\x01',b'\x9d\x00\x9e\x00')
        result=self.check(program=bad)
        self.assertEqual(result.verdict,'inconsistency')
        self.assertTrue(any(e.expected=='entry SP' and e.observed=='entry SP-16' for e in result.evidence))
        result=self.check(program=FRAME_CFI.replace(b'\x9e\x01',b'\x9e\x02'))
        self.assertEqual(result.verdict,'inconsistency')
        self.assertTrue(any(e.expected=='original x30' and e.observed=='original x29' for e in result.evidence))

    def test_missing_lr_rule_is_mismatch_and_explicit_undefined_overrides_it(self):
        no_lr=FRAME_CFI.replace(b'\x9e\x01',b'')
        result=self.check(program=no_lr)
        self.assertEqual(result.verdict,'inconsistency')
        self.assertTrue(any(e.expected=='original x30' and e.observed==f'constant {BASE+16:#x}' for e in result.evidence))
        result=self.check(program=no_lr,cie=CIE+b'\x07\x13')
        self.assertEqual(result.verdict,'unresolved')
        self.assertEqual(result.reason_codes,('unknown_recovery_value',))

    def test_later_unknown_or_unsupported_program_dominates_earlier_discrepancy(self):
        bad=FRAME_CFI.replace(b'\x9e\x01',b'\x9e\x02')
        self.assertEqual(self.check(program=bad+b'\x2d').verdict,'unresolved')
        self.assertEqual(self.check(program=bad,cie=CIE+b'\x07\x13',limits=replace(Limits(),max_evidence_per_function=1)).reason_codes,
                         ('unknown_recovery_value',))
        # Read CFA+0 outside allocated stack: unknown, never a supported defect.
        self.assertEqual(self.check(program=FRAME_CFI.replace(b'\x9e\x01',b'\x9e\x00')).verdict,'unresolved')

    def test_arch_boundary_instruction_return_and_budgets_remain_gates(self):
        from airs.audit import audit_function
        image,fn,entry=eh_image()
        for changed, function in ((replace(image,architecture='arm64e',cpu_subtype=2),fn),
                                  (replace(image,cpu_subtype=0x01000000),fn),
                                  (image,replace(fn,boundary_source='symbol_table'))):
            result=audit_function(changed,function,entry)
            self.assertEqual(result.verdict,'unresolved')
            self.assertEqual(result.coverage,'dwarf_reference')
        for words in ((FRAME[0],FRAME[1],0xffffffff,*FRAME[3:]),
                      (*FRAME[:4],0xD503201F,FRAME[-1])):
            self.assertEqual(self.check(words).verdict,'unresolved')
        for limit in ({'max_evidence_per_function':0},{'max_observations_per_function':0},
                      {'max_instructions_per_function':1}):
            self.assertEqual(self.check(limits=replace(Limits(),**limit)).verdict,'unresolved')

    def test_cfi_row_boundary_uses_bl_pc_not_return_address(self):
        # At BL0x100c rule is wrong; at return-PC0x1010 it becomes right.
        program=bytes.fromhex('440e109d029e02440c1d10489e01440c1f00ddde')
        result=self.check(program=program)
        self.assertEqual(result.verdict,'inconsistency')
        self.assertEqual(result.checked_pcs,(BASE+12,))
