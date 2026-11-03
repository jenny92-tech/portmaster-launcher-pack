#!/usr/bin/env python3
# INPUT: exact f526 source, 9caf main, reviewed Medium metrics and host/ARM Godot
# OUTPUT: source-bound one-font 40/14 delta and UID/quality-tradeoff evidence
# POS: isolated trial; no game logic, device operation or existing-pack modification
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import low_texture_overlay as low

SOURCE='f526ef85cd5b7cf653defb545a8ba22196c72e6a0e95ad66f78f2f3a168b28c9'
BASE='9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad'
GODOT='0d214c6c85e47e7060ac13b035b404ce4dda653992503914963e149a45cd0dca'
ARM='93d0952f7b082e221b15eb2f060b20c0237aabf9fea6ec2639cf31d415ce7e9e'
METRICS='0dca2d9d5eb76979188f1f047bb4b3a292036a805a5f6c5b7882d92071b0af4d'
TARGET='.godot/imported/SourceHanSerifSC-Medium.otf-8b1ba143f94f2163fdbd47c3f56634f6.fontdata'
IMPORT='fonts/zhs/SourceHanSerifSC-Medium.otf.import'
SOURCE_ENTRY='e73efe426dd1f713e31b58ee34544bb0567949645b51d14059486c604478494e'
BASE_ENTRY='9761840a5af9f475cd3a784c3fcda3f3d4e108b7354a1959ff6cc8a987d6f10c'
HERE=Path(__file__).resolve().parent;WORKER=HERE/'font_atlas_trial.gd';UID=HERE/'font_atlas_uid_fixture.gd'

def digest(data):return hashlib.sha256(data).hexdigest()
def run(command,label,timeout=300):
 p=subprocess.run(command,capture_output=True,text=True,timeout=timeout)
 if p.returncode:raise RuntimeError(label+' failed: '+p.stdout+'\n'+p.stderr)
 return p.stdout

def main():
 p=argparse.ArgumentParser(description=__doc__)
 for n in ('source-pck','base-main','godot','arm-godot','metrics-report','output-dir'):p.add_argument('--'+n,type=Path,required=True)
 a=p.parse_args();raw=[a.source_pck,a.base_main,a.godot,a.arm_godot,a.metrics_report]
 if any(x.is_symlink() for x in raw):raise ValueError('symlink input')
 paths=[x.resolve(strict=True) for x in raw]
 if any(x.samefile(y) for i,x in enumerate(paths) for y in paths[i+1:]):raise ValueError('duplicate input')
 for x,expected in zip(paths,(SOURCE,BASE,GODOT,ARM,METRICS)):
  if low.file_hash(x)!=expected:raise ValueError('input identity mismatch: '+str(x))
 source,base,godot,arm,metrics_file=paths;dest=a.output_dir.absolute();dest=dest.parent.resolve(strict=True)/dest.name
 if dest.exists() or dest.is_symlink() or any(dest==x or dest in x.parents for x in paths):raise ValueError('fresh separate output required')
 study=json.loads(metrics_file.read_text());page=study['fixed_500_medium'];comp=study['comparisons']
 if (study['msdf_size']!=40 or study['range']!=14 or study['corpus_sizes']!=[2493,104] or page['glyphs']!=500 or
     page['baseline']['rgba8_nominal_bytes']!=15728640 or page['candidate']['rgba8_nominal_bytes']!=11534336 or
     len(comp)!=3 or any(x['coverage_losses'] for x in comp) or comp[2]['width_mismatch_count']!=0):
  raise ValueError('unexpected metrics study')
 version=run([str(godot),'--version'],'Godot version').strip()
 if not version.startswith('4.5.1.stable.official'):raise ValueError('host Godot version mismatch')
 se=low.read_pack(source);be=low.read_pack(base)
 with source.open('rb') as s,base.open('rb') as b:
  old=low.entry_bytes(s,se[TARGET]);current=low.entry_bytes(b,be[TARGET]);si=low.entry_bytes(s,se[IMPORT]);bi=low.entry_bytes(b,be[IMPORT])
 if digest(old)!=SOURCE_ENTRY or digest(current)!=BASE_ENTRY or si!=bi:raise ValueError('font or import identity mismatch')
 os.umask(0o077);dest.mkdir(mode=0o700);project=dest/'project';project.mkdir();(project/'project.godot').write_text('[application]\nconfig/name="Isolated font atlas trial"\n')
 (project/'medium.res').write_bytes(current)
 command=[str(godot),'--headless','--path',str(project),'--script',str(WORKER)]
 records=[]
 for i in (1,2):
  text=run(command,'font serialization');values=[x.partition('\t')[2] for x in text.splitlines() if x.startswith('FONT_ATLAS_RESULT\t')]
  if len(values)!=1:raise ValueError('font worker evidence missing')
  records.append(json.loads(values[0]));shutil.copyfile(project/'candidate.res',project/f'candidate{i}.res')
 candidate=project/'candidate1.res'
 if low.file_hash(candidate)!=low.file_hash(project/'candidate2.res') or records[0]!=records[1]:raise ValueError('font output is not reproducible')
 delta=dest/'font-atlas-delta.pck';low.write_pack([(TARGET,candidate)],delta);entries=low.read_pack(delta)
 if set(entries)!={TARGET}:raise ValueError('unexpected delta target')
 with delta.open('rb') as f:
  if digest(low.entry_bytes(f,entries[TARGET]))!=low.file_hash(candidate):raise ValueError('delta payload mismatch')
 shutil.copyfile(UID,project/'uid_fixture.gd')
 command=['docker','run','--rm','--network','none','--read-only','--tmpfs','/tmp:rw,nosuid,nodev,size=32m',
  '--env','XDG_DATA_HOME=/tmp','--env','XDG_CACHE_HOME=/tmp','--cap-drop','ALL','--security-opt','no-new-privileges',
  '--mount',f'type=bind,src={arm},dst=/godot,readonly','--mount',f'type=bind,src={project},dst=/fixture,readonly',
  '--mount',f'type=bind,src={base},dst=/parent.pck,readonly','--mount',f'type=bind,src={delta},dst=/delta.pck,readonly',
  '--entrypoint','/godot','sts2-godot-vma-focal:928','--headless','--path','/fixture','--script','res://uid_fixture.gd']
 text=run(command,'full PCK UID fixture');values=[x.partition('\t')[2] for x in text.splitlines() if x.startswith('FONT_ATLAS_UID\t')]
 if len(values)!=1:raise ValueError('UID fixture evidence missing')
 uid=json.loads(values[0])
 report={'source_sha256':SOURCE,'base_main_sha256':BASE,'delta_sha256':low.file_hash(delta),'metrics_report_sha256':METRICS,
  'godot_sha256':GODOT,'arm_godot_sha256':ARM,'builder_sha256':low.file_hash(Path(__file__)),'worker_sha256':low.file_hash(WORKER),'uid_fixture_sha256':low.file_hash(UID),
  'resources':[{'target':TARGET,'source_sha256':SOURCE_ENTRY,'base_sha256':BASE_ENTRY,'output_sha256':low.file_hash(candidate),'output_md5':hashlib.md5(candidate.read_bytes()).hexdigest(),'import_path':IMPORT,'import_sha256':digest(si)}],
  'serialization':records[0],'uid_validation':uid,'metrics_summary':{'source_size':48,'source_range':16,'output_size':40,'output_range':14,'fixed_500_medium':page,'comparisons':comp},
  'limitations':['Medium glyph size and advance/line metrics change; synthetic bold strings differ and may reflow.',
   'Mono vector and size remain but its Medium fallback ascent changes; dynamic text and all glyph shaping are not proven.',
   'Offline headless atlas bytes are not actual game residency, GPU usage or RSS; CPU previews are not device visual proof.']}
 (dest/'report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n');print(json.dumps({'delta':str(delta),'sha256':report['delta_sha256'],'report':str(dest/'report.json')}))
if __name__=='__main__':
 try:main()
 except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError) as e:raise SystemExit('font atlas trial failed: '+str(e))
