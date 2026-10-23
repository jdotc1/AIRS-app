"""Owned mixed-range data preparation; invoke only with specific run authority."""
from pathlib import Path
import struct
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests'))
from parser_helpers import build_macho, regular_unwind

# AIRS canonical frame/pair and owned direct-call/sink patterns. No target runs.
WORDS=(0xa9bf7bfd,0x910003fd,0x94000004,0x94000003,0xa8c17bfd,0xd65f03c0,0xd503201f,0xd65f03c0)
CASES={
    'single-range':((0x1000,0x04000000),(0x1018,0x02000000)),
    'split-equal':((0x1000,0x04000000),(0x100c,0x04000000),(0x1018,0x02000000)),
    'split-different':((0x1000,0x04000000),(0x100c,0x02001000),(0x1018,0x02000000)),
    'uncovered-prefix':((0x100c,0x04000000),(0x1018,0x02000000)),
}

def prepare(destination:Path):
    """Write new synthetic data only; never invokes compiler, decoder or audit."""
    destination.mkdir(parents=True,exist_ok=False)
    for name,entries in CASES.items():
        data=build_macho(struct.pack('<8I',*WORDS),function_offsets=(0,24),
                         symbols=(('_mixed_frame',0),('_owned_sink',24)),
                         unwind_info=regular_unwind(entries,0x1020))
        (destination/(name+'.macho')).write_bytes(data)

if __name__=='__main__':
    if len(sys.argv)!=2:raise SystemExit('Supply one new output directory')
    prepare(Path(sys.argv[1]))
