#!/usr/bin/env python3
# INPUT: reviewed private two-language entry and fixed dd5c font-budget main
# OUTPUT: private trial entry with exactly one different main PCK
# POS: isolated device comparison; no normal entry or active bundle changes
import hashlib
from pathlib import Path
import sys

ENTRY='db2a9c8f7f112ac1ee6ce464ebde0b2b07fbe4641a3d2f6ba118b64556ce366d'
MAIN='dd5c7fa6edd32e61c98b508a975793ef79593a196ffae9c5e841fc3640a51fdd'
OLD='099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c'
DELTA='4119d66135932df11eb3f1187488ca0db6fc9700858accf5658b2fb7cdbb999b'
BASE='/mnt/sdcard/roms/ports/sts2-vk-test/font-budget-trial-a1/packs'
VERIFY=r'''MAIN_PACK="@BASE@/@MAIN@.pck"
python3 - "$MAIN_PACK" <<'VERIFY_FONT_BUDGET' || exit 1
import hashlib,json,os,stat,sys
from pathlib import Path
p=Path(sys.argv[1]); side=p.with_suffix('.json')
def open_safe(x):
 fd=os.open(x,os.O_RDONLY|os.O_NOFOLLOW);s=os.fstat(fd)
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:os.close(fd);raise ValueError('unsafe font trial file')
 return os.fdopen(fd,'rb')
with open_safe(p) as f:
 h=hashlib.sha256()
 while True:
  b=f.read(1024*1024)
  if not b:break
  h.update(b)
 if h.hexdigest()!='@MAIN@':raise ValueError('font main SHA mismatch')
with open_safe(side) as f:j=json.load(f)
if (j.get('source_sha256'),j.get('overlay_sha256'),j.get('merged_sha256'))!=('@OLD@','@DELTA@','@MAIN@'):raise ValueError('font main sidecar mismatch')
print('[STS2-VK] isolated font-budget main verified')
VERIFY_FONT_BUDGET
ln -sfn "$MAIN_PACK" "$GAME/SlayTheSpire2.pck" || exit 1'''.replace('@BASE@',BASE).replace('@MAIN@',MAIN).replace('@OLD@',OLD).replace('@DELTA@',DELTA)

def main(entry, output):
 raw=Path(entry).read_bytes()
 if hashlib.sha256(raw).hexdigest()!=ENTRY:raise ValueError('unexpected two-language entry')
 text=raw.decode()
 changes={
  '/tmp/sts2-two-language-trial-a1':'/tmp/sts2-font-budget-trial-a1',
  '/tmp/sts2-memory-diag-twolanga1':'/tmp/sts2-memory-diag-fontbudgeta1',
  '/tmp/sts2-vk-two-language-a1-':'/tmp/sts2-vk-font-budget-a1-',
  'ln -sfn "$MAIN_PACK" "$GAME/SlayTheSpire2.pck" || exit 1':VERIFY,
 }
 for old,new in changes.items():
  count=text.count(old)
  if count != (2 if old=='/tmp/sts2-two-language-trial-a1' else 1):raise ValueError('entry seam mismatch: '+old)
  text=text.replace(old,new)
 with Path(output).open('x') as f:f.write(text)

if __name__=='__main__':main(*sys.argv[1:])
