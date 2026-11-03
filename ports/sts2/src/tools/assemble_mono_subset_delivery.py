#!/usr/bin/env python3
# INPUT: audited two-language/font release and reviewed single-Mono PCK delta
# OUTPUT: independent full build for existing transactional installer
# POS: offline release assembly; does not change inputs or a device
import argparse,json,shutil,subprocess
from pathlib import Path
import optimize_handheld as o

BASE_REPORT='bcd266901121f3778495c0ad67f1c070e680d94018de7364a950397409fafc5e'
BASE='dd5c7fa6edd32e61c98b508a975793ef79593a196ffae9c5e841fc3640a51fdd'
DELTA='7664064d13008ca34d7d67070d2fede95ac28a06129ac26ec2043f7d74f4217f'
REPORT='6391ae3744fa36f1238c0dcded4d6f8c6349188eaf803999c812dcd17765034c'
MERGE='548e5567fe63ceb6f1f1c2754ad3489e4c68b44848f0fe79e86df9519c1217e4'
MAIN='9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad'

def check(path, expected):
 if path.is_symlink() or not path.is_file() or o.sha(path)!=expected:raise ValueError('unexpected input: '+str(path))

def clone(src,dst):
 result=subprocess.run(['cp','-c',str(src),str(dst)],capture_output=True)
 if result.returncode:shutil.copyfile(src,dst)

def main(output):
 cache=o.REPO/'.cache/sts2-vulkan-trial';base=cache/'two-language-font-delivery-final2/build'
 candidate=cache/'mono-subset-merged2';delta=cache/'mono-subset-final3/mono-subset.pck';report=cache/'mono-subset-final3/report.json'
 out=Path(output).absolute();out=out.parent.resolve(strict=True)/out.name
 if out.exists() or out.is_symlink() or out==base or base in out.parents:raise ValueError('output must be new and separate')
 for p,h in ((base/'build-report.json',BASE_REPORT),(base/'merged'/f'{BASE}.pck',BASE),
             (candidate/'packs'/f'{MAIN}.pck',MAIN),(candidate/'report.json',MERGE),(delta,DELTA),(report,REPORT)):check(p,h)
 side=json.loads((candidate/'packs'/f'{MAIN}.json').read_text())
 if (side.get('source_sha256'),side.get('overlay_sha256'),side.get('merged_sha256'))!=(BASE,DELTA,MAIN):raise ValueError('mono subset sidecar mismatch')
 before=o.source_identities(o.WINDOWS_PROFILE)
 out.mkdir();build=out/'build';result=subprocess.run(['cp','-cR',str(base),str(build)],capture_output=True)
 if result.returncode:
  if build.exists():shutil.rmtree(build)
  shutil.copytree(base,build)
 (build/'merged').rename(build/'mono-subset-base-merged');(build/'merged').mkdir()
 clone(candidate/'packs'/f'{MAIN}.pck',build/'merged'/f'{MAIN}.pck')
 shutil.copyfile(candidate/'packs'/f'{MAIN}.json',build/'merged'/f'{MAIN}.json')
 clone(delta,build/'mono-subset-delta.pck');shutil.copyfile(report,build/'mono-subset-report.json')
 (build/'mono-subset-merge').mkdir();shutil.copyfile(candidate/'report.json',build/'mono-subset-merge/report.json')
 data=json.loads((build/'build-report.json').read_text());data['mono_subset']=json.loads((candidate/'report.json').read_text())
 data['merged_sha256']=MAIN;data['merged_bytes']=(candidate/'packs'/f'{MAIN}.pck').stat().st_size
 data['maskfix_overlay_report']=str(build/'maskfix-overlay-report.json')
 if before!=o.source_identities(o.WINDOWS_PROFILE):raise ValueError('assembly sources changed')
 data['assembly_source_sha256']=before
 (build/'build-report.json').write_text(json.dumps(data,indent=2,ensure_ascii=False)+'\n')
 print(json.dumps({'build':str(build),'main_sha256':MAIN,'patch_sha256':data['patch_manifest_sha256']}))

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True);a=p.parse_args();main(a.output)
