#!/usr/bin/env python3
# INPUT: audited private VMA trial entry, fixed profiler binaries and isolated output paths
# OUTPUT: non-menu launcher that preloads heaptrack solely into the game exec
# POS: one bounded diagnostic run; never changes the normal launcher or game data
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re

ENTRY_SHA='d12d931929dd92fef9421636364063858e989100a3b7c7497ef11be3d06466e7'
PRELOAD_SHA='37c601f887b8429ee57ef826bff1aa7304731dc66e41830891fe6b5be6f6d346'
PRELOAD_16_SHA='a6390b9e4ef6387355709f9a7a8374516c5a35762a1d47bee87acfac7a549e1c'
UNWIND_SHA='bc91bef95a8f38ca8d9cd52af65311eaadf6f581a28a0d5a995ac96a319ce422'
LIBDIR='/tmp/sts2-vma-lab-e080b983f6970255/profile-libs'


def digest(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()


def generate(entry,preload,unwind,device_output_dir):
    paths=[Path(x) for x in (entry,preload,unwind)]
    if any(p.is_symlink() or not p.is_file() for p in paths): raise ValueError('inputs must be regular non-symlink files')
    preload_sha=digest(paths[1])
    if digest(paths[0])!=ENTRY_SHA or preload_sha not in (PRELOAD_SHA,PRELOAD_16_SHA) or digest(paths[2])!=UNWIND_SHA: raise ValueError('input identity mismatch')
    p=PurePosixPath(device_output_dir)
    if p.parent!=PurePosixPath('/userdata') or not re.fullmatch(r'sts2-native-profile-[0-9a-f]{16}',p.name):
        raise ValueError('profile output must be a private unique userdata directory')
    s=paths[0].read_text()
    # Explicitly match the sole final game exec; no upstream helper is preloaded.
    old="    /bin/bash -c 'exec -a unityloader \"$@\"' sts2-vk \"$GAME/godot.mono\" "+chr(92)
    if s.count(old)!=1 or 'LD_PRELOAD=' in s: raise ValueError('unexpected VMA entry layout or existing preload')
    preflight='''  python3 - "'''+str(p)+'''" "'''+LIBDIR+'''" <<'VERIFY_PROFILE' || exit 1
import hashlib,os,stat,sys
from pathlib import Path
out,libs=map(Path,sys.argv[1:]); s=os.lstat(out)
if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=0o700 or list(out.iterdir()): raise ValueError('profile output must be an empty private directory')
s=os.lstat(libs)
if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=0o700 or set(os.listdir(libs))!={'libheaptrack_preload.so','libunwind.so.8'}: raise ValueError('unsafe profiler libraries')
for n,want in (('libheaptrack_preload.so','''+repr(preload_sha)+'''),('libunwind.so.8','''+repr(UNWIND_SHA)+''')):
 fd=os.open(libs/n,os.O_RDONLY|os.O_NOFOLLOW);s=os.fstat(fd)
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('unsafe profiler library')
 h=hashlib.sha256()
 while True:
  b=os.read(fd,1048576)
  if not b: break
  h.update(b)
 os.close(fd)
 if h.hexdigest()!=want:raise ValueError('profiler library identity mismatch')
VERIFY_PROFILE
'''
    new="    /bin/bash -c 'umask 077; export DUMP_HEAPTRACK_OUTPUT=\"$1\" LD_PRELOAD=\"$2\"; export LD_LIBRARY_PATH=\"$3:$LD_LIBRARY_PATH\"; shift 3; exec -a unityloader \"$@\"' sts2-vk \""+str(p)+"/trace.raw\" \""+LIBDIR+"/libheaptrack_preload.so\" \""+LIBDIR+"\" \"$GAME/godot.mono\" "+chr(92)
    marker='  launcher_platform_exec python3 "$TESTDIR/launch_exec_view.py"'
    if s.count(marker)!=1:raise ValueError('unexpected exec-view layout')
    s=s.replace(marker,preflight+marker,1)
    return s.replace(old,new,1)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('entry','preload','unwind','output'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--device-output-dir',required=True);a=p.parse_args()
    data=generate(a.entry,a.preload,a.unwind,a.device_output_dir).encode()
    fd=os.open(a.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700)
    with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
    print(hashlib.sha256(data).hexdigest())
if __name__=='__main__':main()
