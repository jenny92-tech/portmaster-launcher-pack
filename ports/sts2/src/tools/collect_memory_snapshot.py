#!/usr/bin/env python3
# INPUT: explicit STS2 device, build ID, PID/starttime and stage label
# OUTPUT: a new private JSON snapshot of aggregate process/system memory
# POS: read-only status/rollup/status sampling; no addresses, heap or environment
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

REMOTE = r'''import datetime,json,os,sys
from pathlib import Path
pid=int(sys.argv[1]);wanted=sys.argv[2];build=sys.argv[3];p=Path('/proc')/str(pid)
def identity():
 s=(p/'stat').read_text().rsplit(')',1)[1].split()[19]
 a=(p/'cmdline').read_bytes().split(b'\0');exe=os.readlink(p/'exe')
 assert s==wanted and a[0]==b'unityloader' and exe.endswith('/'+build+'/game/godot.mono')
 main=Path('/mnt/sdcard/roms/ports/sts2-vk-test/builds')/build/'main.pck'
 trial=Path(exe).parent/'SlayTheSpire2.pck'
 assert str(main).encode() in a or (str(trial).encode() in a and trial.is_symlink() and trial.resolve(strict=True)==main.resolve(strict=True))
 return s
def values(path,names):
 out={}
 for line in path.read_text().splitlines():
  k,sep,v=line.partition(':')
  if sep and k in names:out[k]=int(v.strip().split()[0])
 return out
sk={'VmHWM','VmRSS','RssAnon','RssFile','RssShmem','VmSwap'}
rk={'Rss','Pss','Pss_Anon','Pss_File','Pss_Shmem','Private_Clean','Private_Dirty','Shared_Clean','Shared_Dirty','Swap'}
mk={'MemTotal','MemAvailable','SwapTotal','SwapFree','Shmem','Cached','Slab'}
before=identity();a=values(p/'status',sk);b=values(p/'smaps_rollup',rk);c=values(p/'status',sk);m=values(Path('/proc/meminfo'),mk);after=identity()
print(json.dumps({'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'pid':pid,'starttime_before':before,'starttime_after':after,'status_before_kib':a,'rollup_kib':b,'status_after_kib':c,'system_kib':m}))
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--target', required=True)
    p.add_argument('--pid', required=True, type=int)
    p.add_argument('--starttime', required=True)
    p.add_argument('--build', required=True)
    p.add_argument('--stage', required=True)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    if a.pid <= 0 or not re.fullmatch(r'[0-9]+', a.starttime) or not re.fullmatch(r'[0-9a-f]{64}', a.build):
        raise ValueError('invalid process identity')
    if not re.fullmatch(r'[a-z0-9_-]{1,40}', a.stage) or not a.output.is_absolute():
        raise ValueError('invalid stage or output path')
    command = shlex.join(['python3', '-c', REMOTE, str(a.pid), a.starttime, a.build])
    run = subprocess.run(['adb', '-s', a.target, 'shell', '-T', command], check=True,
                         capture_output=True, text=True, timeout=20)
    result = json.loads(run.stdout)
    if result['starttime_before'] != a.starttime or result['starttime_after'] != a.starttime:
        raise ValueError('process identity changed')
    result['stage'] = a.stage
    fd = os.open(a.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(a.output)


if __name__ == '__main__':
    main()
