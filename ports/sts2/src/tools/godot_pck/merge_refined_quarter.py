#!/usr/bin/env python3
# INPUT: fixed Windows source, quarter main, its reviewed reports and refined delta
# OUTPUT: immutable main with exactly the audited refinement replacements
# POS: offline gate; original packs and the selected runtime remain unchanged
import argparse
import json
from pathlib import Path
import sys

import low_texture_overlay as low
import merge_texture_pck as merge
import quarter_texture_overlay as quarter
import refine_quarter_texture as refine
import windows_texture_overlay as windows

DELTA_SHA='447f1186d5a86495d8b0b5276c95eb1b514413433220fd01bea29abf1939cf16'
REPORT_SHA='b76fee5473211b9106282a9e34cd1893589fd326acf6a405fc0806d72db9cce3'
MAIN_SHA='099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c'


def prepare(source,base,previous_delta,previous_report,texture_report,delta,delta_report,godot,compiler,astc_dir,outdir):
    supplied=[Path(p) for p in (source,base,previous_delta,previous_report,texture_report,delta,delta_report,godot,compiler,quarter.SPECS,astc_dir)]
    if any(p.is_symlink() for p in supplied):raise ValueError('refinement inputs must not be symlinks')
    paths=[p.resolve(strict=True) for p in supplied]
    if any(a.samefile(b) for i,a in enumerate(paths) for b in paths[i+1:]):raise ValueError('refinement inputs must be distinct')
    source,base,previous_delta,previous_report,texture_report,delta,delta_report,godot,compiler,specs,astc_dir=paths
    dest=Path(outdir).absolute();dest=dest.parent.resolve(strict=True)/dest.name
    if dest.exists() or dest.is_symlink() or any(dest==p or dest in p.parents for p in paths):raise ValueError('output directory must be new and separate')
    for p,want in ((source,refine.SOURCE_SHA),(base,refine.MAIN_SHA),(previous_delta,refine.DELTA_SHA),(previous_report,refine.PREVIOUS_REPORT_SHA),(texture_report,quarter.REPORT_SHA),(specs,quarter.SPECS_SHA),(delta,DELTA_SHA),(delta_report,REPORT_SHA)):
        if merge.sha256_file(p)!=want:raise ValueError('refinement input identity mismatch: '+str(p))
    previous=json.loads(previous_report.read_text());texture=json.loads(texture_report.read_text());spec=json.loads(specs.read_text());data=json.loads(delta_report.read_text())
    expected_meta={'source_sha256':refine.SOURCE_SHA,'base_main_sha256':refine.MAIN_SHA,'previous_delta_sha256':refine.DELTA_SHA,'previous_report_sha256':refine.PREVIOUS_REPORT_SHA,'texture_report_sha256':quarter.REPORT_SHA,'specs_sha256':quarter.SPECS_SHA,'astc_source_sha256':refine.ASTC_SOURCE_SHA,'godot_sha256':merge.sha256_file(godot),'compiler_sha256':merge.sha256_file(compiler),'builder_sha256':merge.sha256_file(Path(refine.__file__)),'worker_sha256':merge.sha256_file(refine.WORKER),'encoder_source_sha256':merge.sha256_file(refine.ENCODER),'delta_sha256':DELTA_SHA}
    if any(data.get(k)!=v for k,v in expected_meta.items()) or refine.source_identity(astc_dir)!=refine.ASTC_SOURCE_SHA:raise ValueError('refinement provenance mismatch')
    if previous.get('source_sha256')!=refine.SOURCE_SHA or previous.get('base_main_sha256')!=quarter.MAIN_SHA or previous.get('delta_sha256')!=refine.DELTA_SHA or texture.get('source_sha256')!=refine.SOURCE_SHA or spec.get('source_pck_sha256')!=refine.SOURCE_SHA:raise ValueError('refinement ancestry mismatch')
    candidates,textures,specs_by_target=refine.candidate_records(previous,texture,spec)
    expected={item[1]:item for item in candidates};records=data.get('resources')
    if not isinstance(records,list) or len(expected)!=len(candidates):raise ValueError('invalid candidate inventory')
    reported={}
    for item in records:
        target=item.get('target')
        if not isinstance(target,str) or not target.startswith('res://') or target[6:] in reported:raise ValueError('invalid report target')
        reported[target[6:]]=item
    if set(reported)!=set(expected) or data.get('candidate_count')!=len(expected):raise ValueError('refinement candidate set mismatch')
    source_entries,base_entries,delta_entries,prior_entries=map(low.read_pack,(source,base,delta,previous_delta))
    if set(prior_entries)!={x['target'][6:] for x in previous['resources'] if x['quality']['status']=='accepted'}:raise ValueError('previous delta closed set mismatch')
    accepted={}
    with source.open('rb') as src,base.open('rb') as main,delta.open('rb') as overlay:
        mapping,imports,spines,fonts=windows.windows_import_map(src,source_entries)
        if set(specs_by_target)!=set(mapping):raise ValueError('refinement mapping differs from source')
        for name,(original_name,_,role,scale,old) in expected.items():
            item=reported[name];tx=textures[name];sp=specs_by_target[name]
            if name in prior_entries or name not in source_entries or name not in base_entries or mapping[name][0]!=tx['source_path'] or sp['source']!=original_name or low.protected(name,mapping,spines,fonts,True):raise ValueError('unsafe candidate: '+name)
            original=low.entry_bytes(src,source_entries[name]);current=low.entry_bytes(main,base_entries[name]);ih=low.texture_header(original);bh=low.parse_texture(current)
            if (item.get('source')!=original_name or item.get('role')!=role or item.get('scale_denominator')!=scale or low.digest(original)!=sp['source_sha256'] or low.digest(original)!=tx['source_sha256'] or item.get('source_sha256')!=low.digest(original) or item.get('source_md5')!=low.digest(original,'md5') or item.get('base_sha256')!=low.digest(current) or item.get('base_md5')!=low.digest(current,'md5') or item.get('input')!=ih or ih!=tx['input'] or item.get('base')!=bh or bh!=tx.get('output',tx['input']) or low.digest(current,'md5')!=tx.get('output_md5',tx['source_md5']) or (old is not None and old.get('base_sha256')!=low.digest(current)) or ih['mipmaps'] or bh['mipmaps']):raise ValueError('source/base entry mismatch: '+name)
            w,h=(max(1,n//scale) for n in ih['gpu']);nominal=refine.nominal(bh)
            if item.get('base_nominal_bytes')!=nominal or (scale==2 and [w,h]!=bh['gpu']):raise ValueError('base dimensions mismatch: '+name)
            modes=[(block,preset) for block,preset in refine.MODES if (((w+block-1)//block)*((h+block-1)//block)*16)*100<nominal*95]
            attempts=item.get('attempts')
            if not isinstance(attempts,list) or len(attempts)>len(modes):raise ValueError('invalid attempts: '+name)
            for idx,attempt in enumerate(attempts):
                block,preset=modes[idx];size=((w+block-1)//block)*((h+block-1)//block)*16
                if (attempt.get('block'),attempt.get('preset'),attempt.get('alpha_weight'),attempt.get('alpha_weight_flag'),attempt.get('payload_bytes'))!=(block,preset,4,True,size):raise ValueError('invalid attempt parameters: '+name)
                quarter.validate_quality(attempt.get('quality'),{'gpu':[w*4,h*4]})
                if attempt['quality']['status']=='accepted' and idx!=len(attempts)-1:raise ValueError('attempts after success: '+name)
            if item.get('status')=='accepted':
                if not attempts or attempts[-1]['quality']['status']!='accepted' or item.get('selected')!=attempts[-1] or name not in delta_entries:raise ValueError('accepted decision mismatch: '+name)
                result=low.entry_bytes(overlay,delta_entries[name]);after=low.parse_texture(result);block=attempts[-1]['block'];payload=attempts[-1]['payload_bytes']
                if (after!=item.get('output') or any(after[k]!=ih[k] for k in ('logical','flags','limit')) or after['gpu']!=[w,h] or (after['data_format'],after['image_format'],after['mipmaps'])!=(0,35 if block==4 else 37,0) or len(result)!=52+payload or item.get('output_nominal_bytes')!=payload or low.digest(result)!=item.get('output_sha256') or low.digest(result,'md5')!=item.get('output_md5')):raise ValueError('refinement output mismatch: '+name)
                accepted[name]=item
            elif item.get('status')!='quality_rejected' or len(attempts)!=len(modes) or any(a['quality']['status']!='quality_rejected' for a in attempts) or any(k in item for k in ('output','output_sha256','output_md5','selected')) or name in delta_entries:
                raise ValueError('rejected decision mismatch: '+name)
    if not accepted or set(accepted)!=set(delta_entries) or len(accepted)!=data.get('accepted_count') or len(expected)-len(accepted)!=data.get('rejected_count'):raise ValueError('refinement accepted set/count mismatch')
    dest.mkdir();adapter=dest/'merge-input.json';adapter.write_text(json.dumps({'source_sha256':refine.MAIN_SHA,'output_sha256':DELTA_SHA,'resources':[{'path':n,'output_md5':v['output_md5']} for n,v in sorted(accepted.items())]})+'\n')
    result=merge.prepare(base,delta,adapter,dest/'packs')
    if result.stem!=MAIN_SHA:raise ValueError('refinement merged main differs from audited SHA')
    provenance={'source_sha256':refine.SOURCE_SHA,'base_main_sha256':refine.MAIN_SHA,'delta_sha256':DELTA_SHA,'delta_report_sha256':REPORT_SHA,'merged_sha256':MAIN_SHA,'previous_delta_sha256':refine.DELTA_SHA,'previous_report_sha256':refine.PREVIOUS_REPORT_SHA,'candidate_count':len(expected),'accepted_count':len(accepted)}
    (dest/'report.json').write_text(json.dumps(provenance,indent=2)+'\n');print(json.dumps({'main':str(result),'sha256':MAIN_SHA,'report':str(dest/'report.json')}));return result


if __name__=='__main__':
    try:
        p=argparse.ArgumentParser(description=__doc__)
        for n in ('source','base','previous-delta','previous-report','texture-report','delta','delta-report','godot','compiler','astc-dir','output-dir'):p.add_argument('--'+n,required=True,type=Path)
        a=p.parse_args();prepare(a.source,a.base,a.previous_delta,a.previous_report,a.texture_report,a.delta,a.delta_report,a.godot,a.compiler,a.astc_dir,a.output_dir)
    except (OSError,ValueError,KeyError,TypeError) as e:sys.exit('refinement merge failed: '+str(e))
