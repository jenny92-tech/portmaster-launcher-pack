#!/usr/bin/env python3
# INPUT: fixed Windows source, frozen 7ec main, official Godot 4.5.1
# OUTPUT: isolated four-entry font budget delta with identity/coverage report
# POS: opt-in quality trial; never mutates a main pack or touches a device
import argparse
import hashlib
import json
import os
import subprocess
import unicodedata
from pathlib import Path
import low_texture_overlay as low
import strip_font_cache as sc
import strip_common_font_cache as common
from font_fallback_trial import collect_strings

SOURCE_SHA = 'f526ef85cd5b7cf653defb545a8ba22196c72e6a0e95ad66f78f2f3a168b28c9'
MAIN_SHA = '7ec4bb3f96fd01dc42bde20b6daa2f98cd16f09cec3b8ef404efd53f089615f1'
GODOT_SHA = '0d214c6c85e47e7060ac13b035b404ce4dda653992503914963e149a45cd0dca'
WORKER = Path(__file__).with_suffix('.gd')
BOLD = 'themes/fonts/zhs/source_han_serif_sc_bold_shared.tres'
BOLD_SHA = '158ec047797545776ac195380e0646de34b7656b613a9dbce8dbc730215a96d9'
DATA_SHA = {
 'SourceHanSerifSC-Medium': '210dc788c6cc15ed693c8ecde93ee83bf7714b759befa6aead042d6f6e1b878a',
 'SourceHanSerifSC-Bold': '4564e8fb84d572e0b8b4e2980f3e23efc0c9956e64c84affce715a6de77cee27',
 'NotoSansMonoCJKsc-Regular': '2b1dbdc50df666a00c50ecd77377e2394c6babd35a71e37505ab411ff55c7906',
}
OLD_REF = b'uid="uid://wcoiw83db02h" path="res://fonts/zhs/SourceHanSerifSC-Bold.otf"'
NEW_REF = b'uid="uid://odbxx5stx1as" path="res://fonts/zhs/SourceHanSerifSC-Medium.otf"'
ANCHOR = b'base_font = ExtResource("1_hbd7y")\n'

def digest(data): return hashlib.sha256(data).hexdigest()

def patch_bold(data):
 if digest(data)!=BOLD_SHA or data.count(OLD_REF)!=1 or data.count(ANCHOR)!=1: raise ValueError('unexpected bold shared input')
 return data.replace(OLD_REF,NEW_REF).replace(ANCHOR,ANCHOR+b'variation_embolden = 0.3\n')

def main():
 p=argparse.ArgumentParser(description=__doc__)
 for key in ('source-pck','base-main','godot','work-dir','output','report'):p.add_argument('--'+key,type=Path,required=True)
 a=p.parse_args();low.ensure_distinct_paths((a.source_pck,a.base_main,a.godot,a.output,a.report))
 if any(x.exists() or x.is_symlink() for x in (a.work_dir,a.output,a.report)):raise ValueError('fresh output/work paths required')
 for path,expected in ((a.source_pck,SOURCE_SHA),(a.base_main,MAIN_SHA),(a.godot,GODOT_SHA)):
  if low.file_hash(path)!=expected:raise ValueError('input identity mismatch: '+str(path))
 version=subprocess.run([str(a.godot),'--version'],capture_output=True,text=True,check=True).stdout.strip()
 if not version.startswith('4.5.1.stable.official'):raise ValueError('unexpected Godot')
 os.umask(0o077);a.work_dir.mkdir(parents=True,mode=0o700);project=a.work_dir/'project';project.mkdir()
 (project/'project.godot').write_text('[application]\nconfig/name="Isolated font budget trial"\n')
 source=low.read_pack(a.source_pck);base=low.read_pack(a.base_main);records=[];manifest={'fonts':[]};cps=set();locale=[]
 with a.source_pck.open('rb') as s,a.base_main.open('rb') as b:
  for stem,expected_data in DATA_SHA.items():
   matches=[x for x in common.SC_OUTPUTS if x.startswith(stem+'.')]
   if len(matches)!=1:raise ValueError('font name mismatch '+stem)
   name=matches[0];target='.godot/imported/'+name;imp=sc.FONTS[name][0]
   original=low.entry_bytes(s,source[target]);current=low.entry_bytes(b,base[target]);imps=low.entry_bytes(s,source[imp]);impb=low.entry_bytes(b,base[imp])
   if digest(original)!=sc.FONTS[name][1] or digest(current)!=common.SC_OUTPUTS[name] or imps!=impb:raise ValueError('font or import mismatch '+stem)
   dest=project/target;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(current)
   impdest=project/imp;impdest.parent.mkdir(parents=True,exist_ok=True);impdest.write_bytes(imps)
   out='res://budget-'+str(len(records))+'.res'
   manifest['fonts'].append({'input':'res://'+target,'output':out,'data_sha':expected_data})
   records.append({'target':target,'import_path':imp,'import_sha256':digest(imps),'source_sha256':digest(original),'base_sha256':digest(current),'font_data_sha256':expected_data})
  initial=low.entry_bytes(s,source[BOLD]);current=low.entry_bytes(b,base[BOLD])
  if initial!=current:raise ValueError('bold variation source/base mismatch')
  candidate=patch_bold(current);boldfile=project/'bold-shared.tres';boldfile.write_bytes(candidate)
  for path in ('themes/fonts/zhs/source_han_serif_sc_medium_shared.tres','themes/fonts/zhs/noto_sans_mono_cjksc_regular_shared.tres'):
   raw=low.entry_bytes(b,base[path])
   if raw!=low.entry_bytes(s,source[path]):raise ValueError('shared variation source/base mismatch')
   dest=project/path;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(raw)
  locale_files=sorted(x for x in base if x.startswith('localization/zhs/') and x.endswith('.json'))
  if len(locale_files)!=46:raise ValueError('unexpected locale file count')
  for path in locale_files:
   sb=low.entry_bytes(s,source[path]);bb=low.entry_bytes(b,base[path])
   if sb!=bb:raise ValueError('locale changed: '+path)
   locale.append({'path':path,'sha256':digest(sb)});collect_strings(json.loads(sb.decode('utf-8-sig')),cps)
 manifest['codepoints']=sorted(cp for cp in cps if unicodedata.category(chr(cp)) not in ('Cc','Cf'))
 if len(manifest['codepoints'])!=2493:raise ValueError('unexpected corpus')
 (project/'manifest.json').write_text(json.dumps(manifest))
 command=[str(a.godot.resolve()),'--headless','--path',str(project.resolve()),'--script',str(WORKER.resolve())]
 run=subprocess.run(command,capture_output=True,text=True,timeout=300)
 rows=[x.partition('\t')[2] for x in run.stdout.splitlines() if x.startswith('FONT_BUDGET_RESULT\t')]
 if run.returncode or len(rows)!=1:raise RuntimeError('font worker failed: '+run.stdout+'\n'+run.stderr)
 evidence=json.loads(rows[0]);files=[]
 if len(evidence['fonts'])!=3 or len(evidence['comparison'])!=3:raise ValueError('worker results incomplete')
 for rec,font,comparison,item in zip(records,evidence['fonts'],evidence['comparison'],manifest['fonts']):
  out=project/item['output'].removeprefix('res://')
  if font['font_data_sha256']!=rec['font_data_sha256'] or comparison['coverage_losses'] or comparison['game_count']!=2493 or comparison['extended_count']!=23644:raise ValueError('worker validation failed')
  rec.update(output_sha256=low.file_hash(out),output_md5=hashlib.md5(out.read_bytes()).hexdigest(),validation=font,coverage_metrics=comparison)
  files.append((rec['target'],out))
 records.append({'target':BOLD,'source_sha256':digest(initial),'base_sha256':digest(current),'output_sha256':digest(candidate),'output_md5':hashlib.md5(candidate).hexdigest(),'change':'canonical Medium plus synthetic embolden 0.3; UID, transform and baseline preserved; no fallback added'})
 files.append((BOLD,boldfile));temp=a.work_dir/'verified-delta.pck';low.write_pack(sorted(files),temp);idx=low.read_pack(temp)
 if set(idx)!={x['target'] for x in records}:raise ValueError('delta closed set mismatch')
 with temp.open('rb') as stream:
  for rec in records:
   if digest(low.entry_bytes(stream,idx[rec['target']]))!=rec['output_sha256']:raise ValueError('delta payload mismatch')
 report={'source_sha256':SOURCE_SHA,'base_main_sha256':MAIN_SHA,'delta_sha256':low.file_hash(temp),'godot_sha256':GODOT_SHA,'godot_version':version,'builder_sha256':low.file_hash(Path(__file__)),'worker_sha256':low.file_hash(WORKER),'locale_files':locale,'resources':records,'shared_validation':evidence['shared_validation'],'limitations':['Experimental 720p quality tradeoff: range 16 may clamp thick outlines; synthetic bold changes advances and appearance.','System fallback retained; no new fallback is introduced.','Coverage and metrics are offline samples, not complete Unicode shaping, device visuals, GPU allocation or RSS.','Bold FontFile remains on disk; actual resident memory depends on all runtime references.']}
 staged=a.work_dir/'verified-report.json';staged.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 a.output.parent.mkdir(parents=True,exist_ok=True);a.report.parent.mkdir(parents=True,exist_ok=True);temp.replace(a.output);staged.replace(a.report)
 print('font budget delta',report['delta_sha256'])
if __name__=='__main__':main()
