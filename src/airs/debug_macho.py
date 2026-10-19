"""Read dSYM identity/debug sections as data; never load code or invoke tools."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import struct
import uuid

MAX_DEBUG_BYTES = 128 * 1024 * 1024


class DebugError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class DebugSlice:
    cpu: int
    subtype: int
    uuid: str | None
    digest: str
    offset: int
    size: int
    sections: dict[str, bytes]


def _extent(data: bytes, offset: int, size: int) -> None:
    if offset < 0 or size < 0 or offset > len(data) or size > len(data)-offset:
        raise DebugError('invalid_dsym', 'A debug Mach-O extent is outside the file')


def read_slices(data: bytes) -> list[DebugSlice]:
    if len(data) > MAX_DEBUG_BYTES:
        raise DebugError('resource_limit', 'Debug data exceeds 128 MiB')
    layouts = {b'\xca\xfe\xba\xbe':('>',False),b'\xbe\xba\xfe\xca':('<',False),
               b'\xca\xfe\xba\xbf':('>',True),b'\xbf\xba\xfe\xca':('<',True)}
    ranges = []
    if data[:4] in layouts:
        endian, wide = layouts[data[:4]]
        _extent(data,0,8)
        count=struct.unpack_from(endian+'I',data,4)[0]
        if not 1 <= count <= 128:
            raise DebugError('resource_limit','Unsupported number of debug slices')
        stride=32 if wide else 20
        _extent(data,8,count*stride)
        for index in range(count):
            values=struct.unpack_from(endian+('IIQQII' if wide else 'IIIII'),data,8+index*stride)
            cpu, subtype, offset, size, alignment=values[:5]
            if alignment > (63 if wide else 31) or offset % (1 << alignment) or offset < 8+count*stride or size < 32 or (wide and values[5]):
                raise DebugError('invalid_dsym','Invalid debug FAT directory')
            _extent(data,offset,size)
            ranges.append((offset,size,cpu,subtype))
        ordered=sorted(ranges)
        if any(a[0]+a[1] > b[0] for a,b in zip(ordered,ordered[1:])):
            raise DebugError('invalid_dsym','Overlapping debug slices')
    else:
        ranges=[(0,len(data),None,None)]
    return [_read_thin(data[offset:offset+size],offset,cpu,subtype) for offset,size,cpu,subtype in ranges]


def _read_thin(data: bytes, origin: int, declared_cpu: int | None, declared_subtype: int | None) -> DebugSlice:
    _extent(data,0,32)
    magic,cpu,subtype,filetype,ncmds,sizeofcmds,_,reserved=struct.unpack_from('<8I',data)
    if magic != 0xfeedfacf or filetype != 10 or reserved:
        raise DebugError('invalid_dsym','Expected a little-endian 64-bit MH_DSYM image')
    if declared_cpu is not None and (cpu,subtype)!=(declared_cpu,declared_subtype):
        raise DebugError('invalid_dsym','FAT and debug slice CPU identities disagree')
    if ncmds > 4096 or sizeofcmds > 16*1024*1024:
        raise DebugError('resource_limit','Debug load commands exceed the limit')
    _extent(data,32,sizeofcmds)
    end=32+sizeofcmds; cursor=32; ident=None;sections={};section_count=0;claims=[]
    for _ in range(ncmds):
        if cursor+8 > end:
            raise DebugError('invalid_dsym','Truncated debug load command')
        cmd,size=struct.unpack_from('<II',data,cursor)
        if size < 8 or size%8 or size > end-cursor:
            raise DebugError('invalid_dsym','Invalid debug load-command size')
        if cmd==0x1b:
            if size!=24 or ident is not None:
                raise DebugError('invalid_dsym','Duplicate or malformed debug UUID')
            ident=str(uuid.UUID(bytes=data[cursor+8:cursor+24]))
        elif cmd==0x19:
            if size < 72:
                raise DebugError('invalid_dsym','Truncated debug segment')
            nsects=struct.unpack_from('<I',data,cursor+64)[0]
            section_count+=nsects
            if section_count > 4096:
                raise DebugError('resource_limit','Too many debug sections')
            if 72+80*nsects != size:
                raise DebugError('invalid_dsym','Invalid debug section table')
            for item in range(nsects):
                row=cursor+72+80*item
                name,segment,_,length,offset,_,_,_,flags,_,_,_=struct.unpack_from('<16s16sQQIIIIIIII',data,row)
                if segment.rstrip(b'\0')!=b'__DWARF':
                    continue
                name=name.rstrip(b'\0').decode('ascii','strict')
                if name in sections or flags&0xff in (1,0xc,0x12):
                    raise DebugError('invalid_dsym','Duplicate or zerofill debug section')
                _extent(data,offset,length)
                if length and offset < end:
                    raise DebugError('invalid_dsym','Debug section overlaps load commands')
                if length:claims.append((offset,offset+length))
                sections[name]=data[offset:offset+length]
        cursor+=size
    if cursor!=end:
        raise DebugError('invalid_dsym','Debug load-command count/extent mismatch')
    ordered=sorted(claims)
    if any(a[1] > b[0] for a,b in zip(ordered,ordered[1:])):
        raise DebugError('invalid_dsym','Overlapping debug section data')
    return DebugSlice(cpu,subtype,ident,hashlib.sha256(data).hexdigest(),origin,len(data),sections)
