"""Bounded decode-only inventory: no state interpretation or unwind verdicts."""
from __future__ import annotations

from collections import Counter
from dataclasses import asdict, replace
from pathlib import Path
import struct

from . import ANALYSIS_MODEL_VERSION
from .arm64 import ModelError
from .cfg import decode_instruction
from .engine import resolve_input
from .macho import parse_macho
from .types import InputError, Limits, MachOImage

DEFAULT_LIMITS = replace(Limits(), max_file_bytes=8*1024*1024, max_functions=1024,
                         max_instructions_per_function=4096, max_total_instructions=16384,
                         max_evidence_per_function=32, max_total_evidence=256)


def decode_inventory(image: MachOImage, limits: Limits = DEFAULT_LIMITS) -> dict:
    if len(image.functions)>limits.max_functions:
        raise InputError('inventory_limit','Function inventory exceeds the configured limit')
    remaining_words=limits.max_total_instructions
    remaining_evidence=limits.max_total_evidence
    rows=[];reasons=Counter()
    ordinary=image.architecture=='arm64' and image.cpu_subtype in (0,1)
    for function in image.functions:
        row={'function':{'name':function.name,'address':hex(function.start),
                         'end_address':hex(function.end),'image_offset':hex(function.start-image.preferred_base),
                         'size':function.size,'boundary_source':function.boundary_source},
             'scan_status':'complete','word_scan_complete':False,'blockers_complete':False,
             'observed_word_count':0,'decoder_admitted_word_count':0,'decline_count':0,
             'omitted_decline_count':0,'blockers':[]}
        rows.append(row)
        if not ordinary:
            row['scan_status']='excluded_architecture';continue
        if function.boundary_source!='lc_function_starts':
            row['scan_status']='excluded_boundary';continue
        if function.start<0 or function.size<=0 or function.start%4 or function.size%4:
            row['scan_status']='invalid_extent';continue
        words=function.size//4
        count=min(words,limits.max_instructions_per_function,remaining_words)
        if count<words:
            row['scan_status']='partial_total_budget' if remaining_words<=limits.max_instructions_per_function else 'partial_function_budget'
        if count:
            try:data=image.bytes_at(function.start,count*4)
            except InputError:
                row['scan_status']='unmapped_bytes';continue
            for index,(word,) in enumerate(struct.iter_unpack('<I',data)):
                address=function.start+index*4
                row['observed_word_count']+=1;remaining_words-=1
                try:decode_instruction(word,address)
                except ModelError as error:
                    row['decline_count']+=1;reasons[error.code]+=1
                    if len(row['blockers'])<limits.max_evidence_per_function and remaining_evidence:
                        row['blockers'].append({'address':hex(address),'word':f'0x{word:08x}',
                                                'reason':error.code,'message':str(error)})
                        remaining_evidence-=1
                else:row['decoder_admitted_word_count']+=1
        row['word_scan_complete']=count==words
        row['omitted_decline_count']=row['decline_count']-len(row['blockers'])
        row['blockers_complete']=row['word_scan_complete'] and row['omitted_decline_count']==0
    issues=[{'code':i.code,'message':i.message,**({'offset':i.offset} if i.offset is not None else {})} for i in image.issues]
    complete=all(r['blockers_complete'] for r in rows) and not issues
    return {'schema_version':1,'report_kind':'airs.decode_inventory',
            'decoder_model':ANALYSIS_MODEL_VERSION,'status':('no_functions' if not rows else 'complete' if complete else 'partial'),
            'address_space':'preferred_vm','analysis_config':{'limits':asdict(limits)},
            'image':{'display_name':Path(image.path).name,'container_sha256':image.container_sha256,
                     'slice_sha256':image.slice_sha256,'architecture':image.architecture,
                     'cpu_subtype':image.cpu_subtype,'uuid':image.uuid,'slice_offset':image.slice_offset,
                     'slice_size':image.slice_size,'preferred_base':hex(image.preferred_base),'file_type':image.file_type},
            'summary':{'function_count':len(rows),'fully_scanned_function_count':sum(r['word_scan_complete'] for r in rows),
                       'observed_word_count':sum(r['observed_word_count'] for r in rows),
                       'decoder_admitted_word_count':sum(r['decoder_admitted_word_count'] for r in rows),
                       'decline_count':sum(r['decline_count'] for r in rows),
                       'retained_blocker_count':sum(len(r['blockers']) for r in rows),
                       'omitted_decline_count':sum(r['omitted_decline_count'] for r in rows)},
            'reasons':[{'reason':key,'observed_count':value} for key,value in sorted(reasons.items())],
            'functions':rows,'issues':issues,
            'limitations':['Decode-only inventory; no state, reachability, metadata, recovery, verdict or checked-PC claim.',
                           'A decoder-admitted word may still have unsupported effects or unknown values during an audit.',
                           'A decoder refusal is not a general ISA-validity classification.',
                           'Counts cover observed words only; incomplete scans and omitted blocker details remain explicit.',
                           'This selected input is not representative binary prevalence; no target code is loaded or executed.']}


def decode_inventory_path(path: Path | str, *, requested_arch: str = 'auto', limits: Limits = DEFAULT_LIMITS) -> dict:
    source=resolve_input(path)
    try:
        if source.stat().st_size>limits.max_file_bytes:
            raise InputError('file_size_limit','Input exceeds the decode inventory file limit')
        with source.open('rb') as handle:data=handle.read(limits.max_file_bytes+1)
    except OSError as error:
        raise InputError('unreadable_input',f'Cannot read input: {error}') from error
    if len(data)>limits.max_file_bytes:
        raise InputError('file_size_limit','Input grew beyond the decode inventory file limit')
    return decode_inventory(parse_macho(data,str(source),limits,requested_arch),limits)
