#!/usr/bin/env python3
# INPUT: fixed f526 source, dd5c parent, reviewed one-font delta and evidence
# OUTPUT: source-bound candidate main, standard sidecar and provenance report
# POS: offline trial gate; never changes inputs or the normal installation
import argparse
import importlib.util
import json
from pathlib import Path
import low_texture_overlay as low
import subset_mono_font as candidate

DELTA='7664064d13008ca34d7d67070d2fede95ac28a06129ac26ec2043f7d74f4217f'
REPORT='6391ae3744fa36f1238c0dcded4d6f8c6349188eaf803999c812dcd17765034c'
OUTPUT='440008fa82545d36151305898a923f148c5f551286a6b178f0ced013c4e44831'
OUTPUT_MD5='aafab1f33d9eddf06c320ce6416936b1'
IMPORT='fonts/zhs/NotoSansMonoCJKsc-Regular.otf.import'

def verify_evidence(r):
    if (r.get('source_sha256')!=candidate.SOURCE or r.get('base_main_sha256')!=candidate.BASE or r.get('delta_sha256')!=DELTA or
        r.get('builder_sha256')!=low.file_hash(Path(candidate.__file__)) or r.get('worker_sha256')!=low.file_hash(candidate.WORKER) or
        r.get('subset_worker_sha256')!=low.file_hash(candidate.SUBSET) or r.get('uid_fixture_sha256')!=low.file_hash(candidate.UID)):
        raise ValueError('Mono subset report provenance mismatch')
    expected={'target':candidate.MONO,'source_sha256':candidate.MONO_SOURCE,'base_sha256':candidate.MONO_BASE,
              'output_sha256':OUTPUT,'output_md5':OUTPUT_MD5,'import_path':IMPORT}
    if r.get('resources')!=[expected]:raise ValueError('Mono subset target mismatch')
    u=r['uid_validation'];sub=r['subset'];ser=r['serialization']
    if (u['game_count']!=2493 or u['compared_count']!=2490 or u['original_supported_count']!=44682 or
        u['coverage_losses'] or u['all_font_losses'] or u['width_mismatches'] or u['string_differences'] or
        not u['same_medium_instance'] or not u['system_fallback'] or u['fallback_count']!=1 or
        u['medium_path']!='res://fonts/zhs/SourceHanSerifSC-Medium.otf' or
        u['digit_widths']!=[24.0]*10 or any(row[1]!=row[2] or row[3]!=row[4] or row[5]!=row[6] for row in u['line_metrics']) or
        ser['original_settings']!=ser['restored_settings'] or not ser['system_fallback'] or sub['wheel_sha256']!=candidate.WHEEL or
        sub['delegated']!=28513 or sub['retained']!=16170 or ser['pages']!=0 or not ser['same_medium']):
        raise ValueError('Mono subset validation evidence mismatch')
    return expected

def prepare(source,base,delta,report,dest):
    supplied=[Path(x) for x in (source,base,delta,report)]
    if any(p.is_symlink() for p in supplied):raise ValueError('symlink input')
    source,base,delta,report=[p.resolve(strict=True) for p in supplied]
    if any(a.samefile(b) for i,a in enumerate((source,base,delta,report)) for b in (source,base,delta,report)[i+1:]):raise ValueError('inputs must differ')
    dest=Path(dest).absolute();dest=dest.parent.resolve(strict=True)/dest.name
    if dest.exists() or dest.is_symlink() or any(dest==x or dest in x.parents for x in (source,base,delta,report)):raise ValueError('fresh separate destination required')
    for path,want in ((source,candidate.SOURCE),(base,candidate.BASE),(delta,DELTA),(report,REPORT)):
        if low.file_hash(path)!=want:raise ValueError('Mono subset input identity mismatch: '+str(path))
    record=verify_evidence(json.loads(report.read_text()));se,be,de=map(low.read_pack,(source,base,delta))
    if set(de)!={candidate.MONO} or any(n not in e for e,n in ((se,candidate.MONO),(be,candidate.MONO),(se,IMPORT),(be,IMPORT))):raise ValueError('Mono subset closed set mismatch')
    with source.open('rb') as s,base.open('rb') as b,delta.open('rb') as d:
        if (low.digest(low.entry_bytes(s,se[candidate.MONO]))!=candidate.MONO_SOURCE or
            low.digest(low.entry_bytes(b,be[candidate.MONO]))!=candidate.MONO_BASE or
            low.digest(low.entry_bytes(d,de[candidate.MONO]))!=OUTPUT or de[candidate.MONO][2]!=OUTPUT_MD5 or
            low.entry_bytes(s,se[IMPORT])!=low.entry_bytes(b,be[IMPORT])):raise ValueError('Mono subset entry mismatch')
    # A separately imported copy receives a one-path approval only in this
    # process; the existing general merger and its audited defaults are untouched.
    spec=importlib.util.spec_from_file_location('_isolated_mono_merge',Path(__file__).with_name('merge_texture_pck.py'))
    merge=importlib.util.module_from_spec(spec);spec.loader.exec_module(merge)
    approval={candidate.MONO:candidate.MONO_BASE};merge.AUDITED_FONT_SOURCE_SHA256=approval
    dest.mkdir();adapter=dest/'merge-input.json'
    adapter.write_text(json.dumps({'source_sha256':candidate.BASE,'output_sha256':DELTA,'resources':[{
        'path':candidate.MONO,'kind':'audited_font','source_sha256':candidate.MONO_BASE,
        'output_sha256':OUTPUT,'output_md5':OUTPUT_MD5}]})+'\n')
    out=merge.prepare(base,delta,adapter,dest/'packs',approved_font_hashes=approval)
    provenance={'source_sha256':candidate.SOURCE,'base_main_sha256':candidate.BASE,'delta_sha256':DELTA,'delta_report_sha256':REPORT,
      'merged_sha256':out.stem,'targets':[candidate.MONO],'merge_source_sha256':low.file_hash(Path(__file__)),
      'limitations':['Original character coverage does not establish all shaping or visual equivalence.', 'Font byte reduction is not device RSS.']}
    (dest/'report.json').write_text(json.dumps(provenance,indent=2)+'\n');print(json.dumps({'main':str(out),'sha256':out.stem,'report':str(dest/'report.json')}));return out
if __name__=='__main__':
    try:
        p=argparse.ArgumentParser(description=__doc__)
        for n in ('source','base','delta','report','output-dir'):p.add_argument('--'+n,required=True,type=Path)
        a=p.parse_args();prepare(a.source,a.base,a.delta,a.report,a.output_dir)
    except (OSError,ValueError,KeyError,TypeError) as e:raise SystemExit('Mono subset merge failed: '+str(e))
