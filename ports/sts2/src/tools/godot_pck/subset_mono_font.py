#!/usr/bin/env python3
# INPUT: exact f526/dd5c PCKs, verified FontTools wheel and audited host/ARM Godot engines
# OUTPUT: reproducible one-FontFile subset delta and offline UID/coverage evidence
# POS: private trial builder; does not alter existing packs, run game logic or contact device
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unicodedata
import low_texture_overlay as low
from font_fallback_trial import collect_strings

SOURCE='f526ef85cd5b7cf653defb545a8ba22196c72e6a0e95ad66f78f2f3a168b28c9'
BASE='dd5c7fa6edd32e61c98b508a975793ef79593a196ffae9c5e841fc3640a51fdd'
GODOT='0d214c6c85e47e7060ac13b035b404ce4dda653992503914963e149a45cd0dca'
ARM_GODOT='93d0952f7b082e221b15eb2f060b20c0237aabf9fea6ec2639cf31d415ce7e9e'
WHEEL='73cf92eeda67cf6ff10c8af56fc8f4f07c1647d989a979be9e388a49be26552a'
IMAGE='sha256:cd2919b9c84b6a13e9324a98d4631d4fe1bf930dfe0c02b8f678c3eb5e2f3e1d'
MONO='.godot/imported/NotoSansMonoCJKsc-Regular.otf-305974efdd77ba2d99a45c70df2b9c8e.fontdata'
MEDIUM='.godot/imported/SourceHanSerifSC-Medium.otf-8b1ba143f94f2163fdbd47c3f56634f6.fontdata'
MONO_SOURCE='89b8497ad0ca58e9e53e45e522ef2a345fa944f6a26fbdebf3c3261eb9b28df9'
MONO_BASE='ec577d7bd825277c8956fc2a5adc9be10506ca25e232716a31d5613562aa6718'
MEDIUM_BASE='9761840a5af9f475cd3a784c3fcda3f3d4e108b7354a1959ff6cc8a987d6f10c'
HERE=Path(__file__).resolve().parent
WORKER=HERE/'subset_mono_font.gd';SUBSET=HERE/'subset_mono_font_worker.py';UID=HERE/'subset_mono_uid_fixture.gd'

def digest(b):return hashlib.sha256(b).hexdigest()
def run(command,label,timeout=300):
 p=subprocess.run(command,capture_output=True,text=True,timeout=timeout)
 if p.returncode:raise RuntimeError(label+' failed: '+p.stdout+'\n'+p.stderr)
 return p.stdout

def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ('source-pck','base-main','wheel','godot','arm-godot','output-dir'):p.add_argument('--'+name,type=Path,required=True)
 a=p.parse_args();raw=[a.source_pck,a.base_main,a.wheel,a.godot,a.arm_godot]
 if any(x.is_symlink() for x in raw):raise ValueError('symlink input')
 paths=[x.resolve(strict=True) for x in raw]
 if any(x.samefile(y) for i,x in enumerate(paths) for y in paths[i+1:]):raise ValueError('duplicate inputs')
 for x,h in zip(paths,(SOURCE,BASE,WHEEL,GODOT,ARM_GODOT)):
  if low.file_hash(x)!=h:raise ValueError('input SHA mismatch: '+str(x))
 source,base,wheel,godot,arm=paths;dest=a.output_dir.absolute();dest=dest.parent.resolve(strict=True)/dest.name
 if dest.exists() or dest.is_symlink() or any(dest==x or dest in x.parents for x in paths):raise ValueError('fresh separate output required')
 if run(['docker','image','inspect','--format','{{.Id}}','rudroid-rust-gles:20260917'],'docker image').strip()!=IMAGE:raise ValueError('subset container identity mismatch')
 os.umask(0o077);dest.mkdir(mode=0o700);project=dest/'project';project.mkdir();(project/'project.godot').write_text('[application]\nconfig/name="Isolated subset font trial"\n')
 source_entries=low.read_pack(source);base_entries=low.read_pack(base);locale=[];codepoints=set()
 imports=['fonts/zhs/NotoSansMonoCJKsc-Regular.otf.import','fonts/zhs/SourceHanSerifSC-Medium.otf.import']
 with source.open('rb') as s,base.open('rb') as b:
  for name,expected in ((MONO,MONO_BASE),(MEDIUM,MEDIUM_BASE)):
   value=low.entry_bytes(b,base_entries[name])
   if digest(value)!=expected:raise ValueError('parent font identity mismatch')
   if name==MONO and digest(low.entry_bytes(s,source_entries[name]))!=MONO_SOURCE:raise ValueError('original Mono identity mismatch')
   f=project/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(value)
   if name==MONO:(project/'original.res').write_bytes(value)
  for name in imports:
   raw=low.entry_bytes(s,source_entries[name])
   if raw!=low.entry_bytes(b,base_entries[name]):raise ValueError('font import mapping changed')
   f=project/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(raw)
  uid=low.entry_bytes(b,base_entries['.godot/uid_cache.bin']);(project/'.godot/uid_cache.bin').write_bytes(uid)
  locales=sorted(x for x in source_entries if x.startswith('localization/zhs/') and x.endswith('.json'))
  if len(locales)!=46:raise ValueError('unexpected locale count')
  for name in locales:
   value=low.entry_bytes(s,source_entries[name])
   if value!=low.entry_bytes(b,base_entries[name]):raise ValueError('localization differs')
   locale.append({'path':name,'sha256':digest(value)});collect_strings(json.loads(value.decode('utf-8-sig')),codepoints)
 cps=sorted(cp for cp in codepoints if unicodedata.category(chr(cp)) not in ('Cc','Cf'))
 if len(cps)!=2493:raise ValueError('unexpected codepoint corpus')
 (project/'manifest.json').write_text(json.dumps({'codepoints':cps}))
 version=run([str(godot),'--version'],'Godot version').strip()
 if not version.startswith('4.5.1.stable.official'):raise ValueError('unexpected host Godot')
 command=[str(godot),'--headless','--path',str(project),'--script',str(WORKER),'--']
 if 'MONO_EXTRACT_OK' not in run(command+['extract'],'font extract'):raise ValueError('font extract failed')
 # The container has no network, capabilities, writable root, or access to the workspace beyond four specific mounts.
 for i in (1,2):
  args=['docker','run','--rm','--network','none','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges',
   '--mount',f'type=bind,src={wheel},dst=/wheel.whl,readonly',
   '--mount',f'type=bind,src={project}/mono.otf,dst=/mono.otf,readonly',
   '--mount',f'type=bind,src={project}/medium.otf,dst=/medium.otf,readonly',
   '--mount',f'type=bind,src={SUBSET},dst=/worker.py,readonly',
   '--mount',f'type=bind,src={project},dst=/out','--entrypoint','/usr/bin/python3',IMAGE,
   '-B','/worker.py','/wheel.whl','/mono.otf','/medium.otf',f'/out/subset{i}.otf',f'/out/subset{i}.json']
  run(args,'isolated subset',600)
 subset1=project/'subset1.otf';subset2=project/'subset2.otf'
 if low.file_hash(subset1)!=low.file_hash(subset2):raise ValueError('subset is not byte reproducible')
 shutil.copyfile(subset1,project/'subset.otf')
 produced=run(command+['produce'],'font serialization');rows=[x.partition('\t')[2] for x in produced.splitlines() if x.startswith('MONO_CANDIDATE\t')]
 if len(rows)!=1:raise ValueError('font serialization evidence missing')
 val=json.loads(rows[0]);candidate=project/'candidate.res'
 if val['vector_sha256']!=low.file_hash(subset1) or val['fallback_base']!='res://fonts/zhs/SourceHanSerifSC-Medium.otf' or not val['same_medium'] or not val['system_fallback'] or val['pages']!=0:raise ValueError('font serialization validation failed')
 delta=dest/'mono-subset.pck';low.write_pack([(MONO,candidate)],delta);idx=low.read_pack(delta)
 if set(idx)!={MONO}:raise ValueError('unexpected delta targets')
 with delta.open('rb') as f:
  if digest(low.entry_bytes(f,idx[MONO]))!=low.file_hash(candidate):raise ValueError('delta output mismatch')
 shutil.copyfile(UID,project/'uid_fixture.gd')
 args=['docker','run','--rm','--network','none','--read-only','--tmpfs','/tmp:rw,nosuid,nodev,size=32m','--env','XDG_DATA_HOME=/tmp','--env','XDG_CACHE_HOME=/tmp','--cap-drop','ALL','--security-opt','no-new-privileges',
  '--mount',f'type=bind,src={arm},dst=/godot,readonly','--mount',f'type=bind,src={project},dst=/fixture,readonly',
  '--mount',f'type=bind,src={base},dst=/parent.pck,readonly','--mount',f'type=bind,src={delta},dst=/delta.pck,readonly',
  '--entrypoint','/godot','sts2-godot-vma-focal:928','--headless','--path','/fixture','--script','res://uid_fixture.gd']
 uid_output=run(args,'full parent UID fixture',900);rows=[x.partition('\t')[2] for x in uid_output.splitlines() if x.startswith('MONO_UID_RESULT\t')]
 if len(rows)!=1:raise ValueError('UID fixture evidence missing')
 uid_result=json.loads(rows[0])
 if uid_result['game_count']!=2493 or uid_result['coverage_losses'] or uid_result['all_font_losses'] or uid_result['width_mismatches'] or uid_result['string_differences'] or not uid_result['same_medium_instance']:raise ValueError('UID fixture failed')
 item={'target':MONO,'source_sha256':MONO_SOURCE,'base_sha256':MONO_BASE,'output_sha256':low.file_hash(candidate),'output_md5':hashlib.md5(candidate.read_bytes()).hexdigest(),'import_path':imports[0]}
 report={'source_sha256':SOURCE,'base_main_sha256':BASE,'delta_sha256':low.file_hash(delta),'godot_sha256':GODOT,'arm_godot_sha256':ARM_GODOT,'wheel_sha256':WHEEL,'container_image_id':IMAGE,'builder_sha256':low.file_hash(Path(__file__)),'worker_sha256':low.file_hash(WORKER),'subset_worker_sha256':low.file_hash(SUBSET),'uid_fixture_sha256':low.file_hash(UID),'locale_files':locale,'subset':json.loads((project/'subset1.json').read_text()),'serialization':val,'uid_validation':uid_result,'resources':[item],
 'limitations':['Candidate intentionally replaces some Mono ideographs by Medium; outlines and shaping may differ.', 'Only known game codepoints and representative strings are measured, not arbitrary user text, all OpenType sequences, device visuals or RSS.', 'System fallback remains enabled; retained and delegated cmap/advance checks do not prove all variation and shaping behavior.']}
 (dest/'report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n');print(json.dumps({'delta':str(delta),'sha256':report['delta_sha256'],'report':str(dest/'report.json')}))
if __name__=='__main__':
 try:main()
 except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError) as e:raise SystemExit('Mono subset trial failed: '+str(e))
