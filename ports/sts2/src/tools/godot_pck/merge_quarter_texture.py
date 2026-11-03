#!/usr/bin/env python3
# INPUT: fixed source/main, audited texture inventory and reviewed quarter delta/report
# OUTPUT: source-bound immutable main with only quality-accepted visual textures changed
# POS: offline merge gate; leaves all source and current packs unchanged
import argparse
import hashlib
import json
from pathlib import Path
import sys

import low_texture_overlay as low
import merge_texture_pck as merge
import quarter_texture_overlay as quarter
import windows_texture_overlay as windows

# Populated only after the complete output and independent review are frozen.
DELTA_SHA = '49dc4dcb42e4fceb74e74d340e8bdfa5a0bec1c8d132fb1ee570d78521620c09'
REPORT_SHA = '098e3a99f952c2f426df32586d403c260e8f0c4d46396cc7ce2e45c7cd1f75f0'
MAIN_SHA = '7ec4bb3f96fd01dc42bde20b6daa2f98cd16f09cec3b8ef404efd53f089615f1'


def prepare(source, base, texture_report, delta, delta_report, godot, outdir):
    supplied=[Path(p) for p in (source,base,texture_report,delta,delta_report,godot,quarter.SPECS)]
    if any(p.is_symlink() for p in supplied):raise ValueError('quarter inputs must not be symlinks')
    paths=[p.resolve(strict=True) for p in supplied]
    if any(a.samefile(b) for i,a in enumerate(paths) for b in paths[i+1:]):raise ValueError('quarter inputs must be distinct')
    source,base,texture_report,delta,delta_report,godot,specs=paths
    dest=Path(outdir).absolute();dest=dest.parent.resolve(strict=True)/dest.name
    if dest.exists() or dest.is_symlink() or any(dest==p or dest in p.parents for p in paths):raise ValueError('quarter output directory must be new and separate')
    if not all(isinstance(x,str) and len(x)==64 for x in (DELTA_SHA,REPORT_SHA,MAIN_SHA)):raise ValueError('quarter candidate identities are not frozen')
    for p,want in ((source,quarter.SOURCE_SHA),(base,quarter.MAIN_SHA),(texture_report,quarter.REPORT_SHA),(specs,quarter.SPECS_SHA),(delta,DELTA_SHA),(delta_report,REPORT_SHA)):
        if merge.sha256_file(p)!=want:raise ValueError('quarter input identity mismatch: '+str(p))
    baseline=json.loads(texture_report.read_text());data=json.loads(delta_report.read_text());spec=json.loads(specs.read_text())
    if (data.get('source_sha256')!=quarter.SOURCE_SHA or data.get('base_main_sha256')!=quarter.MAIN_SHA or data.get('texture_report_sha256')!=quarter.REPORT_SHA or
        data.get('specs_sha256')!=quarter.SPECS_SHA or data.get('godot_sha256')!=merge.sha256_file(godot) or data.get('delta_sha256')!=DELTA_SHA or
        data.get('builder_sha256')!=merge.sha256_file(Path(quarter.__file__)) or data.get('worker_sha256')!=merge.sha256_file(quarter.WORKER) or data.get('profile')!=quarter.PROFILE or
        baseline.get('source_sha256')!=quarter.SOURCE_SHA or spec.get('source_pck_sha256')!=quarter.SOURCE_SHA):
        raise ValueError('quarter provenance mismatch')
    raw_specs=spec.get('resources');items=baseline.get('resources');records=data.get('resources')
    if not all(isinstance(x,list) for x in (raw_specs,items,records)):raise ValueError('invalid quarter inventory')
    specs_by_target={x['target'][6:]:x for x in raw_specs}
    textures=[x for x in items if x.get('kind')=='texture']
    if len(specs_by_target)!=len(raw_specs) or len({x['path'] for x in textures})!=len(textures):raise ValueError('duplicate quarter inventory path')
    source_entries,base_entries,delta_entries=map(low.read_pack,(source,base,delta)); by_target={}
    for item in records:
        target=item.get('target')
        if not isinstance(target,str) or not target.startswith('res://') or target[6:] in by_target:raise ValueError('duplicate or invalid report path')
        by_target[target[6:]]=item
    with source.open('rb') as src,base.open('rb') as main,delta.open('rb') as overlay:
        mapping,imports,spines,fonts=windows.windows_import_map(src,source_entries)
        if set(specs_by_target)!=set(mapping):raise ValueError('quarter mapping inventory differs')
        expected={x['path']:quarter.classify(specs_by_target[x['path']],x) for x in textures}
        expected={k:v for k,v in expected.items() if v}
        if set(by_target)!=set(expected) or data.get('candidate_count')!=len(expected):raise ValueError('quarter report candidate set mismatch')
        by_texture={x['path']:x for x in textures};accepted={}
        for name,role in expected.items():
            record=by_target[name];original_item=by_texture[name];audited=specs_by_target[name]
            if (name not in source_entries or name not in base_entries or mapping[name][0]!=original_item['source_path'] or audited['source']!='res://'+original_item['source_path'] or
                low.protected(name,mapping,spines,fonts,True)):
                raise ValueError('quarter source mapping or protection mismatch: '+name)
            before=low.entry_bytes(src,source_entries[name]);current=low.entry_bytes(main,base_entries[name]);h=low.texture_header(before);old=low.parse_texture(current)
            if (record.get('source')!=audited['source'] or record.get('role')!=role or low.digest(before)!=audited['source_sha256'] or low.digest(before)!=original_item['source_sha256'] or
                record.get('source_sha256')!=low.digest(before) or record.get('source_md5')!=low.digest(before,'md5') or
                record.get('base_sha256')!=low.digest(current) or record.get('base_md5')!=low.digest(current,'md5') or
                h!=record.get('input') or h!=original_item['input'] or old!=record.get('base') or old!=original_item.get('output',original_item['input']) or
                low.digest(current,'md5')!=original_item.get('output_md5',original_item['source_md5'])):
                raise ValueError('quarter texture identity or header mismatch: '+name)
            q=record.get('quality');quarter.validate_quality(q,h)
            if q['status']=='accepted':
                if name not in delta_entries:raise ValueError('missing accepted quarter entry')
                result=low.entry_bytes(overlay,delta_entries[name]);after=quarter.verify_output(result,h)
                if (after!=record.get('output') or low.digest(result)!=record.get('output_sha256') or low.digest(result)!=q.get('output_sha256') or
                    low.digest(result,'md5')!=record.get('output_md5')):raise ValueError('quarter output identity mismatch: '+name)
                w,ht=after['gpu'];size=52+((w+7)//8)*((ht+7)//8)*16
                if len(result)!=size:raise ValueError('quarter ASTC payload size mismatch: '+name)
                accepted[name]=record
            elif any(k in record for k in ('output','output_sha256','output_md5')) or name in delta_entries:
                raise ValueError('quality-rejected quarter entry was included: '+name)
        if not accepted or set(accepted)!=set(delta_entries) or len(accepted)!=data.get('accepted_count') or len(expected)-len(accepted)!=data.get('quality_rejected_count'):
            raise ValueError('quarter accepted set/count mismatch')
    dest.mkdir();adapter=dest/'merge-input.json'
    adapter.write_text(json.dumps({'source_sha256':quarter.MAIN_SHA,'output_sha256':DELTA_SHA,'resources':[
        {'path':n,'output_md5':v['output_md5']} for n,v in sorted(accepted.items())]})+'\n')
    result=merge.prepare(base,delta,adapter,dest/'packs')
    if result.stem!=MAIN_SHA:raise ValueError('quarter merged main differs from audited SHA')
    provenance={'source_sha256':quarter.SOURCE_SHA,'base_main_sha256':quarter.MAIN_SHA,'delta_sha256':DELTA_SHA,'delta_report_sha256':REPORT_SHA,
                'merged_sha256':result.stem,'texture_report_sha256':quarter.REPORT_SHA,'candidate_count':len(expected),'accepted_count':len(accepted)}
    (dest/'report.json').write_text(json.dumps(provenance,indent=2)+'\n')
    print(json.dumps({'main':str(result),'report':str(dest/'report.json'),'sha256':result.stem}));return result


if __name__=='__main__':
    try:
        p=argparse.ArgumentParser(description=__doc__)
        for n in ('source','base','texture-report','delta','delta-report','godot','output-dir'):p.add_argument('--'+n,required=True,type=Path)
        a=p.parse_args();prepare(a.source,a.base,a.texture_report,a.delta,a.delta_report,a.godot,a.output_dir)
    except (OSError,ValueError,KeyError,TypeError) as e:sys.exit('quarter merge failed: '+str(e))
