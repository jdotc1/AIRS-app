#!/usr/bin/env python3
"""Focused C11/C12 experiment, trusting retained local C13 identities/outcomes.

Not a general cache: identity is inherited, not freshly verified. Reevaluate
only _airs_branch; do not hash/rebuild images or repeat CFI/compact checks.
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
from airs import ANALYSIS_MODEL_VERSION
from airs.cfg import audit_current_function
from airs.coverage import coverage_inventory
from airs.engine import GLOBAL_LIMITATIONS, _serialize_evidence
from airs.report import dumps, load_report, validate_report
from airs.types import FunctionRange, Limits, MachOImage, Section, UnwindEntry


def evaluate(corpus: Path, receipts: Path, destination: Path) -> dict:
    destination.mkdir(parents=True,exist_ok=True)
    reports=[];records=[]
    for build in ('O0','O2'):
        prior=receipts/f'owned-{build}-cfi.audit.json'
        report=load_report(prior);identity=report['image']
        if report['generator']['analysis_model_version']!='arm64-linear-dwarf-v2':
            raise ValueError('Expected retained C13 v2 output')
        commands=(corpus/f'owned-{build}-load-commands.txt').read_text()
        pattern=r'sectname __text\s+segname __TEXT\s+addr (0x[0-9a-fA-F]+)\s+size (0x[0-9a-fA-F]+)\s+offset (\d+)'
        address,size,offset=re.findall(pattern,commands)[0]
        section=Section('__TEXT','__text',int(address,16),int(size,16),int(offset),0)
        data=(corpus/identity['display_name']).read_bytes()
        if identity['slice_offset']!=0 or len(data)!=identity['slice_size']:
            raise ValueError('Harness accepts only the retained thin corpus with recorded length')
        functions=tuple(FunctionRange(int(f['function']['address'],16),int(f['function']['end_address'],16),f['function']['name'],f['function']['boundary_source']) for f in report['findings'])
        image=MachOImage(data,str(corpus/identity['display_name']),identity['container_sha256'],identity['slice_sha256'],0,len(data),identity['architecture'],identity['cpu_subtype'],identity['uuid'],int(identity['preferred_base'],16),6,(section,),functions)
        new_finding=None
        for finding,fn in zip(report['findings'],functions):
            if fn.name=='_airs_branch':
                candidates=[r for r in report['metadata_ranges'] if int(r['start'],16)<=fn.start<int(r['end'],16)]
                if len(candidates)!=1:raise ValueError('Expected one retained compact range')
                item=candidates[0];entry=UnwindEntry(int(item['start'],16),int(item['end'],16),int(item['encoding'],16),0)
                result=audit_current_function(image,fn,entry)
                finding.update(verdict=result.verdict,coverage=result.coverage,mode=result.mode,scope=result.scope,
                               reason_codes=list(result.reason_codes),checked_pcs=[hex(pc) for pc in result.checked_pcs],
                               instruction_count=result.instruction_count,evidence=[_serialize_evidence(e) for e in result.evidence],limitations=list(result.limitations))
                # Expected PCs are independently selected from saved disassembly.
                expected=([0x38c,0x390,0x394,0x398,0x39c,0x3a0,0x3a4,0x3a8,0x3ac,0x3b0,0x3b4,0x3b8,0x3bc,0x3c0]
                          if build=='O0' else [0x388,0x38c,0x390,0x394])
                if result.verdict!='agreement' or list(result.checked_pcs)!=expected:
                    raise ValueError(f'New branch result does not match independent expectations: {finding}')
                new_finding=finding
            key=f"1:{ANALYSIS_MODEL_VERSION}:{image.slice_sha256}:{image.architecture}:{fn.start:x}:{fn.end:x}"
            finding['id']='airsf-'+hashlib.sha256(key.encode()).hexdigest() # new derived ID only
        if new_finding is None:raise ValueError('Owned branch function missing from denominator')
        report['generator']['analysis_model_version']=ANALYSIS_MODEL_VERSION
        report['analysis_config']={'limits':asdict(Limits())}
        report['limitations']=GLOBAL_LIMITATIONS+['Only the branch function was reevaluated for v3; image identity and other three outcomes inherit prior receipts. Original images were not re-hashed.']
        report['verification_reuse']={'identity_status':'inherited_from_prior_receipt_not_rehashed',
                                      'outcome_receipt':str(prior.relative_to(ROOT)),
                                      'reevaluated_functions':['_airs_branch'],
                                      'reused_semantics_functions':[f.name for f in functions if f.name!='_airs_branch']}
        counts=Counter(f['verdict'] for f in report['findings'])
        for verdict in ('agreement','inconsistency','unresolved'):report['summary'][verdict+'_count']=counts[verdict]
        report['summary']['checked_pc_count']=sum(len(f['checked_pcs']) for f in report['findings'])
        validate_report(report)
        with (destination/f'owned-{build}-cfg.audit.json').open('x') as handle:handle.write(dumps(report))
        reports.append(report)
        records.append({'build':build,'image_identity':identity,'summary':report['summary'],
                        'branch_finding':new_finding,'identity_status':'reused_prior_receipt_not_reverified',
                        'original_image_hash_recomputed':False,'other_functions_reanalyzed':False,
                        'independent_instruction_receipt':str((corpus/f'owned-{build}-disassembly.txt').relative_to(ROOT))})
    with (destination/'coverage-inventory.json').open('x') as handle:handle.write(dumps(coverage_inventory(reports)))
    results={'analysis_model':ANALYSIS_MODEL_VERSION,'records':records,'corpus_rebuilt':False,'inspected_images_executed':False}
    with (destination/'results.json').open('x') as handle:handle.write(dumps(results))
    return results


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--corpus',type=Path,default=ROOT/'build/owned-toolchain-fixed')
    parser.add_argument('--receipts',type=Path,default=ROOT/'build/c13-evidence')
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args()
    print(json.dumps(evaluate(args.corpus.resolve(),args.receipts.resolve(),args.output_dir.resolve()),indent=2))
