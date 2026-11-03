#!/usr/bin/env python3
# INPUT: audited v0.110.1 build, explicit ADB target and existing entry identity
# OUTPUT: immutable same-version main/data/patch bundle and atomic selector
# POS: installer only; never starts, stops or controls the game
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shlex
import stat
import sys
import tempfile

import upload_build as upload
from managed_dll_arch import classify_runtime_dll

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'godot_pck'))
import merge_font_cache as font_gate
import merge_common_font_cache as common_gate
import merge_quarter_texture as quarter_gate
import merge_refined_quarter as refinement_gate
import merge_font_budget_trial as budget_gate
import merge_mono_subset_trial as mono_gate
import low_texture_overlay as low
REPO=HERE.parents[4]
PROFILE=HERE.parent/'handheld_low_v110_profile.json'
RUNTIME_BASELINE=HERE/'runtime_baseline_v110.json'
FILES={'sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck'}
ENGINE_SHA='93d0952f7b082e221b15eb2f060b20c0237aabf9fea6ec2639cf31d415ce7e9e'
DELIVERY_COMPAT_SHA='96da217412e7011e2f8050fbdfcad948a425021ad358dec674775dbb33d68546'
BASE_REPORT_SHA='52a207e880f8a10ebcd857a872229214e3c3fbcc52dee1413d7ed0a78eeb9efb'
COMPAT_EVIDENCE_SHA='a94af3dcaf82332970b6cf03503e0a74f1e79c828bdc85f7430807ccad45c8dd'
BUDGET_MAIN_SHA='dd5c7fa6edd32e61c98b508a975793ef79593a196ffae9c5e841fc3640a51fdd'
BUDGET_MERGE_REPORT_SHA='5b8c45253a483425aa08e16fa71c2ea3a789135102b7a2619db2169739a6ca80'
MONO_MAIN_SHA='9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad'
MONO_MERGE_REPORT_SHA='548e5567fe63ceb6f1f1c2754ad3489e4c68b44848f0fe79e86df9519c1217e4'
LOCALE_INPUT_SHA='dc0a93d4e86ce8982bc696e8f713d152cec971becbca9ce4f41c5b221e885f2d'
LOCALE_OUTPUT_SHA='543110f1286d71b7391c4a5fcc1df75212fcc3b74c763a09f4413e57acfc0b67'
LOCALE_EVIDENCE_SHA='0b8c9875b2b2f1b4e76245859ad711b51b3f6dfae402ed83461c55bf5cb25d4d'


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()



MASK_BASE='b6d49aadc25d02007c50eeae571ddea9fe5dbea0b555ba25d68b7e9d3d845d95'
MASK_NEW='ced8446fe95c212b26181fc61f27ebe2f6b4f2e8066968a72df03ed68beab3bc'
MASK_REPORT='f02a2af9428e544b4b6e31335f789d2b335cef077ab640bbfa81afa4c3fd5c84'
MASK_OLD_ENTRY='49818b4da2eb9460e2666e091d72e91cc6ac125e1f967817a32f3350ebcc95a4'
MASK_NEW_ENTRY='66ced536fda060f5599bc01f330a57d7cee5a70f44eab2e9813c66d3fc93c636'
MASK_PATH='port_compat/combat_warmup.gd'


def validate_maskfix(build, report, compat):
    old=build/'main-port_compat.pck'; path=build/'maskfix-overlay-report.json'
    supplied=Path(report['maskfix_overlay_report']).resolve(strict=True)
    if supplied!=path.resolve(strict=True) or report.get('main_compat_sha256')!=MASK_BASE or sha(old)!=MASK_BASE or sha(compat)!=MASK_NEW or sha(path)!=MASK_REPORT:
        raise ValueError('maskfix overlay provenance mismatch')
    metadata=json.loads(path.read_text())
    if (metadata.get('base_sha256')!=MASK_BASE or metadata.get('candidate_sha256')!=MASK_NEW or metadata.get('source_sha256')!=MASK_NEW_ENTRY or
        metadata.get('entry_count')!=178 or metadata.get('replaced')!=[MASK_PATH]):raise ValueError('maskfix metadata mismatch')
    before=low.read_pack(old);after=low.read_pack(compat);records=metadata.get('entries')
    if not isinstance(records,list) or len(records)!=178 or len(before)!=178 or set(before)!=set(after):raise ValueError('maskfix closed set mismatch')
    by_path={r.get('path'):r for r in records}
    if len(by_path)!=178 or set(by_path)!=set(before):raise ValueError('maskfix report entry set mismatch')
    with old.open('rb') as a,compat.open('rb') as b:
        for name in before:
            x=hashlib.sha256(low.entry_bytes(a,before[name])).hexdigest();y=hashlib.sha256(low.entry_bytes(b,after[name])).hexdigest();rec=by_path[name]
            if rec.get('before_sha256')!=x or rec.get('after_sha256')!=y or ((x,y)!=(MASK_OLD_ENTRY,MASK_NEW_ENTRY) if name==MASK_PATH else x!=y):
                raise ValueError('maskfix entry mismatch: '+name)
    return MASK_BASE



def validate_source_snapshots(report):
    parent=report['build_source_sha256']
    if not isinstance(parent,dict) or not parent:raise ValueError('missing parent build source snapshot')
    if 'engine_sha256' in report:
        snapshot=report.get('assembly_source_sha256')
        if not isinstance(snapshot,dict) or not snapshot or not set(parent).issubset(snapshot):
            raise ValueError('incomplete assembly source snapshot')
    else:
        snapshot=parent
    for path,expected in snapshot.items():
        if not isinstance(path,str) or not isinstance(expected,str) or not re.fullmatch('[0-9a-f]{64}',expected):
            raise ValueError('invalid source snapshot entry')
        p=(REPO/path).resolve(strict=True)
        if REPO not in p.parents or sha(p)!=expected:raise ValueError('build source changed: '+path)



def validate_release_evidence(build, report):
    base=build/'base-build-report.json';evidence=build/'compat-build-evidence.json'
    if any(p.is_symlink() or not p.is_file() for p in (base,evidence)) or sha(base)!=BASE_REPORT_SHA or sha(evidence)!=COMPAT_EVIDENCE_SHA:
        raise ValueError('release evidence identity mismatch')
    original=json.loads(base.read_text());compat=json.loads(evidence.read_text())
    if original.get('build_source_sha256')!=report['build_source_sha256']:
        raise ValueError('parent build source snapshot mismatch')
    if compat.get('candidate_compat_sha256')!=DELIVERY_COMPAT_SHA or compat.get('source_pck_sha256')!=report['input_sha256']['source_pck']:
        raise ValueError('compat build evidence mismatch')




def validate_two_locale(build,report,patch):
    expected={'input_sha256':LOCALE_INPUT_SHA,'output_sha256':LOCALE_OUTPUT_SHA,'evidence_sha256':LOCALE_EVIDENCE_SHA}
    source=build/'locale-dll-input.dll';evidence=build/'locale-dll-evidence.json'
    if (report.get('two_locale')!=expected or 'engine_sha256' not in report or
        any(x.is_symlink() or not x.is_file() for x in (source,evidence)) or
        sha(source)!=LOCALE_INPUT_SHA or sha(evidence)!=LOCALE_EVIDENCE_SHA or patch['files']['sts2.dll']!=LOCALE_OUTPUT_SHA):
        raise ValueError('two locale DLL identity mismatch')
    parent=json.loads((build/'base-build-report.json').read_text());data=json.loads(evidence.read_text())
    if (parent['patch_files']['sts2.dll']!=LOCALE_INPUT_SHA or data.get('input_sha256')!=LOCALE_INPUT_SHA or
        data.get('output_sha256')!=LOCALE_OUTPUT_SHA or data.get('source_pck_sha256')!=report['input_sha256']['source_pck'] or
        data.get('allowed')!=['eng','zhs'] or data.get('removed_count')!=13 or data.get('cecil_readback') is not True or
        data.get('other_method_il_unchanged') is not True or data.get('synthetic_clr_fixture') is not True):
        raise ValueError('two locale evidence mismatch')


def validate_budget_entries(base,main,delta,records):
    old=low.read_pack(base);new=low.read_pack(main);overlay=low.read_pack(delta)
    if set(overlay)!=budget_gate.EXPECTED or set(old)!=set(new) or not set(overlay)<=set(old):raise ValueError('budget pack closed set mismatch')
    for name in old:
        expected=overlay[name] if name in overlay else old[name]
        if new[name][1:]!=expected[1:]:raise ValueError('budget pack contains an unapproved change: '+name)
    with base.open('rb') as b,main.open('rb') as o,delta.open('rb') as d:
        for name,item in records.items():
            if (hashlib.sha256(low.entry_bytes(b,old[name])).hexdigest()!=item['base_sha256'] or
                hashlib.sha256(low.entry_bytes(d,overlay[name])).hexdigest()!=item['output_sha256'] or
                hashlib.sha256(low.entry_bytes(o,new[name])).hexdigest()!=item['output_sha256']):
                raise ValueError('budget replacement identity mismatch: '+name)
            if name!=budget_gate.trial.BOLD:
                imp=item['import_path']
                if imp not in old or hashlib.sha256(low.entry_bytes(b,old[imp])).hexdigest()!=item['import_sha256']:
                    raise ValueError('budget font import identity mismatch')


def validate_font_budget(build,report,main,side,source_sha):
    item=report['font_budget'];base=build/'font-budget-base-merged'/(budget_gate.BASE+'.pck')
    delta=build/'font-budget-delta.pck';original_report=build/'font-budget-report.json';merged_report=build/'font-budget-merge/report.json'
    if (sha(base)!=budget_gate.BASE or sha(delta)!=budget_gate.DELTA or sha(original_report)!=budget_gate.REPORT or
        sha(merged_report)!=BUDGET_MERGE_REPORT_SHA or item!=json.loads(merged_report.read_text())):
        raise ValueError('font budget provenance mismatch')
    if (item.get('source_sha256')!=source_sha or item.get('base_main_sha256')!=budget_gate.BASE or
        item.get('delta_sha256')!=budget_gate.DELTA or item.get('delta_report_sha256')!=budget_gate.REPORT or
        item.get('merged_sha256')!=BUDGET_MAIN_SHA or set(item.get('targets',[]))!=budget_gate.EXPECTED or
        main.name!=BUDGET_MAIN_SHA+'.pck' or side.get('source_sha256')!=budget_gate.BASE or side.get('overlay_sha256')!=budget_gate.DELTA):
        raise ValueError('font budget ancestry mismatch')
    records=budget_gate.validate_report(json.loads(original_report.read_text()))
    validate_budget_entries(base,main,delta,records)
    base_side=json.loads(base.with_suffix('.json').read_text())
    if base_side.get('source_sha256')!=quarter_gate.MAIN_SHA or base_side.get('overlay_sha256')!=refinement_gate.DELTA_SHA:
        raise ValueError('font budget parent sidecar mismatch')
    return base_side


def validate_mono_entries(base,main,delta,record):
    old,new,overlay=map(low.read_pack,(base,main,delta));target=mono_gate.candidate.MONO
    if set(old)!=set(new) or set(overlay)!={target} or target not in old:raise ValueError('Mono subset closed set mismatch')
    for name in old:
        expected=overlay[name] if name==target else old[name]
        if new[name][1:]!=expected[1:]:raise ValueError('Mono subset contains unapproved change: '+name)
    with base.open('rb') as a,main.open('rb') as b,delta.open('rb') as c:
        if (hashlib.sha256(low.entry_bytes(a,old[target])).hexdigest()!=record['base_sha256'] or
            hashlib.sha256(low.entry_bytes(b,new[target])).hexdigest()!=record['output_sha256'] or
            hashlib.sha256(low.entry_bytes(c,overlay[target])).hexdigest()!=record['output_sha256']):
            raise ValueError('Mono subset entry mismatch')


def validate_mono_subset(build,report,main,side,source_sha):
    item=report['mono_subset'];base=build/'mono-subset-base-merged'/(BUDGET_MAIN_SHA+'.pck')
    delta=build/'mono-subset-delta.pck';original_report=build/'mono-subset-report.json';merged_report=build/'mono-subset-merge/report.json'
    if (sha(base)!=BUDGET_MAIN_SHA or sha(delta)!=mono_gate.DELTA or sha(original_report)!=mono_gate.REPORT or
        sha(merged_report)!=MONO_MERGE_REPORT_SHA or item!=json.loads(merged_report.read_text())):
        raise ValueError('Mono subset provenance mismatch')
    if (item.get('source_sha256')!=source_sha or item.get('base_main_sha256')!=BUDGET_MAIN_SHA or
        item.get('delta_sha256')!=mono_gate.DELTA or item.get('delta_report_sha256')!=mono_gate.REPORT or
        item.get('merged_sha256')!=MONO_MAIN_SHA or item.get('targets')!=[mono_gate.candidate.MONO] or
        report['merged_sha256']!=MONO_MAIN_SHA or side.get('source_sha256')!=BUDGET_MAIN_SHA or side.get('overlay_sha256')!=mono_gate.DELTA):
        raise ValueError('Mono subset ancestry mismatch')
    record=mono_gate.verify_evidence(json.loads(original_report.read_text()))
    validate_mono_entries(base,main,delta,record)
    base_side=json.loads(base.with_suffix('.json').read_text())
    if base_side.get('source_sha256')!=budget_gate.BASE or base_side.get('overlay_sha256')!=budget_gate.DELTA:
        raise ValueError('Mono subset parent sidecar mismatch')
    return base,base_side


def validate(build):
    build=Path(build).resolve(strict=True);report=json.loads((build/'build-report.json').read_text())
    profile=json.loads(PROFILE.read_text()); inputs=report['input_sha256']
    if report['profile']!=profile:raise ValueError('build profile differs from audited source')
    for k in ('source_pck','game_dll','game_deps'):
        if inputs[k]!=profile[k+'_sha256']:raise ValueError('build input mismatch: '+k)
    validate_source_snapshots(report)
    if 'engine_sha256' in report:validate_release_evidence(build,report)
    patch=build/'patch';praw=(patch/'manifest.json').read_bytes();pid=hashlib.sha256(praw).hexdigest();p=json.loads(praw)
    if pid!=report['patch_manifest_sha256'] or set(p)!= {'files','source_files'} or set(p['files'])!=FILES or set(p['source_files'])!={'sts2.dll','sts2.deps.json'}:raise ValueError('invalid patch manifest')
    if {x.name for x in patch.iterdir()}!=FILES|{'manifest.json'}:raise ValueError('unexpected patch contents')
    if 'two_locale' in report:validate_two_locale(build,report,p)
    elif report.get('engine_sha256') and report.get('refinement') and report.get('maskfix_overlay_report') and p['files']['sts2.dll']!=LOCALE_INPUT_SHA:
        raise ValueError('unreviewed delivery game DLL')
    for n,h in p['files'].items():
        if sha(patch/n)!=h:raise ValueError('patch payload mismatch: '+n)
        if n.endswith('.dll'):classify_runtime_dll((patch/n).read_bytes())
    game=build/'game-input';names=sorted(x.name for x in game.glob('*.dll'))+['sts2.deps.json']
    if len(names)!=len(set(names)):raise ValueError('duplicate game file')
    game_files={n:sha(game/n) for n in names}
    for name in names:
        if name.endswith('.dll'):classify_runtime_dll((game/name).read_bytes())
    if any(game_files[n]!=h for n,h in p['source_files'].items()):raise ValueError('patch source differs from game data')
    release=game/'release_info.json'
    if sha(release)!=profile['release_info_sha256'] or json.loads(release.read_text()).get('version')!='v0.110.1':raise ValueError('release metadata mismatch')
    if game_files.get('GodotSharp.dll')!=profile['linux_godotsharp_sha256']:raise ValueError('Linux GodotSharp mismatch')
    prepared_deps=dict(profile['windows_dependency_sha256']);prepared_deps.update(profile['arm64_dependency_sha256'])
    if {n:h for n,h in game_files.items() if n not in ('sts2.dll','sts2.deps.json','GodotSharp.dll')} != prepared_deps:
        raise ValueError('managed dependencies differ from audited Windows input')
    texture=Path(report['texture_overlay']);tr=json.loads(Path(report['texture_report']).read_text())
    if tr['source_sha256']!=inputs['source_pck'] or tr['output_sha256']!=sha(texture):raise ValueError('texture binding mismatch')
    compat=build/'port_compat.pck';cr=json.loads((build/'compat-report.json').read_text())
    if bool(report.get('maskfix_overlay_report'))!=bool(report.get('main_compat_sha256')):raise ValueError('incomplete maskfix provenance')
    compat_in_main=validate_maskfix(build,report,compat) if report.get('maskfix_overlay_report') else sha(compat)
    if cr['source_pck_sha256']!=inputs['source_pck'] or cr['overlay_sha256']!=compat_in_main or sha(compat)!=p['files']['port_compat.pck']:raise ValueError('compat binding mismatch')
    main=build/'merged'/(report['merged_sha256']+'.pck');side=json.loads(main.with_suffix('.json').read_text())
    font=report.get('font_restoration'); common=report.get('common_font_restoration'); quarter=report.get('quarter_restoration'); refinement=report.get('refinement'); budget=report.get('font_budget'); mono=report.get('mono_subset')
    if mono and not budget:raise ValueError('Mono subset requires font budget')
    if budget and not refinement:raise ValueError('font budget requires refinement')
    if refinement and not quarter:raise ValueError('refinement requires quarter textures')
    if common and not font: raise ValueError('common font requires the prior three-font restoration')
    if quarter and not common: raise ValueError('quarter textures require the prior common font restoration')
    if font:
        base=build/'font-base-merged'/(font_gate.BASE+'.pck');bs=json.loads(base.with_suffix('.json').read_text())
        if (font!=json.loads((build/'font-merge/report.json').read_text()) or font.get('source_sha256')!=inputs['source_pck'] or
            font.get('base_main_sha256')!=font_gate.BASE or font.get('delta_sha256')!=font_gate.DELTA or
            font.get('delta_report_sha256')!=font_gate.REPORT or font.get('merged_sha256')!=(common_gate.BASE if common else report['merged_sha256']) or
            sha(build/'font-delta.pck')!=font_gate.DELTA or sha(build/'font-report.json')!=font_gate.REPORT or
            sha(base)!=font_gate.BASE or bs.get('source_sha256')!=inputs['source_pck'] or
            bs.get('overlay_sha256')!=tr['output_sha256'] or bs.get('compat_sha256')!=cr['overlay_sha256'] or
            (not common and (side.get('source_sha256')!=font_gate.BASE or side.get('overlay_sha256')!=font_gate.DELTA))):
            raise ValueError('font main provenance mismatch')
    elif side.get('source_sha256')!=inputs['source_pck'] or side.get('overlay_sha256')!=tr['output_sha256'] or side.get('compat_sha256')!=cr['overlay_sha256']:
        raise ValueError('merged pack binding mismatch')
    if common:
        prior=build/'common-font-base-merged'/(common_gate.BASE+'.pck'); ps=json.loads(prior.with_suffix('.json').read_text())
        if (common != json.loads((build/'common-font-merge/report.json').read_text()) or common.get('source_sha256')!=inputs['source_pck'] or
            common.get('base_main_sha256')!=common_gate.BASE or common.get('delta_sha256')!=common_gate.DELTA or
            common.get('delta_report_sha256')!=common_gate.REPORT or common.get('merged_sha256')!=common_gate.MAIN or
            (not quarter and report['merged_sha256']!=common_gate.MAIN) or sha(build/'common-font-delta.pck')!=common_gate.DELTA or
            sha(build/'common-font-report.json')!=common_gate.REPORT or sha(prior)!=common_gate.BASE or
            ps.get('source_sha256')!=font_gate.BASE or ps.get('overlay_sha256')!=font_gate.DELTA or
            (not quarter and (side.get('source_sha256')!=common_gate.BASE or side.get('overlay_sha256')!=common_gate.DELTA))):
            raise ValueError('common font main provenance mismatch')
    if quarter:
        prior=build/'quarter-base-merged'/(quarter_gate.quarter.MAIN_SHA+'.pck');ps=json.loads(prior.with_suffix('.json').read_text())
        if (quarter != json.loads((build/'quarter-merge/report.json').read_text()) or quarter.get('source_sha256')!=inputs['source_pck'] or
            quarter.get('base_main_sha256')!=quarter_gate.quarter.MAIN_SHA or quarter.get('delta_sha256')!=quarter_gate.DELTA_SHA or
            quarter.get('delta_report_sha256')!=quarter_gate.REPORT_SHA or quarter.get('merged_sha256')!=quarter_gate.MAIN_SHA or
            quarter.get('texture_report_sha256')!=quarter_gate.quarter.REPORT_SHA or (not refinement and report['merged_sha256']!=quarter_gate.MAIN_SHA) or
            sha(build/'quarter-delta.pck')!=quarter_gate.DELTA_SHA or sha(build/'quarter-report.json')!=quarter_gate.REPORT_SHA or
            sha(prior)!=quarter_gate.quarter.MAIN_SHA or ps.get('source_sha256')!=common_gate.BASE or ps.get('overlay_sha256')!=common_gate.DELTA or
            (not refinement and (side.get('source_sha256')!=quarter_gate.quarter.MAIN_SHA or side.get('overlay_sha256')!=quarter_gate.DELTA_SHA))):
            raise ValueError('quarter texture main provenance mismatch')
    budget_main,budget_side=validate_mono_subset(build,report,main,side,inputs['source_pck']) if mono else (main,side)
    refinement_side=validate_font_budget(build,report,budget_main,budget_side,inputs['source_pck']) if budget else side
    if refinement:
        prior=build/'refinement-base-merged'/(quarter_gate.MAIN_SHA+'.pck');ps=json.loads(prior.with_suffix('.json').read_text())
        expected={'source_sha256':inputs['source_pck'],'base_main_sha256':quarter_gate.MAIN_SHA,
                  'delta_sha256':refinement_gate.DELTA_SHA,'delta_report_sha256':refinement_gate.REPORT_SHA,
                  'merged_sha256':refinement_gate.MAIN_SHA,'previous_delta_sha256':quarter_gate.DELTA_SHA,
                  'previous_report_sha256':quarter_gate.REPORT_SHA,'candidate_count':129,'accepted_count':85}
        if (refinement!=expected or refinement!=json.loads((build/'refinement-merge/report.json').read_text()) or
            (not budget and report['merged_sha256']!=refinement_gate.MAIN_SHA) or sha(build/'refinement-delta.pck')!=refinement_gate.DELTA_SHA or
            sha(build/'refinement-report.json')!=refinement_gate.REPORT_SHA or sha(prior)!=quarter_gate.MAIN_SHA or
            ps.get('source_sha256')!=quarter_gate.quarter.MAIN_SHA or ps.get('overlay_sha256')!=quarter_gate.DELTA_SHA or
            refinement_side.get('source_sha256')!=quarter_gate.MAIN_SHA or refinement_side.get('overlay_sha256')!=refinement_gate.DELTA_SHA):
            raise ValueError('refinement main provenance mismatch')
    engine=None
    if 'engine_sha256' in report:
        engine=build/'engine.bin'
        if report['engine_sha256']!=ENGINE_SHA or engine.is_symlink() or not engine.is_file() or sha(engine)!=ENGINE_SHA:
            raise ValueError('engine identity mismatch')
        if refinement and report.get('maskfix_overlay_report') and p['files']['sts2_compat.dll']!=DELIVERY_COMPAT_SHA:
            raise ValueError('delivery managed bridge identity mismatch')
    if sha(main)!=report['merged_sha256'] or main.stat().st_size!=report['merged_bytes']:raise ValueError('merged pack checksum mismatch')
    entry=build/'vulkan-entry.sh'
    if sha(entry)!=report['entry_sha256']:raise ValueError('entry build identity mismatch')
    return {'report':report,'patch':patch,'patch_id':pid,'game':game,'game_files':game_files,'release':release,'main':main,'entry':entry,'engine':engine}


PREFLIGHT=r'''import hashlib,json,os,stat,sys
from pathlib import Path
root,original,entry,oldhash,newhash,names,required,expected_deps,expected_godot=sys.argv[1:]
names=set(json.loads(names)); required=int(required)
architectures={}
def directory(path):
 f=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
 try:
  for part in path[1:].split('/'):
   n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=f);os.close(f);f=n
 finally:os.close(f)
def info(path):
 p=Path(path);directory(str(p.parent));f=os.open(str(p),os.O_RDONLY|os.O_NOFOLLOW);s=os.fstat(f)
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:os.close(f);raise ValueError('unsafe file: '+str(p))
 h=hashlib.sha256()
 with os.fdopen(f,'rb') as stream:
  for b in iter(lambda:stream.read(1048576),b''):h.update(b)
  a=os.fstat(stream.fileno())
 if (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)!=(a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns):raise ValueError('file changed: '+str(p))
 return {'sha256':h.hexdigest(),'size':s.st_size,'mtime_ns':s.st_mtime_ns}
directory(root);directory(original);directory(original+'/data_sts2_linuxbsd_arm64')
entry_info=info(entry)
if entry_info['sha256'] not in (oldhash,newhash):raise ValueError('entry changed or is not recognized')
def marker(name):
 p=Path(root)/name
 try:
  s=os.lstat(str(p))
  if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('unsafe selector: '+name)
  return p.read_text().strip()
 except FileNotFoundError:return None
base=original+'/data_sts2_linuxbsd_arm64'; baseline={}
binding={'sts2.deps.json':info(base+'/sts2.deps.json')['sha256'],'GodotSharp.dll':info(base+'/GodotSharp.dll')['sha256']}
if binding!={'sts2.deps.json':expected_deps,'GodotSharp.dll':expected_godot}:raise ValueError('installed Linux runtime does not match audited baseline')
for name in sorted(os.listdir(base)):
 p=Path(base)/name
 if p.is_file() and p.suffix in ('.dll','.json','.so','.dat') and name not in names and name not in ('sts2.dll','sts2_compat.dll','sts2.deps.json'):
  baseline[name]=info(str(p))
  if name.endswith('.dll'):
   f=os.open(str(p),os.O_RDONLY|os.O_NOFOLLOW)
   with os.fdopen(f,'rb') as stream:kind=classify_runtime_dll(stream.read())
   architectures[kind]=architectures.get(kind,0)+1
if not baseline:raise ValueError('empty Linux runtime baseline')
extensions=['addons/spine/linux/libspine_godot.linux.template_release.arm64.so','addons/fmod/libs/linux/libGodotFmod.linux.template_release.arm64.so']+['addons/fmod/libs/linux/'+n for n in ('libfmod.so','libfmod.so.14','libfmod.so.14.6','libfmodstudio.so','libfmodstudio.so.14','libfmodstudio.so.14.6')]
ext={name:info(original+'/'+name) for name in extensions}
if ext[extensions[0]]['sha256']!='8cb9dbc0aac823a5d305ab058b71a6d7f57aa4eaaced7638cb0a8f1435968438':raise ValueError('unknown Spine binary; re-audit before installation')
print(json.dumps({'entry_sha256':entry_info['sha256'],'active_patch':marker('active-patch'),'active_texture':marker('active-texture'),'active_build':marker('active-build'),'runtime_binding':binding,'baseline_files':baseline,'extension_files':ext,'runtime_architectures':architectures,'free_bytes':os.statvfs(root).f_bavail*os.statvfs(root).f_frsize}))
'''


CHECK_BOUND_STAGE=r'''import hashlib,os,stat,sys
root,identity=sys.argv[1:];fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
 for part in (root+'/builds/'+identity)[1:].split('/'):
  try:n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
  except FileNotFoundError:print('absent');sys.exit(0)
  os.close(fd);fd=n
 try:f=os.open('manifest.json',os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
 except FileNotFoundError:print('absent');sys.exit(0)
 with os.fdopen(f,'rb') as stream:
  st=os.fstat(stream.fileno())
  if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:raise ValueError('unsafe stage manifest')
  print('bound' if hashlib.sha256(stream.read()).hexdigest()==identity else 'foreign')
finally:os.close(fd)
'''


COPY_MAIN=r'''import fcntl,hashlib,json,os,stat,sys
from pathlib import Path
root,oldid,newid,wanted,token=sys.argv[1:6]
kind=sys.argv[6] if len(sys.argv)>6 else ''
if kind not in ('','reviewed-099','reviewed-font','reviewed-mono'):raise ValueError('unknown copy source')
private=bool(kind)
expected={'reviewed-099':'099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c','reviewed-font':'dd5c7fa6edd32e61c98b508a975793ef79593a196ffae9c5e841fc3640a51fdd','reviewed-mono':'9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad'}
if private and wanted!=expected[kind]:raise ValueError('private copy is restricted to reviewed main')
def directory(path):
 fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
 try:
  for part in path[1:].split('/'):
   n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=n
  return fd
 except BaseException:os.close(fd);raise
def read(fd,name):
 f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd);s=os.fstat(f)
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:os.close(f);raise ValueError('unsafe file')
 with os.fdopen(f,'rb') as stream:return stream.read()
def sha(fd,name):
 f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd);s=os.fstat(f)
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:os.close(f);raise ValueError('unsafe file')
 h=hashlib.sha256()
 with os.fdopen(f,'rb') as stream:
  for b in iter(lambda:stream.read(1048576),b''):h.update(b)
  e=os.fstat(stream.fileno())
 if (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)!=(e.st_dev,e.st_ino,e.st_size,e.st_mtime_ns):raise ValueError('source changed')
 return h.hexdigest(),s
rfd=directory(root);ofd=directory(root+'/builds/'+oldid);nfd=directory(root+'/builds/'+newid)
private_dirs={'reviewed-099':'/refine-trial-abff4b541ac9aa9e/packs','reviewed-font':'/font-budget-trial-a1/packs','reviewed-mono':'/mono-subset-trial-a1/packs'}
srcfd=directory(root+private_dirs[kind]) if private else ofd
try:
 if read(rfd,'active-build').decode().strip()!=oldid:raise ValueError('active source build changed')
 oldraw=read(ofd,'manifest.json');newraw=read(nfd,'manifest.json')
 if hashlib.sha256(oldraw).hexdigest()!=oldid or hashlib.sha256(newraw).hexdigest()!=newid:raise ValueError('build manifest mismatch')
 old=json.loads(oldraw);new=json.loads(newraw)
 if new['main_sha256']!=wanted or (not private and old['main_sha256']!=wanted):raise ValueError('main pack identity differs')
 source_name=wanted+'.pck' if private else 'main.pck'
 source_hash,source_stat=sha(srcfd,source_name)
 if private:
  side=json.loads(read(srcfd,wanted+'.json'))
  source_want={'reviewed-099':'7ec4bb3f96fd01dc42bde20b6daa2f98cd16f09cec3b8ef404efd53f089615f1','reviewed-font':'099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c','reviewed-mono':'dd5c7fa6edd32e61c98b508a975793ef79593a196ffae9c5e841fc3640a51fdd'}[kind]
  overlay_want={'reviewed-099':'447f1186d5a86495d8b0b5276c95eb1b514413433220fd01bea29abf1939cf16','reviewed-font':'4119d66135932df11eb3f1187488ca0db6fc9700858accf5658b2fb7cdbb999b','reviewed-mono':'7664064d13008ca34d7d67070d2fede95ac28a06129ac26ec2043f7d74f4217f'}[kind]
  if (source_hash!=wanted or side.get('source_sha256')!=source_want or
      side.get('overlay_sha256')!=overlay_want or side.get('merged_sha256')!=wanted or
      side.get('merged_stat')!={'size':source_stat.st_size,'mtime_ns':source_stat.st_mtime_ns}):raise ValueError('reviewed private source main mismatch')
 else:
  side=json.loads(read(ofd,'main.stat.json'))
  if source_hash!=wanted or side!={'build_sha256':oldid,'main_sha256':wanted,'size':source_stat.st_size,'mtime_ns':source_stat.st_mtime_ns}:raise ValueError('active source main mismatch')
 partial='main.pck.'+wanted+'.partial';owner=partial+'.owner'
 try:f=os.open(owner,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=nfd)
 except FileExistsError:
  if read(nfd,owner)!=token.encode():raise ValueError('foreign copy owner')
 else:
  with os.fdopen(f,'wb') as stream:stream.write(token.encode());stream.flush();os.fsync(stream.fileno())
 try:dst=os.open(partial,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=nfd)
 except FileExistsError:dst=os.open(partial,os.O_RDWR|os.O_NOFOLLOW,dir_fd=nfd)
 src=os.open(source_name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=srcfd)
 try:
  fcntl.flock(dst,fcntl.LOCK_EX|fcntl.LOCK_NB);st=os.fstat(dst);ss=os.fstat(src)
  if (ss.st_dev,ss.st_ino,ss.st_size,ss.st_mtime_ns)!=(source_stat.st_dev,source_stat.st_ino,source_stat.st_size,source_stat.st_mtime_ns):raise ValueError('source inode changed')
  if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1 or (st.st_dev,st.st_ino)==(ss.st_dev,ss.st_ino) or st.st_size>ss.st_size:raise ValueError('unsafe copy partial')
  remaining=st.st_size;h=hashlib.sha256()
  while remaining:
   n=min(1048576,remaining);a=os.read(src,n);b=os.read(dst,n)
   if len(a)!=n or a!=b:raise ValueError('copy partial differs from source')
   h.update(a);remaining-=n
  while True:
   b=os.read(src,1048576)
   if not b:break
   h.update(b);view=memoryview(b)
   while view:
    count=os.write(dst,view)
    if count<=0:raise ValueError('short copy write')
    view=view[count:]
  os.fsync(dst);after=os.fstat(src)
  if h.hexdigest()!=wanted or (ss.st_dev,ss.st_ino,ss.st_size,ss.st_mtime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):raise ValueError('copy input changed')
  current=os.fstat(dst);print(str(current.st_dev)+':'+str(current.st_ino))
 finally:os.close(src);os.close(dst)
finally:
 if private:os.close(srcfd)
 os.close(rfd);os.close(ofd);os.close(nfd)
'''


COPY_FINAL_ID=r'''import os,stat,sys
directory,name,owner,token=sys.argv[1:];fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
 for part in directory[1:].split('/'):
  n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=n
 marker=os.open(owner,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
 try:
  s=os.fstat(marker)
  if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or os.read(marker,256)!=token.encode():raise ValueError('foreign copy owner')
 finally:os.close(marker)
 f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
 try:
  s=os.fstat(f)
  if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('unsafe copied main')
  print(str(s.st_dev)+':'+str(s.st_ino))
 finally:os.close(f)
finally:os.close(fd)
'''


def reuse_main(adb,root,oldid,newid,wanted,state,reviewed=False,budget=False,mono=False):
    if sum((reviewed,budget,mono))>1:raise ValueError('conflicting private copy sources')
    kind='reviewed-099' if reviewed else 'reviewed-font' if budget else 'reviewed-mono' if mono else ''
    directory=root+'/builds/'+newid;partial='main.pck.'+wanted+'.partial'
    state_path=state/('v110-copy-'+hashlib.sha256((adb.target+directory+wanted+(':'+kind if kind else '')).encode()).hexdigest()+'.json')
    final=upload.remote_hash(adb,directory,'main.pck')
    if final is not None:
        if final!=wanted:raise ValueError('foreign main file in build stage')
        marker=upload.remote_hash(adb,directory,partial+'.owner')
        if marker is not None:
            fd=os.open(state_path,os.O_RDONLY|os.O_NOFOLLOW)
            with os.fdopen(fd,'r') as f:
                st=os.fstat(f.fileno())
                if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:raise ValueError('unsafe copy state')
                state_data=json.load(f)
            token=state_data.get('token','')
            if any(state_data.get(k)!=v for k,v in (('old',oldid),('new',newid),('sha256',wanted))) or not re.fullmatch('[0-9a-f]{64}',token) or upload.digest(token.encode())!=marker:raise ValueError('copy owner state mismatch')
            result=adb.run(shlex.join(['python3','-c',COPY_FINAL_ID,directory,'main.pck',partial+'.owner',token]))
            match=re.fullmatch(r'([0-9]+):([0-9]+)',result)
            if not match:raise ValueError('invalid copied main identity')
            dev,ino=map(int,match.groups());upload.remote(adb,directory,'finish',partial,'main.pck',wanted,token,dev,ino)
        return
    try:fd=os.open(state_path,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600);created=True
    except FileExistsError:fd=os.open(state_path,os.O_RDWR|os.O_NOFOLLOW);created=False
    with os.fdopen(fd,'r+') as f:
        fcntl.flock(f.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB);st=os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:raise ValueError('unsafe copy state')
        if created:
            state_data={'old':oldid,'new':newid,'sha256':wanted,'token':secrets.token_hex(32)}
            json.dump(state_data,f);f.flush();os.fsync(f.fileno())
        else:state_data=json.load(f)
        if any(state_data.get(k)!=v for k,v in (('old',oldid),('new',newid),('sha256',wanted))) or not re.fullmatch('[0-9a-f]{64}',state_data.get('token','')):raise ValueError('copy state mismatch')
        token=state_data['token'];result=adb.run(shlex.join(['python3','-c',COPY_MAIN,root,oldid,newid,wanted,token]+([kind] if kind else [])),timeout=900)
        match=re.fullmatch(r'([0-9]+):([0-9]+)',result)
        if not match:raise ValueError('invalid local copy identity')
        dev,ino=map(int,match.groups())
        upload.remote(adb,directory,'publish',partial,'main.pck',wanted,token,dev,ino)
        upload.remote(adb,directory,'finish',partial,'main.pck',wanted,token,dev,ino)
        if upload.remote_hash(adb,directory,'main.pck')!=wanted:raise ValueError('copied main checksum mismatch')


def check_capacity(free, required, bound_stage):
    if free < required + 256*1024*1024 and not bound_stage:
        raise ValueError('insufficient device space for a fresh build and safety margin')


COMMIT=r'''import hashlib,json,os,stat,struct,sys,tempfile
from pathlib import Path
root,original,entry,identity,old_entry,new_entry,old_patch,old_texture,old_build=sys.argv[1:]
bundle=Path(root)/'builds'/identity
def directory(path):
 fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
 try:
  for part in str(path)[1:].split('/'):
   nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=nxt
 finally:os.close(fd)
def digest(path):
 fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW);s=os.fstat(fd)
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:os.close(fd);raise ValueError('unsafe file: '+str(path))
 h=hashlib.sha256()
 with os.fdopen(fd,'rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
  after=os.fstat(f.fileno())
 if (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):raise ValueError('file changed: '+str(path))
 return h.hexdigest()
def marker(name):
 p=Path(root)/name
 try:
  s=os.lstat(str(p))
  if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('unsafe selector')
  return p.read_text().strip()
 except FileNotFoundError:return ''
for pth in (Path(root),Path(original),Path(entry).parent,bundle,bundle/'patch',bundle/'data',Path(original)/'data_sts2_linuxbsd_arm64'):directory(pth)
if digest(bundle/'manifest.json')!=identity:raise ValueError('bundle manifest mismatch')
m=json.loads((bundle/'manifest.json').read_text());main=bundle/'main.pck'
if 'engine_sha256' in m:
 if m['engine_sha256']!='93d0952f7b082e221b15eb2f060b20c0237aabf9fea6ec2639cf31d415ce7e9e' or digest(bundle/'engine.bin')!=m['engine_sha256']:raise ValueError('engine checksum mismatch')
elif os.path.lexists(bundle/'engine.bin'):raise ValueError('unbound engine file')
if m['entry_sha256']!=new_entry:raise ValueError('entry identity differs from build')
if digest(main)!=m['main_sha256'] or main.stat().st_size!=m['main_bytes']:raise ValueError('main checksum mismatch')
if digest(bundle/'patch/manifest.json')!=m['patch_sha256']:raise ValueError('patch identity mismatch')
p=json.loads((bundle/'patch/manifest.json').read_text())
if set(p)!={'files','source_files'} or set(p['files'])!={'sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck'} or set(p['source_files'])!={'sts2.dll','sts2.deps.json'}:raise ValueError('invalid patch shape')
if set(os.listdir(bundle/'patch'))!=set(p['files'])|{'manifest.json'} or set(os.listdir(bundle/'data'))!=set(m['game_files']):raise ValueError('unexpected bundle contents')
for name,h in p['files'].items():
 if digest(bundle/'patch'/name)!=h:raise ValueError('patch checksum mismatch: '+name)
for name,h in m['game_files'].items():
 if '/' in name or name in ('.','..') or digest(bundle/'data'/name)!=h:raise ValueError('game file checksum mismatch: '+name)
for n,h in p['source_files'].items():
 if m['game_files'].get(n)!=h:raise ValueError('mixed game/patch')
if digest(bundle/'release_info.json')!=m['release_sha256'] or digest(bundle/'entry.sh')!=new_entry:raise ValueError('release/entry checksum mismatch')
for name,expected in m['runtime_binding'].items():
 if digest(Path(original)/'data_sts2_linuxbsd_arm64'/name)!=expected:raise ValueError('runtime source identity changed: '+name)
for name,expected in m['baseline_files'].items():
 path=Path(original)/'data_sts2_linuxbsd_arm64'/name;s=path.stat()
 if digest(path)!=expected['sha256'] or s.st_size!=expected['size'] or s.st_mtime_ns!=expected['mtime_ns']:raise ValueError('runtime baseline changed: '+name)
 if name.endswith('.dll'):
  fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW)
  with os.fdopen(fd,'rb') as stream:classify_runtime_dll(stream.read())
for name,expected in m['extension_files'].items():
 path=Path(original)/name;directory(path.parent);s=path.stat()
 if digest(path)!=expected['sha256'] or s.st_size!=expected['size'] or s.st_mtime_ns!=expected['mtime_ns']:raise ValueError('native extension changed: '+name)
selected=marker('active-build')
if marker('active-patch')!=old_patch or marker('active-texture')!=old_texture or selected not in (old_build,identity):raise ValueError('selection changed during install')
s=main.stat();side={'build_sha256':identity,'main_sha256':m['main_sha256'],'size':s.st_size,'mtime_ns':s.st_mtime_ns};sidepath=bundle/'main.stat.json'
if os.path.lexists(sidepath):
 if sidepath.is_symlink() or not sidepath.is_file():raise ValueError('unsafe main stat sidecar')
 if json.loads(sidepath.read_text())!=side:raise ValueError('foreign main stat sidecar')
else:
 fd=os.open(str(sidepath),os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'w') as f:json.dump(side,f);f.flush();os.fsync(f.fileno())
dfd=os.open(str(bundle),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);os.fsync(dfd);os.close(dfd)
def atomic(path,data,mode):
 parent=path.parent;fd,tmp=tempfile.mkstemp(prefix='.sts2-activate-',dir=str(parent))
 try:
  with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fchmod(f.fileno(),mode);os.fsync(f.fileno())
  os.replace(tmp,str(path));dfd=os.open(str(parent),os.O_RDONLY|os.O_DIRECTORY);os.fsync(dfd);os.close(dfd)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)
if digest(Path(entry)) not in (old_entry,new_entry):raise ValueError('entry changed')
if digest(Path(entry))!=new_entry:atomic(Path(entry),(bundle/'entry.sh').read_bytes(),0o755)
if selected!=identity:atomic(Path(root)/'active-build',(identity+'\n').encode(),0o600)
print(json.dumps({'active_build':identity,'main_sha256':m['main_sha256'],'patch_sha256':m['patch_sha256'],'entry_sha256':new_entry}))
'''


def send_file(adb,directory,name,path,state):
    expected=sha(path);existing=upload.remote_hash(adb,directory,name);partial=name+'.'+expected+'.partial'
    if existing==expected:
        upload.finish_transfer(adb,directory,partial,name,expected,state);return
    marker=upload.digest(('STS2_TEXTURE_UPLOAD_PENDING_V1:'+expected).encode())
    if existing is not None and existing!=marker:raise ValueError('foreign destination: '+name)
    owner=upload.transfer_partial(adb,directory,partial,path,expected,state)
    upload.remote(adb,directory,'publish',partial,name,expected,*owner)
    if upload.remote_hash(adb,directory,name)!=expected:raise ValueError('uploaded file checksum mismatch: '+name)
    upload.finish_transfer(adb,directory,partial,name,expected,state)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('target','device-root','device-original','device-entry','old-entry-sha256','build-dir','state-dir'):p.add_argument('--'+name,required=True)
    p.add_argument('--plan',action='store_true');p.add_argument('--allow-unverified-spine-binary',action='store_true')
    p.add_argument('--replace-build',help='require this active build and locally reuse its matching main PCK')
    p.add_argument('--reuse-reviewed-main',action='store_true',help='copy only the audited private 099 main with its bound sidecar')
    p.add_argument('--reuse-budget-main',action='store_true',help='copy only the audited private dd5c main with its bound sidecar')
    p.add_argument('--reuse-mono-main',action='store_true',help='copy only the audited private 9caf main with its bound sidecar')
    p.add_argument('--restore-delta', type=Path);p.add_argument('--restore-report', type=Path)
    p.add_argument('--font-delta', type=Path);p.add_argument('--font-report', type=Path)
    p.add_argument('--common-font-delta', type=Path);p.add_argument('--common-font-report', type=Path)
    p.add_argument('--quarter-delta', type=Path);p.add_argument('--quarter-report', type=Path)
    p.add_argument('--refinement-delta', type=Path);p.add_argument('--refinement-report', type=Path)
    a=p.parse_args();b=validate(a.build_dir)
    if bool(a.font_delta)!=bool(a.font_report) or (a.font_delta and (not a.replace_build or a.restore_delta or a.restore_report)):
        raise ValueError('font delta requires its report, selected prior build and no texture delta')
    if bool(a.restore_delta)!=bool(a.restore_report) or (a.restore_delta and not a.replace_build):
        raise ValueError('delta installation requires its report and the explicitly selected prior build')
    if bool(a.common_font_delta)!=bool(a.common_font_report) or (a.common_font_delta and (not a.replace_build or a.restore_delta or a.restore_report or a.font_delta or a.font_report)):
        raise ValueError('common font delta requires its report, selected prior build and no other delta')
    if bool(a.quarter_delta)!=bool(a.quarter_report) or (a.quarter_delta and (not a.replace_build or a.restore_delta or a.restore_report or a.font_delta or a.font_report or a.common_font_delta or a.common_font_report)):
        raise ValueError('quarter delta requires its report, selected prior build and no other delta')
    if bool(a.refinement_delta)!=bool(a.refinement_report) or (a.refinement_delta and (not a.replace_build or any((a.restore_delta,a.font_delta,a.common_font_delta,a.quarter_delta)))):
        raise ValueError('refinement delta requires its report, selected prior build and no other delta')
    if a.reuse_reviewed_main and (not a.replace_build or any((a.restore_delta,a.font_delta,a.common_font_delta,a.quarter_delta,a.refinement_delta)) or b['report']['merged_sha256']!=refinement_gate.MAIN_SHA):
        raise ValueError('reviewed main reuse requires fixed 099 build, selected prior build and no delta')
    if a.reuse_budget_main and (not a.replace_build or a.reuse_reviewed_main or any((a.restore_delta,a.font_delta,a.common_font_delta,a.quarter_delta,a.refinement_delta)) or b['report']['merged_sha256']!=BUDGET_MAIN_SHA or not b['report'].get('font_budget')):
        raise ValueError('budget main reuse requires fixed dd5c build, selected prior build and no delta')
    if a.reuse_mono_main and (not a.replace_build or a.reuse_reviewed_main or a.reuse_budget_main or any((a.restore_delta,a.font_delta,a.common_font_delta,a.quarter_delta,a.refinement_delta)) or b['report']['merged_sha256']!=MONO_MAIN_SHA or not b['report'].get('mono_subset')):
        raise ValueError('Mono main reuse requires fixed 9caf build, selected prior build and no delta')
    adapter=None
    mode='texture'
    if a.restore_delta:
        if a.restore_delta.is_symlink() or a.restore_report.is_symlink():raise ValueError('restoration inputs cannot be symlinks')
        delta=a.restore_delta.resolve(strict=True);dr=json.loads(a.restore_report.read_text())
        tr=json.loads(Path(b['report']['texture_report']).read_text());binding=tr.get('vram_restoration',{})
        if (sha(delta)!=binding.get('delta_sha256') or sha(a.restore_report)!=binding.get('delta_report_sha256') or
            dr.get('delta_sha256')!=binding.get('delta_sha256') or dr.get('specs_sha256')!=binding.get('specs_sha256') or
            dr.get('source_sha256')!=b['report']['input_sha256']['source_pck']):
            raise ValueError('delta differs from the verified build restoration')
        oldmain='e307d840153f31814b7ec6b67c1f7c34c21170ddf9164b4581d3e004311fc137'
        adapter={'source_sha256':oldmain,'output_sha256':dr['delta_sha256'],
                 'resources':[{'path':x['target'][6:],'output_md5':x['output_md5']} for x in dr['resources'] if 'output_sha256' in x]}
        if len(adapter['resources'])!=dr['accepted_count']:raise ValueError('invalid delta resource count')
    if a.font_delta:
        if a.font_delta.is_symlink() or a.font_report.is_symlink():raise ValueError('font inputs cannot be symlinks')
        delta=a.font_delta.resolve(strict=True);dr=json.loads(a.font_report.read_text());font=b['report'].get('font_restoration')
        if (not font or sha(delta)!=font_gate.DELTA or sha(a.font_report)!=font_gate.REPORT or
            dr.get('source_sha256')!=font_gate.SOURCE or dr.get('base_main_sha256')!=font_gate.BASE or
            dr.get('delta_sha256')!=font_gate.DELTA or font.get('merged_sha256')!=b['report']['merged_sha256']):
            raise ValueError('font delta differs from the reviewed build')
        oldmain=font_gate.BASE;mode='font'
        adapter={'source_sha256':oldmain,'output_sha256':font_gate.DELTA,'resources':[
            {'path':x['target'],'kind':'audited_font','source_sha256':x['source_sha256'],
             'output_sha256':x['output_sha256'],'output_md5':x['output_md5']} for x in dr['resources']]}
        if {x['path'] for x in adapter['resources']}!=set(font_gate.merge.AUDITED_FONT_SOURCE_SHA256) or len(adapter['resources'])!=3:
            raise ValueError('font delta does not contain the exact audited targets')
    if a.common_font_delta:
        if a.common_font_delta.is_symlink() or a.common_font_report.is_symlink():raise ValueError('common font inputs cannot be symlinks')
        delta=a.common_font_delta.resolve(strict=True);dr=json.loads(a.common_font_report.read_text());common=b['report'].get('common_font_restoration')
        if (not common or sha(delta)!=common_gate.DELTA or sha(a.common_font_report)!=common_gate.REPORT or
            dr.get('source_sha256')!=common_gate.SOURCE or dr.get('base_main_sha256')!=common_gate.BASE or
            dr.get('delta_sha256')!=common_gate.DELTA or common.get('merged_sha256')!=common_gate.MAIN or b['report']['merged_sha256']!=common_gate.MAIN):
            raise ValueError('common font delta differs from the reviewed build')
        oldmain=common_gate.BASE;mode='common-font'
        adapter={'source_sha256':oldmain,'output_sha256':common_gate.DELTA,'resources':[
            {'path':x['target'],'kind':'audited_font','source_sha256':x['source_sha256'],
             'output_sha256':x['output_sha256'],'output_md5':x['output_md5']} for x in dr['resources']]}
        if len(adapter['resources'])!=6 or {x['path'] for x in adapter['resources']}!=set(common_gate.merge.AUDITED_COMMON_FONT_SOURCE_SHA256):
            raise ValueError('common font delta does not contain the exact audited targets')
    if a.quarter_delta:
        if a.quarter_delta.is_symlink() or a.quarter_report.is_symlink():raise ValueError('quarter inputs cannot be symlinks')
        delta=a.quarter_delta.resolve(strict=True);dr=json.loads(a.quarter_report.read_text());quarter=b['report'].get('quarter_restoration')
        if (not quarter or sha(delta)!=quarter_gate.DELTA_SHA or sha(a.quarter_report)!=quarter_gate.REPORT_SHA or
            dr.get('source_sha256')!=quarter_gate.quarter.SOURCE_SHA or dr.get('base_main_sha256')!=quarter_gate.quarter.MAIN_SHA or
            dr.get('delta_sha256')!=quarter_gate.DELTA_SHA or quarter.get('merged_sha256')!=quarter_gate.MAIN_SHA or b['report']['merged_sha256']!=quarter_gate.MAIN_SHA):
            raise ValueError('quarter delta differs from the reviewed build')
        oldmain=quarter_gate.quarter.MAIN_SHA;mode='quarter'
        adapter={'source_sha256':oldmain,'output_sha256':quarter_gate.DELTA_SHA,'resources':[
            {'path':x['target'][6:],'output_md5':x['output_md5']} for x in dr['resources'] if x['quality']['status']=='accepted']}
        if len(adapter['resources'])!=dr['accepted_count'] or len({x['path'] for x in adapter['resources']})!=len(adapter['resources']):
            raise ValueError('quarter delta accepted set invalid')
    if a.refinement_delta:
        if a.refinement_delta.is_symlink() or a.refinement_report.is_symlink():raise ValueError('refinement inputs cannot be symlinks')
        delta=a.refinement_delta.resolve(strict=True);dr=json.loads(a.refinement_report.read_text());refinement=b['report'].get('refinement')
        if (not refinement or sha(delta)!=refinement_gate.DELTA_SHA or sha(a.refinement_report)!=refinement_gate.REPORT_SHA or
            dr.get('source_sha256')!=refinement_gate.refine.SOURCE_SHA or dr.get('base_main_sha256')!=quarter_gate.MAIN_SHA or
            dr.get('delta_sha256')!=refinement_gate.DELTA_SHA or dr.get('accepted_count')!=85 or
            refinement.get('merged_sha256')!=refinement_gate.MAIN_SHA or b['report']['merged_sha256']!=refinement_gate.MAIN_SHA):
            raise ValueError('refinement delta differs from the reviewed build')
        oldmain=quarter_gate.MAIN_SHA;mode='refinement'
        adapter={'source_sha256':oldmain,'output_sha256':refinement_gate.DELTA_SHA,'resources':[
            {'path':x['target'][6:],'output_md5':x['output_md5']} for x in dr['resources'] if x['status']=='accepted']}
        names=[x['path'] for x in adapter['resources']]
        if len(names)!=85 or len(set(names))!=85 or any(not n.startswith('.godot/imported/') or not n.endswith('.ctex') for n in names):
            raise ValueError('refinement delta accepted set invalid')
    if not a.allow_unverified_spine_binary and not a.plan:raise ValueError('explicit unverified Spine binary opt-in required')
    root=PurePosixPath(a.device_root);original=PurePosixPath(a.device_original);entry=PurePosixPath(a.device_entry)
    if not all(x.is_absolute() and '..' not in x.parts for x in (root,original,entry)) or root!=entry.parent/'sts2-vk-test' or original!=entry.parent/'sts2':raise ValueError('device paths do not match launcher layout')
    if not re.fullmatch('[0-9a-f]{64}',a.old_entry_sha256):raise ValueError('invalid old entry SHA')
    if a.replace_build and not re.fullmatch('[0-9a-f]{64}',a.replace_build):raise ValueError('invalid previous build identity')
    state=Path(a.state_dir)
    if not state.is_absolute() or state.is_symlink() or not state.is_dir() or state.stat().st_uid!=os.geteuid() or state.stat().st_mode&0o077:raise ValueError('state directory must be private')
    if a.plan:
        print(json.dumps({'source_pck_sha256':b['report']['input_sha256']['source_pck'],'main_sha256':b['report']['merged_sha256'],'patch_sha256':b['patch_id'],'entry_sha256':b['report']['entry_sha256'],'activation':'single active-build marker','game_files':len(b['game_files']),
                          'restoration_delta_sha256':adapter['output_sha256'] if adapter else None,
                          'required_previous_main_sha256':oldmain if adapter else None,'engine_sha256':b['report'].get('engine_sha256')},indent=2));return
    adb=upload.Adb(a.target)
    required=b['main'].stat().st_size+(delta.stat().st_size if adapter else 0)+sum((b['game']/n).stat().st_size for n in b['game_files'])+sum((b['patch']/n).stat().st_size for n in FILES|{'manifest.json'})+(b['engine'].stat().st_size if b['engine'] else 0)
    profile=b['report']['profile']
    audit_code=(HERE/'managed_dll_arch.py').read_text()
    pre=json.loads(adb.run(shlex.join(['python3','-c',audit_code+'\n'+PREFLIGHT,str(root),str(original),str(entry),a.old_entry_sha256,b['report']['entry_sha256'],json.dumps(sorted(b['game_files'])),str(required),profile['linux_runtime_deps_sha256'],profile['linux_godotsharp_sha256']])))
    if sha(RUNTIME_BASELINE)!=profile['runtime_baseline_manifest_sha256']:raise ValueError('runtime baseline manifest identity mismatch')
    trusted=json.loads(RUNTIME_BASELINE.read_text())
    if trusted['runtime_deps_sha256']!=profile['linux_runtime_deps_sha256'] or trusted['godotsharp_sha256']!=profile['linux_godotsharp_sha256'] or {n:v['sha256'] for n,v in pre['baseline_files'].items()}!=trusted['files']:
        raise ValueError('runtime files differ from audited Linux ARM64 baseline')
    manifest={'source_pck_sha256':b['report']['input_sha256']['source_pck'],'main_sha256':b['report']['merged_sha256'],'main_bytes':b['main'].stat().st_size,'patch_sha256':b['patch_id'],'game_files':b['game_files'],'release_sha256':sha(b['release']),'entry_sha256':b['report']['entry_sha256'],'runtime_binding':pre['runtime_binding'],'baseline_files':pre['baseline_files'],'extension_files':pre['extension_files']}
    if b['engine']:manifest['engine_sha256']=ENGINE_SHA
    raw=(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode();identity=hashlib.sha256(raw).hexdigest()
    if pre['active_build'] not in (None,identity,a.replace_build) or (a.replace_build and pre['active_build'] not in (a.replace_build,identity)):
        raise ValueError('active build differs from explicit replacement')
    stage=adb.run(shlex.join(['python3','-c',CHECK_BOUND_STAGE,str(root),identity]))
    if stage not in ('bound','absent'):raise ValueError('foreign build stage')
    check_capacity(pre['free_bytes'],required,stage=='bound')
    bundle=str(root/'builds'/identity)
    for directory in (str(root/'builds'),bundle,bundle+'/data',bundle+'/patch'):
        upload.remote_hash(adb,directory,'.probe')
    with tempfile.TemporaryDirectory(prefix='sts2-v110-manifest-') as tmp:
        path=Path(tmp)/'manifest.json';path.write_bytes(raw)
        for name,item in [('manifest.json',path),('release_info.json',b['release']),('entry.sh',b['entry'])]:send_file(adb,bundle,name,item,state)
        if b['engine']:send_file(adb,bundle,'engine.bin',b['engine'],state)
        for n in sorted(b['game_files']):send_file(adb,bundle+'/data',n,b['game']/n,state)
        for n in sorted(FILES|{'manifest.json'}):send_file(adb,bundle+'/patch',n,b['patch']/n,state)
        if adapter and pre['active_build']==a.replace_build:
            adapter_path=Path(tmp)/'restore-adapter.json';adapter_path.write_text(json.dumps(adapter)+'\n')
            send_file(adb,bundle,'restore-delta.pck',delta,state)
            send_file(adb,bundle,'restore-adapter.json',adapter_path,state)
            module=(HERE.parent/'godot_pck/merge_texture_pck.py').read_text()
            helper=(HERE/'merge_v110_delta.py').read_text()
            code="import sys,types\nm=types.ModuleType('merge_texture_pck');sys.modules[m.__name__]=m\nexec("+repr(module)+",m.__dict__)\n"+helper
            result=adb.run(shlex.join(['python3','-c',code,'merge',str(root),a.replace_build,identity,oldmain,dr['delta_sha256'],b['report']['merged_sha256'],mode]),timeout=900)
            if result.splitlines()[-1]!=b['report']['merged_sha256']:raise ValueError('device merge did not publish the reviewed main')
        elif a.replace_build and pre['active_build']==a.replace_build:
            reuse_main(adb,str(root),a.replace_build,identity,b['report']['merged_sha256'],state,reviewed=a.reuse_reviewed_main,budget=a.reuse_budget_main,mono=a.reuse_mono_main)
        else:send_file(adb,bundle,'main.pck',b['main'],state)
    result=adb.run(shlex.join(['python3','-c',audit_code+'\n'+COMMIT,str(root),str(original),str(entry),identity,a.old_entry_sha256,b['report']['entry_sha256'],pre['active_patch'] or '',pre['active_texture'] or '',pre['active_build'] or '']))
    print(result)
    if adapter:
        module=(HERE.parent/'godot_pck/merge_texture_pck.py').read_text()
        helper=(HERE/'merge_v110_delta.py').read_text()
        code="import sys,types\nm=types.ModuleType('merge_texture_pck');sys.modules[m.__name__]=m\nexec("+repr(module)+",m.__dict__)\n"+helper
        adapter_sha=hashlib.sha256((json.dumps(adapter)+'\n').encode()).hexdigest()
        try:
            cleaned=adb.run(shlex.join(['python3','-c',code,'cleanup',str(root),str(original),identity,dr['delta_sha256'],adapter_sha,b['report']['merged_sha256']]),timeout=900)
            print('restoration intermediates cleaned: '+cleaned)
        except RuntimeError as exc:
            print('build activated but restoration cleanup remains: '+str(exc),file=sys.stderr)


if __name__=='__main__':
    try:main()
    except (OSError,ValueError,KeyError,TypeError,RuntimeError) as exc:
        print('v110 install failed: '+str(exc),file=sys.stderr);sys.exit(1)
