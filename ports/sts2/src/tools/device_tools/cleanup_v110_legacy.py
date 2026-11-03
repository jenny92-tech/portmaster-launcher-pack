#!/usr/bin/env python3
# INPUT: explicit selected build and old patch/main identities, process metadata
# OUTPUT: dry-run inventory or removal of the verified unused legacy test bundle
# POS: device-side cleanup; retains original game, saves and active build
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

FLAGS=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
FILES={'sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck','manifest.json'}


def directory(path):
    if not path.is_absolute() or '..' in path.parts:raise ValueError('absolute normalized path required')
    fd=os.open('/',FLAGS)
    try:
        for part in path.parts[1:]:
            nextfd=os.open(part,FLAGS,dir_fd=fd);os.close(fd);fd=nextfd
    finally:os.close(fd)


def read(path):
    directory(path.parent);fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW);s=os.fstat(fd)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:os.close(fd);raise ValueError('unsafe file: '+str(path))
    with os.fdopen(fd,'rb') as f:return f.read()


def digest(path):
    directory(path.parent);fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW);s=os.fstat(fd)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:os.close(fd);raise ValueError('unsafe file: '+str(path))
    h=hashlib.sha256()
    with os.fdopen(fd,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
        e=os.fstat(f.fileno())
    if (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)!=(e.st_dev,e.st_ino,e.st_size,e.st_mtime_ns):raise ValueError('file changed during checksum')
    return h.hexdigest()


def snapshot(path):
    s=os.lstat(path)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('unsafe file: '+str(path))
    return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)


def reject_protected_aliases(targets, protected):
    if {snapshot(p)[:2] for p in targets} & {snapshot(p)[:2] for p in protected}:
        raise ValueError('legacy deletion target aliases protected file')


def inspect(root, original, build_id, old_patch, old_main, proc=Path('/proc'), apply=False):
    if not all(re.fullmatch('[0-9a-f]{64}',v) for v in (build_id,old_patch,old_main)):raise ValueError('invalid identity')
    for path in (root,original,root/'patches',root/'merged',root/'builds',root/'builds'/build_id):directory(path)
    bundle=root/'builds'/build_id
    if read(root/'active-build').decode().strip()!=build_id:raise ValueError('active build changed')
    if read(root/'active-patch').decode().strip()!=old_patch or read(root/'active-texture').decode().strip()!=old_main:raise ValueError('legacy selectors changed')
    raw=read(bundle/'manifest.json')
    if hashlib.sha256(raw).hexdigest()!=build_id:raise ValueError('active build manifest mismatch')
    m=json.loads(raw);main=bundle/'main.pck';side=json.loads(read(bundle/'main.stat.json'));s=snapshot(main)
    if digest(main)!=m['main_sha256'] or snapshot(main)!=s or side!={'build_sha256':build_id,'main_sha256':m['main_sha256'],'size':s[2],'mtime_ns':s[3]}:raise ValueError('active main failed verification')
    patch=bundle/'patch';data=bundle/'data';directory(patch);directory(data)
    p=read(patch/'manifest.json')
    if hashlib.sha256(p).hexdigest()!=m['patch_sha256']:raise ValueError('active patch identity mismatch')
    pm=json.loads(p)
    if set(pm['files'])!=FILES-{'manifest.json'} or set(pm['source_files'])!={'sts2.dll','sts2.deps.json'}:raise ValueError('active patch shape mismatch')
    protected=[main,bundle/'main.stat.json',bundle/'manifest.json',patch/'manifest.json',bundle/'release_info.json',bundle/'entry.sh',root/'active-build',root.parent/'Je-杀戮尖塔2-VK测试.sh']
    for name in ('sts2.dll','sts2.deps.json','sts2_compat.dll'):
        path=original/'data_sts2_linuxbsd_arm64'/name
        if os.path.lexists(path):directory(path.parent);protected.append(path)
    for folder,files in ((patch,pm['files']),(data,m['game_files'])):
        for name,expected in files.items():
            if '/' in name or name in ('','.','..') or digest(folder/name)!=expected:raise ValueError('active bundle mismatch: '+name)
            protected.append(folder/name)
    if any(m['game_files'].get(n)!=h for n,h in pm['source_files'].items()) or digest(bundle/'release_info.json')!=m['release_sha256']:raise ValueError('active bundle cross-binding mismatch')
    if digest(root.parent/'Je-杀戮尖塔2-VK测试.sh')!=m['entry_sha256'] or digest(bundle/'entry.sh')!=m['entry_sha256']:raise ValueError('active entry mismatch')
    for name,expected in m['runtime_binding'].items():
        if digest(original/'data_sts2_linuxbsd_arm64'/name)!=expected:raise ValueError('runtime source mismatch')
        protected.append(original/'data_sts2_linuxbsd_arm64'/name)
    for folder,files in ((original/'data_sts2_linuxbsd_arm64',m['baseline_files']),(original,m['extension_files'])):
        for name,expected in files.items():
            path=folder/name;directory(path.parent);st=snapshot(path)
            if {'size':st[2],'mtime_ns':st[3]}!={k:expected[k] for k in ('size','mtime_ns')} or digest(path)!=expected['sha256']:raise ValueError('runtime file changed: '+name)
            protected.append(path)
    olddir=root/'patches'/old_patch;directory(olddir)
    if set(os.listdir(olddir))!=FILES:raise ValueError('unknown old patch contents')
    rawold=read(olddir/'manifest.json')
    if hashlib.sha256(rawold).hexdigest()!=old_patch:raise ValueError('old patch identity mismatch')
    old=json.loads(rawold)
    if set(old['files'])!=FILES-{'manifest.json'}:raise ValueError('old patch shape mismatch')
    for n,h in old['files'].items():
        if digest(olddir/n)!=h:raise ValueError('old patch mismatch: '+n)
    oldp=root/'merged'/(old_main+'.pck');olds=root/'merged'/(old_main+'.json');oldmeta=json.loads(read(olds));source=original/'gamedata/pcks/SlayTheSpire2.pck'
    if oldmeta['merged_sha256']!=old_main or digest(oldp)!=old_main or digest(source)!=oldmeta['source_sha256']:raise ValueError('old main/source identity mismatch')
    if oldmeta['merged_stat']!={'size':snapshot(oldp)[2],'mtime_ns':snapshot(oldp)[3]} or oldmeta['source_stat']!={'size':snapshot(source)[2],'mtime_ns':snapshot(source)[3]}:raise ValueError('old main/source stat changed')
    targets=[olddir/n for n in sorted(FILES)]+[oldp,olds,root/'active-patch',root/'active-texture']
    protected.append(source)
    reject_protected_aliases(targets,protected)
    identities={snapshot(p)[:2] for p in targets}
    for process in proc.iterdir():
        if not process.name.isdigit():continue
        try:
            for handle in (process/'fd').iterdir():
                try:st=handle.stat()
                except FileNotFoundError:continue
                if (st.st_dev,st.st_ino) in identities:raise ValueError('legacy file open by PID '+process.name)
            with (process/'maps').open() as maps:
                for line in maps:
                    fields=line.split(None,5)
                    if len(fields)<5:raise ValueError('invalid process maps')
                    major,minor=(int(x,16) for x in fields[3].split(':'))
                    if any((os.major(dev),os.minor(dev),ino)==(major,minor,int(fields[4])) for dev,ino in identities):raise ValueError('legacy file mapped by PID '+process.name)
        except FileNotFoundError:
            if process.exists():raise
    snapshots={p:snapshot(p) for p in targets}
    if read(root/'active-build').decode().strip()!=build_id or snapshot(main)!=s:raise ValueError('active build changed')
    total=sum(s[2] for s in snapshots.values())
    if apply:
        for path in targets:
            if snapshot(path)!=snapshots[path] or read(root/'active-build').decode().strip()!=build_id:raise ValueError('selection or legacy file changed')
            path.unlink()
        olddir.rmdir()
    return {'build_id':build_id,'old_patch':old_patch,'old_main':old_main,'files':len(targets),'bytes':total,'dry_run':not apply}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('root','original','build-id','old-patch','old-main'):p.add_argument('--'+name,required=True)
    p.add_argument('--apply',action='store_true');a=p.parse_args()
    print(json.dumps(inspect(Path(a.root),Path(a.original),a.build_id,a.old_patch,a.old_main,apply=a.apply)))


if __name__=='__main__':
    try:main()
    except (OSError,ValueError,KeyError,TypeError) as e:print('legacy cleanup failed: '+str(e),file=sys.stderr);sys.exit(1)
