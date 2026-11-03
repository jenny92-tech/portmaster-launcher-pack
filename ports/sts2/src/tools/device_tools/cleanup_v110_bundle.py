#!/usr/bin/env python3
# INPUT: explicitly selected new build, previous build and live process metadata
# OUTPUT: dry-run inventory or removal of one verified unused previous bundle
# POS: device-side cleanup; retain active build, original game and all saves
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from cleanup_v110_legacy import directory, read, digest, snapshot, reject_protected_aliases


def verify_bundle(root, identity):
    bundle=root/'builds'/identity;directory(bundle);directory(bundle/'data');directory(bundle/'patch')
    raw=read(bundle/'manifest.json')
    if hashlib.sha256(raw).hexdigest()!=identity:raise ValueError('bundle manifest mismatch')
    m=json.loads(raw);praw=read(bundle/'patch/manifest.json');p=json.loads(praw)
    if hashlib.sha256(praw).hexdigest()!=m['patch_sha256'] or set(p['files'])!={'sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck'} or set(p['source_files'])!={'sts2.dll','sts2.deps.json'}:raise ValueError('invalid patch identity')
    expected={'data','patch','manifest.json','main.pck','main.stat.json','entry.sh','release_info.json'}
    if 'engine_sha256' in m:expected.add('engine.bin')
    if set(os.listdir(bundle))!=expected or set(os.listdir(bundle/'data'))!=set(m['game_files']) or set(os.listdir(bundle/'patch'))!=set(p['files'])|{'manifest.json'}:raise ValueError('unexpected bundle contents')
    paths=[bundle/'manifest.json',bundle/'main.pck',bundle/'main.stat.json',bundle/'entry.sh',bundle/'release_info.json',bundle/'patch/manifest.json']
    if 'engine_sha256' in m:
        if not re.fullmatch('[0-9a-f]{64}',m['engine_sha256']) or digest(bundle/'engine.bin')!=m['engine_sha256']:raise ValueError('engine identity mismatch')
        paths.append(bundle/'engine.bin')
    for folder,files in ((bundle/'data',m['game_files']),(bundle/'patch',p['files'])):
        for name,expected in files.items():
            if '/' in name or name in ('','.','..') or digest(folder/name)!=expected:raise ValueError('bundle payload mismatch: '+name)
            paths.append(folder/name)
    if any(m['game_files'].get(n)!=h for n,h in p['source_files'].items()):raise ValueError('mixed game and patch')
    if digest(bundle/'entry.sh')!=m['entry_sha256'] or digest(bundle/'release_info.json')!=m['release_sha256']:raise ValueError('entry/release mismatch')
    main=bundle/'main.pck';s=snapshot(main);side=json.loads(read(bundle/'main.stat.json'))
    if digest(main)!=m['main_sha256'] or snapshot(main)!=s or side!={'build_sha256':identity,'main_sha256':m['main_sha256'],'size':s[2],'mtime_ns':s[3]}:raise ValueError('main pack mismatch')
    return m,paths,s


def clean(root,original,newid,oldid,proc=Path('/proc'),apply=False):
    if not all(re.fullmatch('[0-9a-f]{64}',v) for v in (newid,oldid)) or newid==oldid:raise ValueError('invalid build identities')
    for p in (root,original,root/'builds'):directory(p)
    if read(root/'active-build').decode().strip()!=newid:raise ValueError('active selector changed')
    new,protected,newstat=verify_bundle(root,newid);old,targets,_=verify_bundle(root,oldid)
    entry=root.parent/'Je-杀戮尖塔2-VK测试.sh';source=original/'gamedata/pcks/SlayTheSpire2.pck'
    if digest(entry)!=new['entry_sha256']:raise ValueError('active entry mismatch')
    protected.extend([entry,source,root/'active-build'])
    for name,expected in new['runtime_binding'].items():
        path=original/'data_sts2_linuxbsd_arm64'/name
        if digest(path)!=expected:raise ValueError('runtime source mismatch')
        protected.append(path)
    for folder,files in ((original/'data_sts2_linuxbsd_arm64',new['baseline_files']),(original,new['extension_files'])):
        for name,expected in files.items():
            path=folder/name;directory(path.parent);s=snapshot(path)
            if {'size':s[2],'mtime_ns':s[3]}!={k:expected[k] for k in ('size','mtime_ns')} or digest(path)!=expected['sha256']:raise ValueError('runtime changed: '+name)
            protected.append(path)
    for name in ('sts2.dll','sts2.deps.json','sts2_compat.dll'):
        path=original/'data_sts2_linuxbsd_arm64'/name
        if os.path.lexists(path):directory(path.parent);protected.append(path)
    reject_protected_aliases(targets,protected)
    identities={snapshot(p)[:2] for p in targets}
    for process in proc.iterdir():
        if not process.name.isdigit():continue
        try:
            for handle in (process/'fd').iterdir():
                try:s=handle.stat()
                except FileNotFoundError:continue
                if (s.st_dev,s.st_ino) in identities:raise ValueError('old bundle open by PID '+process.name)
            with (process/'maps').open() as maps:
                for line in maps:
                    fields=line.split(None,5)
                    if len(fields)<5:raise ValueError('invalid process maps')
                    major,minor=(int(x,16) for x in fields[3].split(':'))
                    if any((os.major(dev),os.minor(dev),ino)==(major,minor,int(fields[4])) for dev,ino in identities):raise ValueError('old bundle mapped by PID '+process.name)
        except FileNotFoundError:
            if process.exists():raise
    snapshots={p:snapshot(p) for p in targets};active=root/'builds'/newid/'main.pck'
    if read(root/'active-build').decode().strip()!=newid or snapshot(active)!=newstat:raise ValueError('active build changed')
    total=sum(s[2] for s in snapshots.values())
    if apply:
        for path in targets:
            if snapshot(path)!=snapshots[path] or read(root/'active-build').decode().strip()!=newid:raise ValueError('selection or old file changed')
            path.unlink()
        bundle=root/'builds'/oldid;(bundle/'data').rmdir();(bundle/'patch').rmdir();bundle.rmdir()
    return {'active_build':newid,'old_build':oldid,'files':len(targets),'bytes':total,'dry_run':not apply}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('root','original','new-build','old-build'):p.add_argument('--'+name,required=True)
    p.add_argument('--apply',action='store_true');a=p.parse_args()
    print(json.dumps(clean(Path(a.root),Path(a.original),a.new_build,a.old_build,apply=a.apply)))


if __name__=='__main__':
    try:main()
    except (OSError,ValueError,KeyError,TypeError) as e:print('old bundle cleanup failed: '+str(e),file=sys.stderr);sys.exit(1)
