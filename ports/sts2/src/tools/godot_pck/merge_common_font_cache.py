#!/usr/bin/env python3
# INPUT: audited Windows PCK, three-SC-font main and six-common-font delta/report
# OUTPUT: independently verified immutable main with only six font-cache replacements
# POS: separate fixed-identity gate; preserves the existing three-SC-font contract
import argparse
import json
from pathlib import Path
import sys

import merge_texture_pck as merge
import strip_common_font_cache as spec

SOURCE = 'f526ef85cd5b7cf653defb545a8ba22196c72e6a0e95ad66f78f2f3a168b28c9'
BASE = spec.MAIN
DELTA = spec.DELTA_SHA
REPORT = '32d8005dd07cd735f01c77ce1cc54a83eb098c33a0e1232795f97d0a9481020e'
MAIN = '3abccf4a75ea347b0d4cece05d376beeaf42b4f34a3af1ccc17644bd2762203d'


def prepare(source, base, delta, report, godot, outdir):
    paths = [Path(p) for p in (source, base, delta, report, godot)]
    if any(p.is_symlink() for p in paths): raise ValueError('common font inputs cannot be symlinks')
    paths = [p.resolve(strict=True) for p in paths]
    if any(a.samefile(b) for i, a in enumerate(paths) for b in paths[i+1:]): raise ValueError('common font inputs must be distinct')
    source, base, delta, report, godot = paths
    destination = Path(outdir).absolute(); destination = destination.parent.resolve(strict=True)/destination.name
    if destination.exists() or destination.is_symlink() or any(destination == p or destination in p.parents for p in paths):
        raise ValueError('common font output directory must be new and cannot contain inputs')
    if any(merge.sha256_file(p) != h for p,h in ((source,SOURCE),(base,BASE),(delta,DELTA),(report,REPORT))):
        raise ValueError('common font source, base, delta or report mismatch')
    r = json.loads(report.read_text()); here = Path(__file__).parent
    if (r.get('source_sha256') != SOURCE or r.get('base_main_sha256') != BASE or r.get('delta_sha256') != DELTA or
        r.get('godot_sha256') != merge.sha256_file(godot) or
        r.get('builder_sha256') != merge.sha256_file(here/'strip_font_cache.py') or
        r.get('worker_sha256') != merge.sha256_file(here/'strip_common_font_cache.gd') or
        r.get('common_builder_sha256') != merge.sha256_file(here/'strip_common_font_cache.py')):
        raise ValueError('common font builder or engine mismatch')
    entries = r.get('resources'); by_name = {}
    if not isinstance(entries,list): raise ValueError('invalid common font report')
    for item in entries:
        name = item.get('target'); basename = name.removeprefix('.godot/imported/') if isinstance(name,str) else ''
        if basename not in spec.COMMON or name in by_name: raise ValueError('unknown or duplicate common font')
        import_path, original_sha, vector_sha = spec.COMMON[basename]; v = item.get('validation',{})
        if (item.get('import_path') != import_path or item.get('source_sha256') != original_sha or item.get('base_sha256') != original_sha or
            item.get('output_sha256') != spec.COMMON_OUTPUTS[basename] or item.get('font_data_sha256') != vector_sha or
            v.get('status') != 'verified' or v.get('font_data_sha256') != vector_sha or v.get('glyph_image',{}).get('exact_pixels') is not True or
            not v.get('before_sizes') or not v.get('after_sizes') or any(x.get('pages') != 0 for cache in v['after_sizes'] for x in cache) or
            len(v.get('metrics',[])) != 42 or any(not x.get('present') or not x.get('glyph') for x in v['metrics'])):
            raise ValueError('common font evidence mismatch: '+basename)
        by_name[name] = item
    if set(by_name) != set(merge.AUDITED_COMMON_FONT_SOURCE_SHA256): raise ValueError('common font target set mismatch')
    src, current, replacements = map(merge.read_pack,(source,base,delta))
    if set(replacements) != set(by_name): raise ValueError('common delta target set mismatch')
    with source.open('rb') as original, base.open('rb') as installed, delta.open('rb') as replacement:
        for name,item in by_name.items():
            imp = item['import_path']
            if any(n not in index for index in (src,current) for n in (name,imp)): raise ValueError('common font or import missing')
            if (merge.entry_sha256(original,src[name]) != item['source_sha256'] or merge.entry_sha256(installed,current[name]) != item['base_sha256'] or
                merge.entry_sha256(original,src[imp]) != item['import_sha256'] or merge.entry_sha256(installed,current[imp]) != item['import_sha256'] or
                merge.entry_sha256(replacement,replacements[name]) != item['output_sha256'] or src[name][2].hex() != item['source_md5'] or replacements[name][2].hex() != item['output_md5']):
                raise ValueError('common font entry identity mismatch: '+name)
        previous = r.get('previous_sc_verified')
        if not isinstance(previous,list) or len(previous) != 3: raise ValueError('missing prior SC font evidence')
        seen=set()
        for item in previous:
            name=item['target']; basename=name.removeprefix('.godot/imported/')
            if basename not in spec.SC_OUTPUTS or name in seen or item['source_sha256'] != merge.AUDITED_FONT_SOURCE_SHA256.get(name) or item['base_sha256'] != spec.SC_OUTPUTS[basename]:
                raise ValueError('prior SC font identity mismatch')
            imp=spec.base.FONTS[basename][0]
            if (merge.entry_sha256(original,src[name]) != item['source_sha256'] or merge.entry_sha256(installed,current[name]) != item['base_sha256'] or
                merge.entry_sha256(original,src[imp]) != item['import_sha256'] or merge.entry_sha256(installed,current[imp]) != item['import_sha256']):
                raise ValueError('prior SC font or import changed')
            seen.add(name)
        if seen != set(merge.AUDITED_FONT_SOURCE_SHA256): raise ValueError('prior SC font set mismatch')
    destination.mkdir(); adapter=destination/'merge-input.json'
    adapter.write_text(json.dumps({'source_sha256':BASE,'output_sha256':DELTA,'resources':[
        {'path':name,'kind':'audited_font','source_sha256':item['source_sha256'],'output_sha256':item['output_sha256'],'output_md5':item['output_md5']}
        for name,item in sorted(by_name.items())]})+'\n')
    main=merge.prepare(base,delta,adapter,destination/'packs',approved_font_hashes=merge.AUDITED_COMMON_FONT_SOURCE_SHA256)
    if main.stem != MAIN: raise ValueError('common font merged main differs from audited result')
    provenance={'source_sha256':SOURCE,'base_main_sha256':BASE,'delta_sha256':DELTA,'delta_report_sha256':REPORT,'merged_sha256':main.stem,'targets':sorted(by_name)}
    (destination/'report.json').write_text(json.dumps(provenance,indent=2)+'\n')
    print(json.dumps({'main':str(main),'report':str(destination/'report.json'),'sha256':main.stem}))
    return main


if __name__=='__main__':
    try:
        p=argparse.ArgumentParser(description=__doc__)
        for n in ('source','base','delta','report','godot','output-dir'): p.add_argument('--'+n,required=True,type=Path)
        a=p.parse_args();prepare(a.source,a.base,a.delta,a.report,a.godot,a.output_dir)
    except (OSError,ValueError,KeyError,TypeError) as e:sys.exit('common font merge failed: '+str(e))
