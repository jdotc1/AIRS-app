"""New literal CFI cases for bounded local refusal; no retained workload replay."""
from dataclasses import replace
import struct
import unittest
from airs import dwarf_cfi
from airs.types import InputError, Limits
from test_dwarf_cfi import eh_image, record, EH_ADDRESS, BASE


def pair(tail=b'\x0a\x0b', *, overlap=False, words=None):
    image, fn, entry = eh_image(program=b'\0', **({'words':words} if words else {}))
    section=image.sections[-1]
    eh=image.data[section.file_offset:]
    offset=len(eh)
    start=BASE if overlap else fn.end
    body=struct.pack('<IqQ',offset+4,start-(EH_ADDRESS+offset+8),fn.size)+b'\0'+tail
    eh+=record(body)
    image=replace(image,data=image.data[:section.file_offset]+eh,
                  sections=image.sections[:-1]+(replace(section,size=len(eh)),))
    return image,fn,entry,offset,replace(fn,start=start,end=start+fn.size)


class LocalFDETests(unittest.TestCase):
    def test_neighbor_retains_rows_refused_fde_has_no_prefix(self):
        image,fn,entry,offset,other=pair(b'\0\x0a\xff')
        table=dwarf_cfi.parse_eh_frame(image)
        self.assertEqual(table.select(entry.encoding&0xffffff,fn).row_at(BASE).cfa,(31,0))
        self.assertEqual(table.fdes[offset].rows,())
        with self.assertRaises(InputError): table.select(offset,other)
        with self.assertRaises(InputError): table.fdes[offset].row_at(other.start)

    def test_refused_ranges_still_make_neighbors_ambiguous(self):
        image,fn,entry,offset,other=pair(overlap=True)
        table=dwarf_cfi.parse_eh_frame(image)
        self.assertEqual(table.overlapping,frozenset((entry.encoding&0xffffff,offset)))
        with self.assertRaises(InputError): table.select(entry.encoding&0xffffff,fn)

    def test_opaque_tail_reserves_both_global_budgets(self):
        image,*_=pair(b'\x0a'+b'\xff'*8)
        # CIE=1 instruction/row; supported FDE=1 instruction/row;
        # refusal opcode=1 instruction; eight tail bytes reserve 8 instructions and 9 rows including final.
        for changes in ({'max_cfi_instructions':10},{'max_cfi_rows':10}):
            with self.subTest(changes=changes),self.assertRaises(InputError):
                dwarf_cfi.parse_eh_frame(image,replace(Limits(),**changes))
        dwarf_cfi.parse_eh_frame(image,replace(Limits(),max_cfi_instructions=11,max_cfi_rows=11))

    def test_arbitrary_unknown_and_shared_cie_remain_global(self):
        with self.assertRaises(InputError): dwarf_cfi.parse_eh_frame(pair(b'\xff')[0])
        image,_,_=eh_image(cie=b'\x01zR\0\x01\x78\x1e\x01\x10\x0c\x1f\0\x0a')
        with self.assertRaises(InputError): dwarf_cfi.parse_eh_frame(image)

    def test_later_invalid_header_remains_global(self):
        image,fn,entry,offset,other=pair()
        section=image.sections[-1]; data=bytearray(image.data)
        struct.pack_into('<Q',data,section.file_offset+offset+16,3)
        with self.assertRaises(InputError): dwarf_cfi.parse_eh_frame(replace(image,data=bytes(data)))

    def test_audit_neighbor_agreement_refusal_has_no_checked_pcs(self):
        from airs.audit import audit_function
        image,fn,entry,offset,other=pair(words=(0xd503201f,0xd65f03c0))
        table=dwarf_cfi.parse_eh_frame(image)
        good=audit_function(image,fn,entry,cfi_table=table)
        bad=audit_function(image,fn,replace(entry,encoding=0x03000000|offset),cfi_table=table)
        self.assertEqual((good.verdict,good.coverage,good.checked_pcs),('agreement','dwarf_evaluated',(BASE,)))
        self.assertEqual((bad.verdict,bad.coverage,bad.checked_pcs),('unresolved','dwarf_reference',()))

    def test_zero_tail_and_restore_opcode_also_refuse(self):
        for opcode in (b'\x0a',b'\x0b'):
            image,fn,entry,offset,other=pair(opcode)
            table=dwarf_cfi.parse_eh_frame(image)
            with self.assertRaises(InputError):table.select(offset,other)

    def test_new_model_admission_and_unknown_future(self):
        from airs import ANALYSIS_MODEL_VERSION
        from airs.report import validate_report
        from test_equivalent_compact import synthetic_report
        model='arm64-bounded-local-fde-v40'
        self.assertEqual(ANALYSIS_MODEL_VERSION,model)
        for fault in ('subtype','boundary','scope','dwarf'):
            wire=synthetic_report(model);finding=wire['findings'][0]
            if fault=='subtype':wire['image']['cpu_subtype']=0x80000000
            elif fault=='boundary':finding['function']['boundary_source']='compact_unwind'
            elif fault=='scope':finding['scope']='modeled_leaf_body'
            else:finding.update(mode='dwarf',coverage='dwarf_reference',encoding='0x03000004')
            with self.subTest(fault=fault),self.assertRaises(InputError):validate_report(wire)
        wire=synthetic_report(model+'-future');wire['image']['cpu_subtype']=0x80000000
        self.assertIs(validate_report(wire),wire)

    def test_opaque_tail_reserves_pending_final_row(self):
        image,*_=pair(b'\x0a\x44')
        # CIE and supported FDE cost two rows; opaque tail requires two more.
        with self.assertRaises(InputError):
            dwarf_cfi.parse_eh_frame(image,replace(Limits(),max_cfi_rows=3))
        dwarf_cfi.parse_eh_frame(image,replace(Limits(),max_cfi_rows=4))
