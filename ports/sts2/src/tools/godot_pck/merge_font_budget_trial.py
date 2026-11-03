#!/usr/bin/env python3
# INPUT: audited f526 source, 099 main and reviewed four-entry font-budget delta/report
# OUTPUT: independent source-bound main and PCK sidecar; all other entries preserved
# POS: offline trial gate; never changes inputs, installs or starts the game
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import tempfile
import merge_texture_pck as merge
import font_budget_trial as trial

SOURCE=trial.SOURCE_SHA
BASE='099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c'
DELTA='4119d66135932df11eb3f1187488ca0db6fc9700858accf5658b2fb7cdbb999b'
REPORT='12d40ff17aa0eba1a8f890c35d7986364840f5f58b58178da8dd402722d3bbc1'
EXPECTED=set(merge.AUDITED_FONT_SOURCE_SHA256)|{trial.BOLD}

def validate_report(r):
    if (r.get('source_sha256')!=SOURCE or r.get('base_main_sha256')!=trial.MAIN_SHA or r.get('delta_sha256')!=DELTA or
        r.get('builder_sha256')!=merge.sha256_file(Path(trial.__file__)) or r.get('worker_sha256')!=merge.sha256_file(trial.WORKER)):
        raise ValueError('font budget report provenance mismatch')
    records=r.get('resources')
    if not isinstance(records,list) or len(records)!=4:raise ValueError('font budget target count')
    by_name={x['target']:x for x in records}
    if set(by_name)!=EXPECTED or len(by_name)!=len(records):raise ValueError('font budget target set')
    for name,item in by_name.items():
        if name==trial.BOLD:continue
        settings=item['validation'];before=dict(settings['before_settings']);after=settings['after_settings']
        if before.get('msdf_pixel_range')!=24 or after.get('msdf_pixel_range')!=16:raise ValueError('unexpected MSDF range')
        before['msdf_pixel_range']=16
        coverage=item['coverage_metrics']
        if (before!=after or settings['output_pages']!=0 or settings['font_data_sha256']!=item['font_data_sha256'] or
            coverage['game_count']!=2493 or coverage['extended_count']!=23644 or coverage['coverage_losses'] or
            coverage['old_missing_game']!=[287,305,322]):raise ValueError('font budget validation mismatch')
    shared=r.get('shared_validation',{})
    if (shared.get('canonical_medium_same_instance') is not True or shared.get('system_fallback') is not True or
        shared.get('bold_fallbacks')!=[] or shared.get('bold_canonical_path')!='res://fonts/zhs/SourceHanSerifSC-Medium.otf' or
        shared.get('mono_canonical_path')!='res://fonts/zhs/NotoSansMonoCJKsc-Regular.otf'):
        raise ValueError('font budget shared instance mismatch')
    return by_name

def prepare(source,base,delta,report,outdir):
    supplied=[Path(x) for x in (source,base,delta,report)]
    if any(p.is_symlink() for p in supplied):raise ValueError('symlink inputs forbidden')
    paths=[p.resolve(strict=True) for p in supplied]
    if any(a.samefile(b) for i,a in enumerate(paths) for b in paths[i+1:]):raise ValueError('inputs must be distinct')
    source,base,delta,report=paths;dest=Path(outdir).absolute();dest=dest.parent.resolve(strict=True)/dest.name
    if dest.exists() or dest.is_symlink() or any(dest==p or dest in p.parents for p in paths):raise ValueError('output directory must be fresh and separate')
    for path,expected in zip(paths,(SOURCE,BASE,DELTA,REPORT)):
        if merge.sha256_file(path)!=expected:raise ValueError('input identity mismatch: '+str(path))
    records=validate_report(json.loads(report.read_text()));src,before,patch=map(merge.read_pack,(source,base,delta))
    if set(patch)!=EXPECTED or not EXPECTED<=set(src) or not EXPECTED<=set(before):raise ValueError('PCK replacement closed set mismatch')
    with source.open('rb') as s,base.open('rb') as b,delta.open('rb') as d:
        for name,item in records.items():
            if (merge.entry_sha256(s,src[name])!=item['source_sha256'] or merge.entry_sha256(b,before[name])!=item['base_sha256'] or
                merge.entry_sha256(d,patch[name])!=item['output_sha256'] or patch[name][2].hex()!=item['output_md5']):raise ValueError('entry identity mismatch: '+name)
            if name!=trial.BOLD:
                imp=item['import_path']
                if imp not in src or imp not in before or merge.entry_sha256(s,src[imp])!=item['import_sha256'] or merge.entry_sha256(b,before[imp])!=item['import_sha256']:
                    raise ValueError('font import mapping mismatch: '+name)
    stats=[merge.identity(p) for p in paths];dest.mkdir();packs=dest/'packs';packs.mkdir()
    names=sorted(before);needed=112+sum((patch.get(n,before[n])[1]+15)//16*16 for n in names)+4+sum(4+((len(('res://'+n).encode())+3)//4*4)+36 for n in names)
    if shutil.disk_usage(packs).free<needed+16*1024*1024:raise ValueError('insufficient disk space')
    fd,tmp=tempfile.mkstemp(prefix='.font-budget-',suffix='.incoming',dir=packs);temp=Path(tmp)
    try:
        with os.fdopen(fd,'w+b') as out,base.open('rb') as b,delta.open('rb') as d:
            out.write(struct.pack('<6I2Q',*merge.HEADER,2,112,0)+bytes(72));directory=[]
            for i,name in enumerate(names,1):
                is_patch=name in patch;entry=patch[name] if is_patch else before[name];offset=out.tell()-112
                if is_patch:merge.transfer(b,before[name])
                merge.transfer(d if is_patch else b,entry,out);directory.append((name,offset,entry[1],entry[2]));out.write(bytes((-out.tell())%16))
                if i%2048==0 or i==len(names):print('merged entries {}/{}'.format(i,len(names)),flush=True)
            position=out.tell();out.write(struct.pack('<I',len(directory)))
            for name,offset,length,md5 in directory:
                raw=('res://'+name).encode();raw+=bytes((-len(raw))%4)
                out.write(struct.pack('<I',len(raw))+raw+struct.pack('<QQ16sI',offset,length,md5,0))
            out.seek(32);out.write(struct.pack('<Q',position));out.flush();os.fchmod(out.fileno(),0o644);os.fsync(out.fileno())
        if [merge.identity(p) for p in paths]!=stats:raise ValueError('input changed during merge')
        result=merge.read_pack(temp)
        if {n:v[1:] for n,v in result.items()}!={n:patch.get(n,before[n])[1:] for n in names}:raise ValueError('merged closed set differs')
        with temp.open('rb') as f:
            for name in names:merge.transfer(f,result[name])
        output_sha=merge.sha256_file(temp);output=packs/(output_sha+'.pck');os.rename(temp,output)
        st=merge.identity(output);side={'source_sha256':BASE,'overlay_sha256':DELTA,'merged_sha256':output_sha,
            'source_stat':{k:stats[1][k] for k in ('size','mtime_ns')},'merged_stat':{k:st[k] for k in ('size','mtime_ns')}}
        (packs/(output_sha+'.json')).write_text(json.dumps(side,sort_keys=True)+'\n')
        provenance={'source_sha256':SOURCE,'base_main_sha256':BASE,'delta_sha256':DELTA,'delta_report_sha256':REPORT,
                    'merged_sha256':output_sha,'targets':sorted(EXPECTED),'unchanged_entry_count':len(names)-4,
                    'merge_source_sha256':merge.sha256_file(Path(__file__)),
                    'limitations':['Range 16 may reduce thick outlines; synthetic bold changes shape and advance.',
                      'Static coverage and nominal atlas page estimates do not prove runtime GPU memory or RSS savings.',
                      'Bold FontFile remains in the pack and may still load through other runtime references.']}
        (dest/'report.json').write_text(json.dumps(provenance,indent=2)+'\n');print(json.dumps({'sha256':output_sha,'main':str(output),'report':str(dest/'report.json')}));return output
    finally:
        if temp.exists():temp.unlink()

if __name__=='__main__':
    try:
        p=argparse.ArgumentParser(description=__doc__)
        for n in ('source','base','delta','report','output-dir'):p.add_argument('--'+n,required=True,type=Path)
        a=p.parse_args();prepare(a.source,a.base,a.delta,a.report,a.output_dir)
    except (OSError,ValueError,KeyError,TypeError) as e:raise SystemExit('font budget merge failed: '+str(e))
