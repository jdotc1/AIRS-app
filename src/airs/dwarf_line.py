"""Bounded DWARF line locations, independent of unwind CFI or function discovery.

DWARF32 v4 line tables, 64-bit addresses, max_ops_per_instruction=1.
DWARF32 v4 CU root attributes only provide comp_dir for their own stmt_list.
Unknown formats/effects reject the complete lookup, never a partial unique map.
"""
from __future__ import annotations

from dataclasses import dataclass
import posixpath
import struct

from .debug_macho import DebugError

MAX_ROWS=200_000
MAX_OPS=1_000_000
MAX_UNITS=4096
MAX_STR=4096


class Reader:
    def __init__(self,data: bytes,start: int=0,end: int | None=None):
        self.data=data;self.pos=start;self.end=len(data) if end is None else end
        if not 0 <= start <= self.end <= len(data):self.bad()

    def bad(self):
        raise DebugError('invalid_debug_data','Truncated or malformed DWARF data')

    def take(self,n):
        if n<0 or n>self.end-self.pos:self.bad()
        out=self.data[self.pos:self.pos+n];self.pos+=n;return out

    def uint(self,n):return int.from_bytes(self.take(n),'little')

    def leb(self,signed=False):
        value=0
        for index in range(10):
            byte=self.uint(1);value|=(byte&127)<<(7*index)
            if not byte&128:
                if signed and byte&64:value-=1<<(7*(index+1))
                if not -(1<<63)<=value<(1<<64):self.bad()
                return value
        self.bad()

    def string(self):
        end=self.data.find(b'\0',self.pos,min(self.end,self.pos+MAX_STR+1))
        if end<0:self.bad()
        try:out=self.data[self.pos:end].decode('utf-8','strict')
        except UnicodeError:self.bad()
        self.pos=end+1;return out


def _unsupported(message):
    raise DebugError('unsupported_debug_format',message)


def _unit(reader):
    size=reader.uint(4)
    if size>=0xfffffff0:_unsupported('DWARF64/reserved unit length is not supported')
    if size>reader.end-reader.pos:reader.bad()
    unit=Reader(reader.data,reader.pos,reader.pos+size);reader.pos+=size
    return unit


def _form(r,form,strings,depth=0):
    if depth>4:r.bad()
    if form==0x16:return _form(r,r.leb(),strings,depth+1)
    if form==8:return r.string()
    if form==0xe:
        off=r.uint(4);return Reader(strings,off).string()
    widths={1:8,5:2,6:4,7:8,0xb:1,0xc:1,0x10:4,0x11:1,0x12:2,0x13:4,0x14:8,0x17:4,0x20:8}
    if form in widths:return r.uint(widths[form])
    if form in (0xd,0xf,0x15):return r.leb(form==0xd)
    if form==0x19:return True
    if form in (3,4,9,0xa,0x18):
        length=r.uint({3:2,4:4,0xa:1}[form]) if form in (3,4,0xa) else r.leb()
        r.take(length);return None
    _unsupported(f'Unsupported CU attribute form {form:#x}')


def compilation_directories(sections: dict[str,bytes]) -> dict[int,str]:
    info=sections.get('__debug_info',b'')
    if not info:return {}
    abbrev=sections.get('__debug_abbrev',b'');strings=sections.get('__debug_str',b'')
    r=Reader(info);directories={};units=0;operations=0
    while r.pos<r.end:
        units+=1
        if units>MAX_UNITS:raise DebugError('resource_limit','Too many debug compilation units')
        unit=_unit(r)
        if unit.uint(2)!=4:_unsupported('Only DWARF v4 CU root attributes are supported')
        offset=unit.uint(4)
        if unit.uint(1)!=8:_unsupported('Only 64-bit DWARF addresses are supported')
        wanted=unit.leb()
        if wanted==0:unit.bad()
        a=Reader(abbrev,offset);specifications=None;seen_codes=set();terminated=False
        while a.pos<a.end:
            operations+=1
            if operations>MAX_OPS:raise DebugError('resource_limit','Debug abbreviations exceed operation budget')
            code=a.leb()
            if not code:
                terminated=True;break
            if code in seen_codes:a.bad()
            seen_codes.add(code)
            tag=a.leb();children=a.uint(1)
            if children not in (0,1):a.bad()
            pairs=[];attribute_names=set()
            while True:
                name=a.leb();form=a.leb();operations+=1
                if operations>MAX_OPS:raise DebugError('resource_limit','Debug abbreviations exceed operation budget')
                if not name and not form:break
                if not name or not form:a.bad()
                if form==0x21:_unsupported('DW_FORM_implicit_const is outside DWARF v4 support')
                if name in attribute_names:a.bad()
                attribute_names.add(name);pairs.append((name,form))
            if code==wanted:
                if tag!=0x11:_unsupported('Expected a compile-unit root')
                specifications=pairs
        if specifications is None or not terminated:unit.bad()
        for name,form in specifications:
            if name==0x10 and form!=0x17:
                _unsupported('CU stmt_list requires DW_FORM_sec_offset in the supported v4 subset')
            if name==0x1b and form not in (8,0xe):
                _unsupported('CU comp_dir requires a string or strp form')
        attributes={name:_form(unit,form,strings) for name,form in specifications}
        statement=attributes.get(0x10);directory=attributes.get(0x1b)
        if statement is not None:
            if type(statement) is not int:unit.bad()
            if not isinstance(directory,str):directory=''
            if statement in directories:
                raise DebugError('unsupported_debug_format','Multiple CUs claim one line table')
            directories[statement]=directory
    return directories


@dataclass(frozen=True)
class LineRange:
    start: int
    end: int
    path: str
    line: int
    column: int
    discriminator: int
    sequence: int


def parse_lines(data: bytes,directories: dict[int,str]) -> list[LineRange]:
    r=Reader(data);result=[];units=0;ops=0;row_count=0;sequence=0
    while r.pos<r.end:
        offset=r.pos;unit=_unit(r);units+=1
        if units>MAX_UNITS:raise DebugError('resource_limit','Too many DWARF line units')
        version=unit.uint(2)
        if version!=4:_unsupported(f'DWARF line version {version} is unsupported')
        length=unit.uint(4);header=Reader(data,unit.pos,unit.pos+length);unit.pos+=length
        if unit.pos>unit.end:unit.bad()
        minimum=header.uint(1);maxops=header.uint(1)
        if maxops!=1:_unsupported('Line operation indexes greater than one are unsupported')
        default=header.uint(1);base=struct.unpack('b',header.take(1))[0];line_range=header.uint(1);opcode_base=header.uint(1)
        if minimum==0 or line_range==0 or default not in (0,1):header.bad()
        if opcode_base!=13:_unsupported('Only the standard DWARF v4 line opcode header is supported')
        standard=[header.uint(1) for _ in range(opcode_base-1)]
        if standard[:12]!=[0,1,1,1,1,0,0,0,1,0,0,1]:
            _unsupported('Unrecognized standard line opcode operand counts')
        dirs=['']
        while True:
            value=header.string()
            if not value:break
            dirs.append(value)
            if len(dirs)>4096:raise DebugError('resource_limit','Too many source directories')
        files=[('',0)]
        def file_entry(reader):
            name=reader.string()
            if not name:return False
            directory=reader.leb();reader.leb();reader.leb()
            if directory>=len(dirs):reader.bad()
            files.append((name,directory))
            if len(files)>65536:raise DebugError('resource_limit','Too many source files')
            return True
        while file_entry(header):pass
        if header.pos!=header.end:header.bad()
        address=0;file=1;line=1;column=0;discriminator=0;rows=[];path_cache={}
        def emit(end_sequence=False):
            nonlocal rows,row_count,sequence
            row_count+=1
            if row_count>MAX_ROWS:raise DebugError('resource_limit','DWARF rows exceed 200000')
            if not 0<=address<(1<<64) or not 0<=line<(1<<31) or not 0<=column<(1<<31) or not 0<=discriminator<(1<<31):unit.bad()
            if rows and address<rows[-1][0]:unit.bad()
            if end_sequence:
                # Group equal-PC rows; all remain candidates for the next span.
                groups=[]
                for item in rows:
                    if groups and groups[-1][0][0]==item[0]:groups[-1].append(item)
                    else:groups.append([item])
                for index,group in enumerate(groups):
                    end=groups[index+1][0][0] if index+1<len(groups) else address
                    for pc,filename,number,col,disc in group:
                        if pc<end:result.append(LineRange(pc,end,filename,number,col,disc,sequence))
                sequence+=1;rows=[];return
            if not 1<=file<len(files):unit.bad()
            if file not in path_cache:
                name,dirindex=files[file]
                path=posixpath.join(dirs[dirindex],name)
                compdir=directories.get(offset,'')
                if not posixpath.isabs(path) and compdir:path=posixpath.join(compdir,path)
                path=posixpath.normpath(path)
                if len(path)>MAX_STR:raise DebugError('resource_limit','Source path exceeds limit')
                path_cache[file]=path
            path=path_cache[file]
            rows.append((address,path,line,column,discriminator))
        while unit.pos<unit.end:
            ops+=1
            if ops>MAX_OPS:raise DebugError('resource_limit','DWARF line operation budget exhausted')
            op=unit.uint(1)
            if op==0:
                size=unit.leb();ext=Reader(data,unit.pos,unit.pos+size);unit.pos+=size
                if size==0 or unit.pos>unit.end:unit.bad()
                kind=ext.uint(1)
                if kind==1:
                    emit(True);address=0;file=1;line=1;column=0;discriminator=0
                elif kind==2:address=ext.uint(8)
                elif kind==3:
                    if not file_entry(ext):ext.bad()
                elif kind==4:discriminator=ext.leb()
                else:_unsupported(f'Unknown extended line opcode {kind}')
                if ext.pos!=ext.end:ext.bad()
            elif op>=opcode_base:
                adjusted=op-opcode_base;address+=(adjusted//line_range)*minimum;line+=base+adjusted%line_range
                emit();discriminator=0
            elif op==1:emit();discriminator=0
            elif op==2:address+=unit.leb()*minimum
            elif op==3:line+=unit.leb(True)
            elif op==4:file=unit.leb()
            elif op==5:column=unit.leb()
            elif op in (6,7,10,11):pass # Statement/basic/prologue flags do not change a source location.
            elif op==8:address+=((255-opcode_base)//line_range)*minimum
            elif op==9:address+=unit.uint(2)
            elif op==12:
                if unit.leb()!=0:_unsupported('Nonzero line-table ISA variants are not interpreted')
            else:_unsupported(f'Unknown standard line opcode {op}')
        if rows:unit.bad() # Never extrapolate past an unterminated sequence.
    return result
