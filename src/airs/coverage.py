"""Inventory saved evidence; never re-audit binaries or infer representative prevalence."""
from __future__ import annotations

from collections import Counter, defaultdict
import json

from .types import InputError


def coverage_inventory(reports: list[dict]) -> dict:
    if len(reports)>128 or sum(len(r['findings']) for r in reports)>200000:
        raise InputError('inventory_limit','Inventory is limited to 128 reports and 200000 findings')
    groups=defaultdict(list);records=[];counts=Counter();reasons={};models=Counter();conflicts=set()
    for index,report in enumerate(reports):
        image=report['image'];model=report['generator']['analysis_model_version'];config=report.get('analysis_config')
        key=(image['slice_sha256'],image['architecture'],image['cpu_subtype'],model,json.dumps(config,sort_keys=True))
        record={'index':index,'image':{k:image.get(k) for k in ('display_name','slice_sha256','architecture','cpu_subtype','uuid')},
            'model':model,'analysis_config':config,'summary':report['summary'],'duplicate_of':None}
        for earlier,previous in groups[key]:
            if all(previous.get(k)==report.get(k) for k in ('findings','summary','metadata_ranges','issues')):
                record['duplicate_of']=earlier;break
        if record['duplicate_of'] is not None:
            counts['duplicate_report_count']+=1;records.append(record);continue
        if groups[key]:conflicts.update([index]+[earlier for earlier,_ in groups[key]])
        groups[key].append((index,report));records.append(record);models[model]+=1
        counts['function_count']+=len(report['findings'])
        for finding in report['findings']:
            counts[finding['verdict']+'_count']+=1
            if finding['verdict']!='unresolved':continue
            for reason in set(finding['reason_codes']):
                entry=reasons.setdefault(reason,{'reason':reason,'count':0,'examples':[]})
                entry['count']+=1
                if len(entry['examples'])<8:
                    entry['examples'].append({'report_index':index,'finding_id':finding['id'],
                        'function_name':finding['function']['name'],'pc':finding['function']['address'],
                        'scope':finding['scope'],'mode':finding['mode']})
    summary={key:counts[key] for key in ('duplicate_report_count','function_count','agreement_count','inconsistency_count','unresolved_count')}
    summary.update(input_report_count=len(reports),unique_image_model_config_count=len(groups),conflicting_report_count=len(conflicts))
    return {'schema_version':1,'report_kind':'airs.coverage_inventory','status':'conflicting_reports' if conflicts else 'complete',
        'summary':summary,'reports':records,'conflicting_report_indices':sorted(conflicts),
        'models':dict(sorted(models.items())),'reasons':sorted(reasons.values(),key=lambda r:(-r['count'],r['reason'])),
        'limitations':['This inventory describes only the supplied saved reports; it is not real-world prevalence.',
            'Duplicate image/model/configuration reports with equal findings are counted once; conflicting variants remain visible and are counted separately.',
            'Reason counts can overlap when an unresolved finding has multiple reasons. No semantic support is added.',
            'Symbols or source labels do not prove that functions across builds have the same source identity.']}
