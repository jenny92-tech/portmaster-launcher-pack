#!/usr/bin/env python3
# INPUT: fixed private dd5c pack and one-entry Mono subset delta on the device
# OUTPUT: isolated reviewed 9caf main and sidecar; selector and source stay intact
# POS: explicit private trial only; never launches the game or alters the active build
import hashlib
import json
import os
from pathlib import Path
import stat
import merge_texture_pck as m

ACTIVE='ca236d08f22d406e8361512bcb45208f281b1f2fac79878ad114468c758ba4c9'
BASE='dd5c7fa6edd32e61c98b508a975793ef79593a196ffae9c5e841fc3640a51fdd'
BASE_PARENT='099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c'
BASE_DELTA='4119d66135932df11eb3f1187488ca0db6fc9700858accf5658b2fb7cdbb999b'
DELTA='7664064d13008ca34d7d67070d2fede95ac28a06129ac26ec2043f7d74f4217f'
EXPECTED='9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad'
TARGET='.godot/imported/NotoSansMonoCJKsc-Regular.otf-305974efdd77ba2d99a45c70df2b9c8e.fontdata'
OLD='ec577d7bd825277c8956fc2a5adc9be10506ca25e232716a31d5613562aa6718'
NEW='440008fa82545d36151305898a923f148c5f551286a6b178f0ced013c4e44831'
root=Path('/mnt/sdcard/roms/ports/sts2-vk-test')
source=root/'font-budget-trial-a1/packs'/(BASE+'.pck')
sidecar=source.with_suffix('.json')
delta=Path('/tmp/sts2-mono-subset-trial-a1/delta.pck')
out=root/'mono-subset-trial-a1'

def directory(path):
 fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
 try:
  for part in path.parts[1:]:
   child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=child
 finally:os.close(fd)

def read_file(path):
 fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW);s=os.fstat(fd)
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:os.close(fd);raise ValueError('unsafe input')
 with os.fdopen(fd,'rb') as f:return f.read()

def selected():
 if read_file(root/'active-build').decode().strip()!=ACTIVE:raise ValueError('active build changed')
 if hashlib.sha256(read_file(root/'builds'/ACTIVE/'manifest.json')).hexdigest()!=ACTIVE:raise ValueError('active manifest mismatch')

def main():
 for path in (root,root/'builds'/ACTIVE,source.parent,delta.parent,out.parent):directory(path)
 if out.exists() or out.is_symlink():raise ValueError('trial output already exists')
 selected();side=json.loads(read_file(sidecar))
 for path in (source,delta):
  s=path.lstat()
  if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('unsafe pack input')
 st=source.stat()
 if (side.get('source_sha256')!=BASE_PARENT or side.get('overlay_sha256')!=BASE_DELTA or side.get('merged_sha256')!=BASE or
     side.get('merged_stat')!={'size':st.st_size,'mtime_ns':st.st_mtime_ns}):raise ValueError('parent sidecar mismatch')
 if m.sha256_file(source)!=BASE or m.sha256_file(delta)!=DELTA:raise ValueError('input SHA mismatch')
 a,b=m.read_pack(source),m.read_pack(delta)
 if set(b)!={TARGET} or TARGET not in a:raise ValueError('unexpected replacement set')
 with source.open('rb') as original,delta.open('rb') as replacement:
  if m.entry_sha256(original,a[TARGET])!=OLD or m.entry_sha256(replacement,b[TARGET])!=NEW:raise ValueError('font entry SHA mismatch')
 selected();out.mkdir(mode=0o700);adapter=out/'adapter.json'
 adapter.write_text(json.dumps({'source_sha256':BASE,'output_sha256':DELTA,'resources':[{'path':TARGET,'kind':'audited_font',
  'source_sha256':OLD,'output_sha256':NEW,'output_md5':b[TARGET][2].hex()}]},sort_keys=True)+'\n')
 approval={TARGET:OLD};m.AUDITED_FONT_SOURCE_SHA256=approval
 result=m.prepare(source,delta,adapter,out/'packs',approved_font_hashes=approval)
 selected()
 if result.name!=EXPECTED+'.pck' or m.sha256_file(result)!=EXPECTED:raise ValueError('output mismatch')
 print(json.dumps({'main':str(result),'sha256':EXPECTED,'delta':DELTA,'target':TARGET}))
if __name__=='__main__':main()
