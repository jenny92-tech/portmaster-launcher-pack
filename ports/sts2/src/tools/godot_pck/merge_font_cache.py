#!/usr/bin/env python3
# INPUT: audited original PCK, restored-texture main and three-font delta/report
# OUTPUT: independent source-bound main PCK with cleared cached glyph pages
# POS: offline build gate; never mutates the original, existing main or fonts
import argparse
import hashlib
import json
from pathlib import Path
import sys

import merge_texture_pck as merge

SOURCE='f526ef85cd5b7cf653defb545a8ba22196c72e6a0e95ad66f78f2f3a168b28c9'
BASE='a9c61d767c577ea066010af452f6e706ae2c0925f41b800b0bfe0c4d3f835daa'
DELTA='76412fc7494eb1c49189ebaf2b6add3d1f9b1d3ce407502b2993e6e683ddcedb'
REPORT='67caab260846df8ae804443b55193e7d94e0c4ca8a8fad80dfbb9bd2a8e97f29'


def prepare(source, base, delta, report, godot, outdir):
    paths=[Path(p) for p in (source,base,delta,report,godot)]
    if any(p.is_symlink() for p in paths): raise ValueError('font inputs must not be symlinks')
    paths=[p.resolve(strict=True) for p in paths]
    if any(a.samefile(b) for i,a in enumerate(paths) for b in paths[i+1:]): raise ValueError('font inputs must be distinct')
    source,base,delta,report,godot=paths
    destination=Path(outdir).absolute();destination=destination.parent.resolve(strict=True)/destination.name
    if destination.exists() or destination.is_symlink() or any(destination==p or destination in p.parents for p in paths):
        raise ValueError('font output directory must be new and cannot contain inputs')
    if (merge.sha256_file(source)!=SOURCE or merge.sha256_file(base)!=BASE or
        merge.sha256_file(delta)!=DELTA or merge.sha256_file(report)!=REPORT):
        raise ValueError('font source, base, delta or reviewed report identity mismatch')
    r=json.loads(report.read_text()); here=Path(__file__).parent
    if (r.get('source_sha256')!=SOURCE or r.get('base_main_sha256')!=BASE or r.get('delta_sha256')!=DELTA or
        r.get('godot_sha256')!=merge.sha256_file(godot) or
        r.get('builder_sha256')!=merge.sha256_file(here/'strip_font_cache.py') or
        r.get('worker_sha256')!=merge.sha256_file(here/'strip_font_cache.gd')):
        raise ValueError('font builder or engine identity mismatch')
    records=r.get('resources'); by_name={}
    if not isinstance(records,list): raise ValueError('invalid font report')
    for item in records:
        name=item.get('target')
        if name not in merge.AUDITED_FONT_SOURCE_SHA256 or name in by_name:
            raise ValueError('unknown or duplicate font target')
        if (item.get('source_sha256')!=merge.AUDITED_FONT_SOURCE_SHA256[name] or
            item.get('base_sha256')!=item['source_sha256'] or
            item.get('validation',{}).get('status')!='verified' or
            item['validation'].get('font_data_sha256')!=item.get('font_data_sha256') or
            item['validation'].get('glyph_image',{}).get('exact_pixels') is not True):
            raise ValueError('font validation evidence missing: '+name)
        before=item['validation'].get('before_sizes');after=item['validation'].get('after_sizes')
        if not before or not after or any(page.get('pages')!=0 for cache in after for page in cache):
            raise ValueError('font cache page evidence invalid: '+name)
        by_name[name]=item
    if set(by_name)!=set(merge.AUDITED_FONT_SOURCE_SHA256): raise ValueError('font report must contain the exact three audited targets')
    src_entries,base_entries,delta_entries=map(merge.read_pack,(source,base,delta))
    if set(delta_entries)!=set(by_name): raise ValueError('font delta differs from reviewed target set')
    with source.open('rb') as original,base.open('rb') as installed,delta.open('rb') as replacement:
        for name,item in by_name.items():
            imp=item.get('import_path')
            if not isinstance(imp,str) or not imp.startswith('fonts/zhs/') or not imp.endswith('.otf.import'):
                raise ValueError('invalid font import path')
            if name not in src_entries or name not in base_entries or imp not in src_entries or imp not in base_entries:
                raise ValueError('font or import missing from source/base')
            if (merge.entry_sha256(original,src_entries[name])!=item['source_sha256'] or
                merge.entry_sha256(installed,base_entries[name])!=item['base_sha256'] or
                merge.entry_sha256(original,src_entries[imp])!=item.get('import_sha256') or
                merge.entry_sha256(installed,base_entries[imp])!=item.get('import_sha256') or
                merge.entry_sha256(replacement,delta_entries[name])!=item.get('output_sha256') or
                src_entries[name][2].hex()!=item.get('source_md5') or delta_entries[name][2].hex()!=item.get('output_md5')):
                raise ValueError('font PCK entry identity mismatch: '+name)
    destination.mkdir()
    adapter=destination/'merge-input.json'
    adapter.write_text(json.dumps({'source_sha256':BASE,'output_sha256':DELTA,'resources':[
        {'path':name,'kind':'audited_font','source_sha256':item['source_sha256'],
         'output_sha256':item['output_sha256'],'output_md5':item['output_md5']}
        for name,item in sorted(by_name.items())]})+'\n')
    main=merge.prepare(base,delta,adapter,destination/'packs',approved_font_hashes=merge.AUDITED_FONT_SOURCE_SHA256)
    provenance={'source_sha256':SOURCE,'base_main_sha256':BASE,'delta_sha256':DELTA,
                'delta_report_sha256':REPORT,'merged_sha256':main.stem,'targets':sorted(by_name)}
    (destination/'report.json').write_text(json.dumps(provenance,indent=2)+'\n')
    print(json.dumps({'main':str(main),'report':str(destination/'report.json'),'sha256':main.stem}))
    return main


if __name__=='__main__':
    try:
        p=argparse.ArgumentParser(description=__doc__)
        for n in ('source','base','delta','report','godot','output-dir'): p.add_argument('--'+n,required=True,type=Path)
        a=p.parse_args();prepare(a.source,a.base,a.delta,a.report,a.godot,a.output_dir)
    except (OSError,ValueError,KeyError,TypeError) as e:sys.exit('font merge failed: '+str(e))
