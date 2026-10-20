#!/usr/bin/env python3
"""C13 focused corpus experiment using recorded identity/layout receipts.

This is a development evidence harness, not a general cache or audit command.
It trusts the retained local corpus and its prior identity receipt. It does not
re-hash images, rebuild them, or assert newly verified identity. Only DWARF
findings are re-evaluated; unchanged compact findings use the prior receipt.
Use ordinary `airs_cli.py audit` for new/unverified input files.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
ANALYSIS_MODEL_VERSION = "arm64-linear-dwarf-v2"  # Freeze this historical experiment's semantics.
from airs.audit import audit_function
from airs.coverage import coverage_inventory
from airs.dwarf_cfi import parse_eh_frame
from airs.engine import GLOBAL_LIMITATIONS, _serialize_evidence
from airs.report import dumps, load_report, validate_report
from airs.types import FunctionRange, Limits, MachOImage, Section, UnwindEntry


def evaluate(corpus: Path, destination: Path) -> dict:
    destination.mkdir(parents=True,exist_ok=True)
    reports=[]; records=[]
    for build in ('O0','O2'):
        receipt=corpus/f'owned-{build}-audit.json'
        report=load_report(receipt); identity=report['image']
        if report['generator']['analysis_model_version']!='arm64-linear-v1':
            raise ValueError('Expected the retained first-build v1 receipt')
        commands=(corpus/f'owned-{build}-load-commands.txt').read_text()
        sections=[]
        pattern=r'sectname (\S+)\s+segname (\S+)\s+addr (0x[0-9a-fA-F]+)\s+size (0x[0-9a-fA-F]+)\s+offset (\d+)'
        for name,segment,address,size,offset in re.findall(pattern,commands):
            if name in ('__text','__eh_frame'):
                sections.append(Section(segment,name,int(address,16),int(size,16),int(offset),0))
        data=(corpus/identity['display_name']).read_bytes()
        if len(data)!=identity['slice_size'] or identity['slice_offset']!=0:
            raise ValueError('Harness only accepts the retained thin corpus with its recorded byte length')
        functions=tuple(FunctionRange(int(f['function']['address'],16),int(f['function']['end_address'],16),f['function']['name'],f['function']['boundary_source']) for f in report['findings'])
        image=MachOImage(data,str(corpus/identity['display_name']),identity['container_sha256'],identity['slice_sha256'],0,len(data),identity['architecture'],identity['cpu_subtype'],identity['uuid'],int(identity['preferred_base'],16),6,tuple(sections),functions)
        table=parse_eh_frame(image)
        changed=[]; reused=[]; rows=[]
        for finding,fn in zip(report['findings'],functions):
            if finding['mode']=='dwarf':
                ranges=[r for r in report['metadata_ranges'] if int(r['start'],16)<=fn.start< int(r['end'],16)]
                if len(ranges)!=1: raise ValueError('Expected one recorded compact range')
                r=ranges[0]; entry=UnwindEntry(int(r['start'],16),int(r['end'],16),int(r['encoding'],16),0)
                outcome=audit_function(image,fn,entry,cfi_table=table)
                finding.update(verdict=outcome.verdict,coverage=outcome.coverage,mode=outcome.mode,scope=outcome.scope,
                               reason_codes=list(outcome.reason_codes),checked_pcs=[hex(pc) for pc in outcome.checked_pcs],
                               instruction_count=outcome.instruction_count,evidence=[_serialize_evidence(e) for e in outcome.evidence],limitations=list(outcome.limitations))
                fde=table.select(entry.encoding&0xffffff,fn)
                rows.append({'function':fn.name,'fde_offset':hex(fde.offset),'range':[hex(fde.start),hex(fde.end)],
                             'checked': [{'pc':hex(pc),'row_pc':hex(fde.row_at(pc).pc),'rule':fde.row_at(pc).describe()} for pc in outcome.checked_pcs]})
                changed.append(fn.name)
            else:
                # Only the old blanket CFI limitation no longer describes v2.
                finding['limitations']=[item.replace('DWARF FDE evaluation, ','CFI outside the bounded subset, ') for item in finding['limitations']]
                reused.append(fn.name)
            key=f"1:{ANALYSIS_MODEL_VERSION}:{image.slice_sha256}:{image.architecture}:{fn.start:x}:{fn.end:x}"
            finding['id']='airsf-'+hashlib.sha256(key.encode()).hexdigest()  # derived ID, not image hashing
        report['generator']['analysis_model_version']=ANALYSIS_MODEL_VERSION
        report['analysis_config']={'limits':asdict(Limits())}
        for issue in report['issues']:
            if issue['code']=='dwarf_metadata_only':
                issue['message']='The retained compact metadata receipt records an FDE reference; see each finding for v2 CFI evaluation status'
        report['limitations']=GLOBAL_LIMITATIONS + ['Corpus image identity and unchanged compact outcomes are inherited from prior receipts; original bytes were not re-hashed for this focused experiment.']
        counts=Counter(f['verdict'] for f in report['findings'])
        for verdict in ('agreement','inconsistency','unresolved'):report['summary'][verdict+'_count']=counts[verdict]
        report['summary']['checked_pc_count']=sum(len(f['checked_pcs']) for f in report['findings'])
        report['verification_reuse']={'identity_status':'inherited_from_prior_receipt_not_rehashed',
                                      'identity_receipt':str(receipt.relative_to(ROOT)),
                                      'reevaluated_functions':changed,'reused_semantics_functions':reused}
        validate_report(report)
        output=destination/f'owned-{build}-cfi.audit.json'
        with output.open('x') as handle:handle.write(dumps(report))
        reports.append(report)
        records.append({'build':build,'image_identity':identity,'summary':report['summary'],'rows':rows,
                        'identity_status':'reused_prior_receipt_not_reverified','original_image_hash_recomputed':False,
                        'compact_functions_reanalyzed':False,'independent_cfi_receipt':f'owned-{build}-eh-frame.txt'})
    with (destination/'coverage-inventory.json').open('x') as handle:handle.write(dumps(coverage_inventory(reports)))
    result={'analysis_model':ANALYSIS_MODEL_VERSION,'records':records,'corpus_rebuilt':False,'inspected_images_executed':False}
    with (destination/'results.json').open('x') as handle:handle.write(dumps(result))
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--corpus',type=Path,default=ROOT/'build/owned-toolchain-fixed')
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args()
    print(json.dumps(evaluate(args.corpus.resolve(),args.output_dir.resolve()),indent=2))
