"""Identity-gated, source-only dSYM annotations on an existing audit.

The selected image digest remains code identity. dSYM UUID is a build association,
not a signature or equality of artifact bytes. Nothing here evaluates unwind CFI,
changes findings, discovers functions, or executes selected artifacts/tools.
"""
from __future__ import annotations

from collections import Counter
import copy
import heapq
from pathlib import Path
import posixpath
import uuid

from .debug_macho import DebugError, MAX_DEBUG_BYTES, read_slices
from .dwarf_line import compilation_directories, parse_lines
from .types import InputError

STATUSES=frozenset(('matched','missing_dsym','missing_image_uuid','missing_dsym_uuid',
    'uuid_mismatch','architecture_mismatch','ambiguous_dsym','missing_line_table',
    'invalid_dsym','invalid_debug_data','unsupported_debug_format','resource_limit'))
FUNCTION_STATUSES=frozenset(('mapped','ambiguous_line','no_line_entry'))
SOURCE_STATUSES=frozenset(('available_unverified','missing','unavailable','relative_path_unresolved'))
IDENTITY_KEYS=('architecture','cpu_subtype','uuid','slice_sha256','preferred_base','container_sha256','slice_offset','slice_size')
LIMITATIONS=[
    'Source locations annotate existing preferred PCs; they do not change function boundaries, findings, checked scope or verdicts.',
    'Only bounded DWARF32 v4 line tables and v4 CU root paths are read. DWARF CFI and inline DIE chains are not evaluated.',
    'UUID and exact architecture/subtype associate the selected dSYM with the recorded image; the dSYM is a different artifact from the audited code slice.',
    'Source availability is a local observation. Source file contents are not verified against the build.',
    'Source labels do not establish cross-build function identity.'
]


def _identity(image):return {key:image.get(key) for key in IDENTITY_KEYS}


def _candidates(path: Path):
    if not path.exists():raise DebugError('missing_dsym','The selected dSYM is unavailable')
    if path.is_file():return [path]
    folder=path/'Contents/Resources/DWARF'
    if not folder.is_dir():raise DebugError('missing_dsym','No dSYM DWARF directory was found')
    paths=[]
    for entry in folder.iterdir():
        if len(paths)>=128:raise DebugError('resource_limit','More than 128 dSYM candidates')
        if entry.is_file():paths.append(entry)
        else:raise DebugError('invalid_dsym','Unexpected entry in dSYM DWARF directory')
    if not paths:raise DebugError('missing_dsym','The dSYM has no DWARF files')
    return sorted(paths)


def _read(path,remaining):
    if path.stat().st_size>remaining:raise DebugError('resource_limit','Combined dSYM candidates exceed 128 MiB')
    with path.open('rb') as file:data=file.read(remaining+1)
    if len(data)>remaining:raise DebugError('resource_limit','Combined dSYM candidates exceed 128 MiB')
    return data


def attach_dsym(report: dict, path: Path | str) -> dict:
    from .report import validate_report
    validate_report(report)
    result=copy.deepcopy(report)
    image=report['image']
    annotations={'schema_version':1,'status':'missing_dsym','image_identity':_identity(image),
        'attachment':None,'inline_chain':'not_evaluated','functions':[],
        'message':'','limitations':list(LIMITATIONS)}
    result['source_annotations']=annotations
    try:
        if not image.get('uuid'):raise DebugError('missing_image_uuid','The recorded image has no UUID; symbols cannot be attached')
        target_uuid=str(uuid.UUID(image['uuid']))
        candidates=[];remaining=MAX_DEBUG_BYTES
        for file in _candidates(Path(path)):
            data=_read(file,remaining);remaining-=len(data)
            for item in read_slices(data):candidates.append((file,item))
        architecture=[(file,item) for file,item in candidates if item.cpu==0x100000c and item.subtype==image['cpu_subtype']
                      and ({0:'arm64',1:'arm64',2:'arm64e'}.get(item.subtype&0xffffff))==image['architecture']]
        if not architecture:raise DebugError('architecture_mismatch','No dSYM slice matches the exact recorded architecture/subtype')
        matching=[(file,item) for file,item in architecture if item.uuid==target_uuid]
        if len(matching)>1:raise DebugError('ambiguous_dsym','More than one dSYM candidate matches; no source lookup was selected')
        if not matching:
            if any(item.uuid is None for _,item in architecture):raise DebugError('missing_dsym_uuid','A matching-architecture dSYM has no UUID')
            raise DebugError('uuid_mismatch','No dSYM UUID matches the recorded image')
        file,item=matching[0]
        annotations['attachment']={'path':str(file.resolve()),'architecture':image['architecture'],
            'cpu_subtype':item.subtype,'uuid':item.uuid,'slice_sha256':item.digest,
            'slice_offset':item.offset,'slice_size':item.size}
        if not item.sections.get('__debug_line'):raise DebugError('missing_line_table','The matching dSYM has no line table')
        directories=compilation_directories(item.sections)
        rows=parse_lines(item.sections['__debug_line'],directories)
        names=Counter(f['function']['name'] for f in report['findings'])
        # Sweep line intervals and query PCs once. Avoid findings × line-row work.
        ordered=sorted(enumerate(rows),key=lambda pair:(pair[1].start,pair[0]))
        index=0;active={};expires=[];candidate_heap=[];mapped={};source_cache={}
        for finding in sorted(report['findings'],key=lambda f:int(f['function']['address'],16)):
            pc=int(finding['function']['address'],16)
            while index<len(ordered) and ordered[index][1].start<=pc:
                key,row=ordered[index];active[key]=row;heapq.heappush(expires,(row.end,key));heapq.heappush(candidate_heap,key);index+=1
            while expires and expires[0][0]<=pc:
                _,key=heapq.heappop(expires);active.pop(key,None)
            entries=[]
            selected=[]
            while candidate_heap and len(selected)<8:
                key=heapq.heappop(candidate_heap)
                if key in active:selected.append(key)
            for key in selected:heapq.heappush(candidate_heap,key)
            for key in selected:
                row=active[key]
                if row.path not in source_cache:
                    if not posixpath.isabs(row.path):state='relative_path_unresolved'
                    else:
                        try:state='available_unverified' if Path(row.path).is_file() else 'missing'
                        except OSError:state='unavailable'
                    source_cache[row.path]=state
                entries.append({'path':row.path,'line':row.line,'column':row.column,
                    'discriminator':row.discriminator,'source_status':source_cache[row.path]})
            status='mapped' if len(active)==1 else 'ambiguous_line' if active else 'no_line_entry'
            mapped[finding['id']]={'finding_id':finding['id'],'pc':finding['function']['address'],'status':status,
                'name_status':'duplicate' if names[finding['function']['name']]>1 else 'unique',
                'candidate_count':len(active),'locations':entries}
        annotations['functions']=[mapped[f['id']] for f in report['findings']]
        annotations['status']='matched'
        annotations['message']='dSYM UUID and architecture/subtype match. Locations describe function-entry PCs only; inline chains are not evaluated.'
    except DebugError as error:
        annotations['status']=error.code;annotations['message']=str(error)
    except (OSError,UnicodeError,ValueError) as error:
        annotations['status']='invalid_dsym';annotations['message']=f'The selected debug artifact could not be read: {type(error).__name__}'
    validate_annotations(annotations,report)
    return result


def validate_annotations(value: object, report: dict) -> None:
    def bad():raise InputError('invalid_source_annotations','Source annotations are malformed or do not match the audit image/findings')
    def string(v):return isinstance(v,str) and len(v)<=4096 and '\0' not in v
    def integer(v):return type(v) is int and 0<=v<(1<<31)
    if not isinstance(value,dict) or type(value.get('schema_version')) is not int or value['schema_version']!=1:bad()
    if not isinstance(value.get('status'),str) or value.get('status') not in STATUSES or value.get('inline_chain')!='not_evaluated':bad()
    identity=value.get('image_identity')
    if not isinstance(identity,dict) or any(key not in identity or identity[key]!=report['image'].get(key) for key in IDENTITY_KEYS):bad()
    if any(type(value['image_identity'].get(k)) is not int for k in ('cpu_subtype','slice_offset','slice_size')):bad()
    if not string(value.get('message')) or not isinstance(value.get('limitations'),list) or len(value['limitations'])>32 or not all(string(v) for v in value['limitations']):bad()
    attachment=value.get('attachment')
    requires_attachment=('matched','missing_line_table','invalid_debug_data','unsupported_debug_format')
    if value['status'] in requires_attachment and attachment is None:bad()
    if attachment is not None and value['status'] not in (*requires_attachment,'resource_limit'):bad()
    if attachment is not None:
        if not isinstance(attachment,dict) or type(attachment.get('cpu_subtype')) is not int:bad()
        for key in ('architecture','cpu_subtype'):
            if attachment.get(key)!=report['image'][key]:bad()
        try:
            if uuid.UUID(attachment.get('uuid'))!=uuid.UUID(report['image']['uuid']):bad()
        except (ValueError,TypeError,AttributeError):bad()
        import re
        if not isinstance(attachment.get('slice_sha256'),str) or not re.fullmatch('[0-9a-f]{64}',attachment['slice_sha256']):bad()
        if not string(attachment.get('path')) or not posixpath.isabs(attachment['path']):bad()
        if not integer(attachment.get('slice_offset')) or not integer(attachment.get('slice_size')) or attachment['slice_size']>MAX_DEBUG_BYTES:bad()
    entries=value.get('functions')
    if not isinstance(entries,list) or len(entries)>50000:bad()
    if value['status']!='matched':
        if entries:bad()
        return
    if attachment is None or len(entries)!=len(report['findings']):bad()
    findings={f['id']:f for f in report['findings']};seen=set()
    names=Counter(f['function']['name'] for f in report['findings'])
    for entry in entries:
        if not isinstance(entry,dict) or not isinstance(entry.get('finding_id'),str):bad()
        finding=findings.get(entry['finding_id'])
        if finding is None or entry['finding_id'] in seen:bad()
        seen.add(entry['finding_id'])
        if entry.get('pc')!=finding['function']['address'] or not isinstance(entry.get('status'),str) or entry.get('status') not in FUNCTION_STATUSES or entry.get('name_status')!=('duplicate' if names[finding['function']['name']]>1 else 'unique'):bad()
        count=entry.get('candidate_count');locations=entry.get('locations')
        if not integer(count) or count>200000 or not isinstance(locations,list) or len(locations)!=min(count,8):bad()
        if entry['status']!=('mapped' if count==1 else 'ambiguous_line' if count>1 else 'no_line_entry'):bad()
        for location in locations:
            if not isinstance(location,dict) or not string(location.get('path')) or not location['path'] or not isinstance(location.get('source_status'),str) or location.get('source_status') not in SOURCE_STATUSES:bad()
            if any(not integer(location.get(key)) for key in ('line','column','discriminator')):bad()
            if (location['source_status']=='relative_path_unresolved')==posixpath.isabs(location['path']):bad()
