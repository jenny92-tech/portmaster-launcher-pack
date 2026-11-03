#!/usr/bin/env python3
# INPUT: audited 899c release, source-bound two-language DLL, optional reviewed font budget
# OUTPUT: self-contained build for existing transactional installer
# POS: offline assembly; never alters an existing build or device
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
import optimize_handheld as o

BASE_REPORT='96aaa2ea3583946d50eea5232910aa45bc8609ac797f3c13b752e127fc34a4cf'
BASE_MAIN='099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c'
LANG_IN='dc0a93d4e86ce8982bc696e8f713d152cec971becbca9ce4f41c5b221e885f2d'
LANG_OUT='543110f1286d71b7391c4a5fcc1df75212fcc3b74c763a09f4413e57acfc0b67'
EVIDENCE='0b8c9875b2b2f1b4e76245859ad711b51b3f6dfae402ed83461c55bf5cb25d4d'
FONT_MAIN='dd5c7fa6edd32e61c98b508a975793ef79593a196ffae9c5e841fc3640a51fdd'
FONT_DELTA='4119d66135932df11eb3f1187488ca0db6fc9700858accf5658b2fb7cdbb999b'
FONT_REPORT='12d40ff17aa0eba1a8f890c35d7986364840f5f58b58178da8dd402722d3bbc1'
FONT_MERGE='5b8c45253a483425aa08e16fa71c2ea3a789135102b7a2619db2169739a6ca80'

def check(path, expected):
 if path.is_symlink() or not path.is_file() or o.sha(path)!=expected:raise ValueError('unexpected input: '+str(path))

def clone(src,dst):
 result=subprocess.run(['cp','-c',str(src),str(dst)],capture_output=True)
 if result.returncode:shutil.copyfile(src,dst)

def main(output, budget):
 cache=o.REPO/'.cache/sts2-vulkan-trial';base=cache/'release743-final3/build';lang=cache/'two-language-candidate'
 out=Path(output).absolute();out=out.parent.resolve(strict=True)/out.name
 if out.exists() or out.is_symlink() or out==base or base in out.parents:raise ValueError('output must be new and separate')
 check(base/'build-report.json',BASE_REPORT);check(base/'merged'/f'{BASE_MAIN}.pck',BASE_MAIN);check(base/'patch/sts2.dll',LANG_IN)
 check(lang/'sts2-v3.dll',LANG_OUT);check(lang/'evidence-v2.json',EVIDENCE)
 font=cache/'font-budget-099-candidate';delta=cache/'font-budget-final3.pck';report=cache/'font-budget-final3.json'
 if budget:
  check(font/'packs'/f'{FONT_MAIN}.pck',FONT_MAIN);check(font/'report.json',FONT_MERGE);check(delta,FONT_DELTA);check(report,FONT_REPORT)
  s=json.loads((font/'packs'/f'{FONT_MAIN}.json').read_text())
  if (s.get('source_sha256'),s.get('overlay_sha256'),s.get('merged_sha256'))!=(BASE_MAIN,FONT_DELTA,FONT_MAIN):raise ValueError('font sidecar mismatch')
 before=o.source_identities(o.WINDOWS_PROFILE)
 out.mkdir();build=out/'build';result=subprocess.run(['cp','-cR',str(base),str(build)],capture_output=True)
 if result.returncode:
  if build.exists():shutil.rmtree(build)
  shutil.copytree(base,build)
 clone(base/'patch/sts2.dll',build/'locale-dll-input.dll');shutil.copyfile(lang/'evidence-v2.json',build/'locale-dll-evidence.json')
 patch=build/'patch';(patch/'sts2.dll').unlink();clone(lang/'sts2-v3.dll',patch/'sts2.dll')
 manifest=json.loads((patch/'manifest.json').read_text());manifest['files']['sts2.dll']=LANG_OUT
 raw=(json.dumps(manifest,indent=2)+'\n').encode();(patch/'manifest.json').write_bytes(raw)
 data=json.loads((build/'build-report.json').read_text());data['patch_manifest_sha256']=hashlib.sha256(raw).hexdigest();data['patch_files']=manifest['files']
 data['maskfix_overlay_report']=str(build/'maskfix-overlay-report.json')
 data['two_locale']={'input_sha256':LANG_IN,'output_sha256':LANG_OUT,'evidence_sha256':EVIDENCE}
 if budget:
  (build/'merged').rename(build/'font-budget-base-merged');(build/'merged').mkdir()
  clone(font/'packs'/f'{FONT_MAIN}.pck',build/'merged'/f'{FONT_MAIN}.pck')
  shutil.copyfile(font/'packs'/f'{FONT_MAIN}.json',build/'merged'/f'{FONT_MAIN}.json')
  clone(delta,build/'font-budget-delta.pck');shutil.copyfile(report,build/'font-budget-report.json')
  (build/'font-budget-merge').mkdir();shutil.copyfile(font/'report.json',build/'font-budget-merge/report.json')
  data['font_budget']=json.loads((font/'report.json').read_text());data['merged_sha256']=FONT_MAIN;data['merged_bytes']=(font/'packs'/f'{FONT_MAIN}.pck').stat().st_size
 if before!=o.source_identities(o.WINDOWS_PROFILE):raise ValueError('assembly sources changed')
 data['assembly_source_sha256']=before
 (build/'build-report.json').write_text(json.dumps(data,indent=2,ensure_ascii=False)+'\n')
 print(json.dumps({'build':str(build),'patch_sha256':data['patch_manifest_sha256'],'main_sha256':data['merged_sha256'],'two_locale':True,'font_budget':budget}))

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True);p.add_argument('--font-budget',action='store_true');a=p.parse_args();main(a.output,a.font_budget)
