#!/usr/bin/env python3
# INPUT: audited 899c entry and source-bound 543110 game DLL
# OUTPUT: private diagnostic entry; never changes the active bundle or player data
# POS: one isolated device comparison of English/Simplified Chinese language list
import hashlib
import sys
from pathlib import Path

ENTRY='9a46cc88f86463173258945a69f1ba62de50a1643348c3f802488492154a2ca2'
ACTIVE='899c01c5d7d6bfa737ba4011fb1566bfe24a12149881ec0050568de035502341'
CANDIDATE='543110f1286d71b7391c4a5fcc1df75212fcc3b74c763a09f4413e57acfc0b67'
BASE='dc0a93d4e86ce8982bc696e8f713d152cec971becbca9ce4f41c5b221e885f2d'
LAB='/tmp/sts2-two-language-trial-a1'
ROOT='/tmp/sts2-memory-diag-twolanga1'

INSERT=r'''[ "$BUILD_ID" = "@ACTIVE@" ] && [ "${SLL_DIAG_XDG_ROOT:-}" = "@ROOT@" ] && [ "${SLL_TEXTURE_DIAG:-0}" = 1 ] || { echo "[STS2-VK] language trial requires audited build and isolated diagnostics"; exit 1; }
python3 - "$GAME/data_sts2_linuxbsd_arm64/sts2.dll" "@LAB@/sts2.dll" "$SLL_DIAG_XDG_ROOT" <<'VERIFY_TWO_LANG' || exit 1
import hashlib,os,stat,sys,tempfile
from pathlib import Path
dest,src,root=map(Path,sys.argv[1:]);s=root.lstat()
if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.geteuid() or s.st_mode&0o077 or any(root.iterdir()):raise ValueError('isolated root is not private and empty')
def read(p, expected):
 fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
 try:
  s=os.fstat(fd)
  if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('unsafe DLL')
  with os.fdopen(fd,'rb',closefd=False) as f:data=f.read()
  if hashlib.sha256(data).hexdigest()!=expected:raise ValueError('DLL identity mismatch')
  return data
 finally:os.close(fd)
read(dest,'@BASE@');data=read(src,'@CANDIDATE@')
fd,name=tempfile.mkstemp(prefix='.two-language-',dir=dest.parent)
try:
 with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
 read(Path(name),'@CANDIDATE@');os.replace(name,dest)
finally:
 if os.path.exists(name):os.unlink(name)
print('[STS2-VK] isolated two-language DLL installed')
VERIFY_TWO_LANG
'''.replace('@ACTIVE@',ACTIVE).replace('@ROOT@',ROOT).replace('@LAB@',LAB).replace('@BASE@',BASE).replace('@CANDIDATE@',CANDIDATE)

def main(entry, output):
    raw=Path(entry).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=ENTRY:raise ValueError('unexpected release entry')
    text=raw.decode()
    changes={
      'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"':'SCRIPT_DIR="/mnt/sdcard/roms/ports"',
      'cache_root="/tmp/sts2-vk-test-$(id -u)"':'cache_root="/tmp/sts2-vk-two-language-a1-$(id -u)"',
      'exec > "$TESTDIR/log.txt" 2>&1':'exec > "'+LAB+'/log.txt" 2>&1',
      'ln -sfn "$TESTDIR/conf" "$GAME/conf" || exit 1':INSERT+'ln -sfn "$TESTDIR/conf" "$GAME/conf" || exit 1',
    }
    for old,new in changes.items():
        if text.count(old)!=1:raise ValueError('entry seam mismatch')
        text=text.replace(old,new,1)
    with Path(output).open('x') as f:f.write(text)

if __name__=='__main__':main(*sys.argv[1:])
