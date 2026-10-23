"""Source-only owned CFI witness. No parser/auditor or target is invoked here."""
from dataclasses import replace
from pathlib import Path
import struct
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests'))
# Reuse existing owned literal CIE and independent record framing helper.
from test_dwarf_cfi import CIE, record
from test_rbit_x_candidate import fixture, NOP, RET
from airs.types import FunctionRange, Section, UnwindEntry, UnwindTable

BASE=0x1000
EH_ADDRESS=BASE+0x400
CASES=('supported-control','local-program','malformed-record','shared-cie','unsupported-overlap')
STATE_PAIR=b'\x0a\x0b'  # Operand-free remember_state followed by restore_state.


def _fde(offset, start, program):
    # Backward CIE pointer to offset zero; pcrel signed64 pointer and uint64 span.
    body=struct.pack('<IqQ',offset+4,start-(EH_ADDRESS+offset+8),8)+b'\0'+program
    return record(body)


def build_case(name):
    """Return new typed image/table data; caller owns any specifically granted run."""
    if name not in CASES:
        raise ValueError('Unknown prepared case')
    image,_,_=fixture((NOP,RET,NOP,RET),0x03000000)
    functions=(FunctionRange(BASE,BASE+8,'owned_cfi_first','lc_function_starts'),
               FunctionRange(BASE+8,BASE+16,'owned_cfi_second','lc_function_starts'))
    cie=record(bytes(4)+CIE+(STATE_PAIR if name=='shared-cie' else b''))
    first_offset=len(cie)
    first=_fde(first_offset,BASE,b'\0')
    second_offset=first_offset+len(first)
    second_start=BASE+4 if name=='unsupported-overlap' else BASE+8
    second=_fde(second_offset,second_start,STATE_PAIR if name in ('local-program','unsupported-overlap') else b'\0')
    if name=='malformed-record':
        # Same original bytes, but declared second length exceeds remaining data.
        second=struct.pack('<I',len(second)+4)+second[4:]
    eh=cie+first+second
    section=Section('__TEXT','__eh_frame',EH_ADDRESS,len(eh),len(image.data))
    image=replace(image,data=image.data+eh,slice_size=len(image.data)+len(eh),
                  path=f'<owned-cfi-{name}>',container_sha256='1'*64,slice_sha256='2'*64,
                  sections=(*image.sections,section),functions=functions)
    table=UnwindTable((UnwindEntry(BASE,BASE+8,0x03000000|first_offset,0),
                       UnwindEntry(BASE+8,BASE+16,0x03000000|second_offset,8)))
    source={'case':name,'function_denominator':2,'preferred_base':hex(BASE),
            'eh_frame_address':hex(EH_ADDRESS),'eh_frame_bytes':len(eh),
            'cie_offset':0,'fde_offsets':[first_offset,second_offset],
            'fde_ranges':[[hex(BASE),hex(BASE+8)],[hex(second_start),hex(second_start+8)]],
            'function_ranges':[[hex(f.start),hex(f.end)] for f in functions],
            'compact_dwarf_offsets':[hex(first_offset),hex(second_offset)]}
    return image,table,source
