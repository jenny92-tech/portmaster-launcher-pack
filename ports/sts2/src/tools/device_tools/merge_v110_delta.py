#!/usr/bin/env python3
# INPUT: explicitly bound old and new build manifests plus verified texture delta
# OUTPUT: new immutable main PCK prepared locally on the same filesystem
# POS: device-side helper; never activates the build or changes the old main
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

import merge_texture_pck as merge

FONT_BASE_SHA='a9c61d767c577ea066010af452f6e706ae2c0925f41b800b0bfe0c4d3f835daa'
FONT_DELTA_SHA='76412fc7494eb1c49189ebaf2b6add3d1f9b1d3ce407502b2993e6e683ddcedb'
FONT_MAIN_SHA='8a4d8a475bb7bcb7eb4b94c3691ca8564306c25a630516248e31eaed143c0996'
COMMON_DELTA_SHA='3280be91f4b8b2b8d8af56b4f82350fe9d6cdeb1411c319668e135aece4f3bfa'
COMMON_MAIN_SHA='3abccf4a75ea347b0d4cece05d376beeaf42b4f34a3af1ccc17644bd2762203d'
QUARTER_DELTA_SHA='49dc4dcb42e4fceb74e74d340e8bdfa5a0bec1c8d132fb1ee570d78521620c09'
QUARTER_MAIN_SHA='7ec4bb3f96fd01dc42bde20b6daa2f98cd16f09cec3b8ef404efd53f089615f1'
QUARTER_COUNT=776
REFINEMENT_DELTA_SHA='447f1186d5a86495d8b0b5276c95eb1b514413433220fd01bea29abf1939cf16'
REFINEMENT_MAIN_SHA='099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c'
REFINEMENT_COUNT=85


def directory(path):
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('directory must be absolute and normalized')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.parts[1:]:
            new = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = new
        return fd
    except BaseException:
        os.close(fd); raise


def read_file(fd, name):
    f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
    s = os.fstat(f)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
        os.close(f); raise ValueError('unsafe input: ' + name)
    with os.fdopen(f, 'rb') as stream:
        return stream.read()


def publish(srcfd, fd, source, final, wanted):
    marker = ('STS2_VRAM_MAIN_PENDING:' + wanted).encode()
    libc = ctypes.CDLL(None, use_errno=True)
    rename = getattr(libc, 'renameat2', None)
    if rename is not None:
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        if rename(srcfd, os.fsencode(source), fd, os.fsencode(final), 1) == 0:
            os.fsync(fd); return
        error = ctypes.get_errno()
        if error not in (errno.EEXIST, errno.EINVAL, errno.ENOSYS, errno.EOPNOTSUPP):
            raise OSError(error, os.strerror(error))
    try:
        reserved = os.open(final, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    except FileExistsError:
        pass
    else:
        try:
            if os.write(reserved, marker) != len(marker): raise ValueError('short reservation write')
            os.fsync(reserved)
        finally: os.close(reserved)
    if read_file(fd, final) != marker: raise ValueError('foreign main destination')
    os.replace(source, final, src_dir_fd=srcfd, dst_dir_fd=fd)
    os.fsync(fd)


def prepare(root, oldid, newid, oldmain, delta_sha, wanted, mode='texture'):
    if any(not re.fullmatch('[0-9a-f]{64}', s) for s in (oldid, newid, oldmain, delta_sha, wanted)):
        raise ValueError('invalid build identity')
    if mode not in ('texture','font','common-font','quarter','refinement'): raise ValueError('invalid merge mode')
    if mode=='font' and (oldmain,delta_sha,wanted)!=(FONT_BASE_SHA,FONT_DELTA_SHA,FONT_MAIN_SHA):
        raise ValueError('font merge is restricted to the audited identities')
    if mode=='common-font' and (oldmain,delta_sha,wanted)!=(FONT_MAIN_SHA,COMMON_DELTA_SHA,COMMON_MAIN_SHA):
        raise ValueError('common font merge is restricted to the audited identities')
    if mode=='quarter' and (oldmain,delta_sha,wanted)!=(COMMON_MAIN_SHA,QUARTER_DELTA_SHA,QUARTER_MAIN_SHA):
        raise ValueError('quarter merge is restricted to the audited identities')
    if mode=='refinement' and (oldmain,delta_sha,wanted)!=(QUARTER_MAIN_SHA,REFINEMENT_DELTA_SHA,REFINEMENT_MAIN_SHA):
        raise ValueError('refinement merge is restricted to the audited identities')
    root = Path(root)
    old = root / 'builds' / oldid; new = root / 'builds' / newid
    rfd, ofd, nfd = directory(root), directory(old), directory(new)
    try:
        lock = os.open('.vram-merge.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=nfd)
        try:
            ls = os.fstat(lock)
            if not stat.S_ISREG(ls.st_mode) or ls.st_nlink != 1: raise ValueError('unsafe merge lock')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if read_file(rfd, 'active-build').decode().strip() not in (oldid, newid):
                raise ValueError('active build changed')
            oldraw, newraw = read_file(ofd, 'manifest.json'), read_file(nfd, 'manifest.json')
            if hashlib.sha256(oldraw).hexdigest() != oldid or hashlib.sha256(newraw).hexdigest() != newid:
                raise ValueError('build manifest identity mismatch')
            om, nm = json.loads(oldraw), json.loads(newraw)
            if om['main_sha256'] != oldmain or nm['main_sha256'] != wanted:
                raise ValueError('build main identity mismatch')
            if om['source_pck_sha256'] != nm['source_pck_sha256']:
                raise ValueError('game source differs across builds')
            source, delta, adapter = old/'main.pck', new/'restore-delta.pck', new/'restore-adapter.json'
            for fd, name in ((ofd, 'main.pck'), (nfd, 'restore-delta.pck')):
                st = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1: raise ValueError('unsafe merge input: ' + name)
            ss = os.stat('main.pck', dir_fd=ofd, follow_symlinks=False); side = json.loads(read_file(ofd, 'main.stat.json'))
            if side != {'build_sha256': oldid, 'main_sha256': oldmain, 'size': ss.st_size, 'mtime_ns': ss.st_mtime_ns}:
                raise ValueError('old main sidecar mismatch')
            if merge.sha256_file(source) != oldmain or merge.sha256_file(delta) != delta_sha:
                raise ValueError('old main or delta checksum mismatch')
            data = json.loads(read_file(nfd, 'restore-adapter.json'))
            if data.get('source_sha256') != oldmain or data.get('output_sha256') != delta_sha:
                raise ValueError('delta adapter identity mismatch')
            if mode=='font' and {r.get('path') for r in data.get('resources',[])}!=set(merge.AUDITED_FONT_SOURCE_SHA256):
                raise ValueError('font adapter does not contain the audited targets')
            if mode=='common-font' and (len(data.get('resources',[])) != 6 or {r.get('path') for r in data['resources']} != set(merge.AUDITED_COMMON_FONT_SOURCE_SHA256)):
                raise ValueError('common font adapter does not contain the audited targets')
            if mode in ('quarter','refinement'):
                records=data.get('resources',[]);names=[r.get('path') for r in records]
                count=QUARTER_COUNT if mode=='quarter' else REFINEMENT_COUNT
                if len(names)!=count or len(set(names))!=count or any(not isinstance(n,str) or not n.startswith('.godot/imported/') or not n.endswith('.ctex') for n in names):
                    raise ValueError('quarter adapter does not contain the audited texture set')
            try:
                existing = os.stat('main.pck', dir_fd=nfd, follow_symlinks=False)
            except FileNotFoundError: existing = None
            if existing and existing.st_size != len(('STS2_VRAM_MAIN_PENDING:' + wanted).encode()):
                if not stat.S_ISREG(existing.st_mode) or existing.st_nlink != 1 or merge.sha256_file(new/'main.pck') != wanted:
                    raise ValueError('foreign main destination')
                return wanted
            # A failed prior attempt is left for explicit inspection rather than
            # claiming an unknown partial or consuming additional SD space.
            stage = new / 'restore-output'
            if stage.exists() or stage.is_symlink():
                fd = directory(stage)
                try:
                    names = set(os.listdir(fd))
                    if names != {wanted+'.pck', wanted+'.json'}:
                        raise ValueError('incomplete merge stage requires inspection')
                finally: os.close(fd)
                result = stage/(wanted+'.pck')
                st = os.lstat(result)
                if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1: raise ValueError('unsafe staged main')
                if merge.sha256_file(result) != wanted: raise ValueError('staged main checksum mismatch')
            else:
                result = merge.prepare(source, delta, adapter, stage,
                    approved_font_hashes=(merge.AUDITED_FONT_SOURCE_SHA256 if mode=='font' else merge.AUDITED_COMMON_FONT_SOURCE_SHA256 if mode=='common-font' else None))
                if result.name != wanted+'.pck': raise ValueError('device merge differs from reviewed main')
            stagefd = directory(stage)
            try:
                # Both directories are on the same SD filesystem. The rename is
                # no-replace or uses an exclusively-created identity marker.
                publish(stagefd, nfd, wanted+'.pck', 'main.pck', wanted)
            finally: os.close(stagefd)
            if merge.sha256_file(new/'main.pck') != wanted: raise ValueError('published main checksum mismatch')
            return wanted
        finally: os.close(lock)
    finally: os.close(rfd); os.close(ofd); os.close(nfd)


def cleanup(root, original, newid, delta_sha, adapter_sha, wanted, proc=Path('/proc')):
    if any(not re.fullmatch('[0-9a-f]{64}', s) for s in (newid, delta_sha, adapter_sha, wanted)):
        raise ValueError('invalid cleanup identity')
    root = Path(root); new = root/'builds'/newid
    rfd, nfd = directory(root), directory(new)
    lock = None; stagefd = None
    try:
        try: lock = os.open('.vram-merge.lock', os.O_RDWR | os.O_NOFOLLOW, dir_fd=nfd)
        except FileNotFoundError:
            if set(os.listdir(nfd)) & {'restore-delta.pck','restore-adapter.json','restore-output'}:
                raise ValueError('cleanup owner missing while intermediates remain')
            return 0
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if read_file(rfd, 'active-build').decode().strip() != newid:
            raise ValueError('cleanup requires the selected build')
        raw = read_file(nfd, 'manifest.json')
        manifest=json.loads(raw)
        if hashlib.sha256(raw).hexdigest() != newid or manifest['main_sha256'] != wanted:
            raise ValueError('cleanup build manifest mismatch')
        main = os.stat('main.pck', dir_fd=nfd, follow_symlinks=False)
        side = json.loads(read_file(nfd, 'main.stat.json'))
        if not stat.S_ISREG(main.st_mode) or main.st_nlink != 1 or side != {'build_sha256':newid,'main_sha256':wanted,'size':main.st_size,'mtime_ns':main.st_mtime_ns}:
            raise ValueError('selected main changed before cleanup')
        stage = new/'restore-output'
        if stage.exists() or stage.is_symlink():
            stagefd = directory(stage)
            if set(os.listdir(stagefd)) - {wanted+'.json'}: raise ValueError('unknown restore output remains')
        targets = []
        for name, expected in (('restore-delta.pck',delta_sha),('restore-adapter.json',adapter_sha)):
            try: s = os.stat(name,dir_fd=nfd,follow_symlinks=False)
            except FileNotFoundError: continue
            if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or merge.sha256_file(new/name) != expected:
                raise ValueError('restoration cleanup input changed: '+name)
            targets.append((nfd,name,s))
        if stagefd is not None and wanted+'.json' in os.listdir(stagefd):
            raw = read_file(stagefd,wanted+'.json');record=json.loads(raw)
            if record.get('overlay_sha256') != delta_sha or record.get('merged_sha256') != wanted:
                raise ValueError('restoration sidecar identity mismatch')
            targets.append((stagefd,wanted+'.json',os.stat(wanted+'.json',dir_fd=stagefd,follow_symlinks=False)))
        lockstat=os.fstat(lock)
        protected={(main.st_dev,main.st_ino)}
        for name in ('manifest.json','main.stat.json','entry.sh','release_info.json')+(('engine.bin',) if 'engine_sha256' in manifest else ()):
            st=os.stat(name,dir_fd=nfd,follow_symlinks=False);protected.add((st.st_dev,st.st_ino))
        for subdir in ('data','patch'):
            subfd=directory(new/subdir)
            try:
                for name in os.listdir(subfd):
                    st=os.stat(name,dir_fd=subfd,follow_symlinks=False);protected.add((st.st_dev,st.st_ino))
            finally: os.close(subfd)
        original=Path(original)
        protected_paths=[original/'gamedata/pcks/SlayTheSpire2.pck']
        protected_paths += [original/'data_sts2_linuxbsd_arm64'/n for n in set(manifest['runtime_binding'])|set(manifest['baseline_files'])]
        protected_paths += [original/n for n in manifest['extension_files']]
        for path in protected_paths:
            parentfd=directory(path.parent)
            try:
                st=os.stat(path.name,dir_fd=parentfd,follow_symlinks=False);protected.add((st.st_dev,st.st_ino))
            finally: os.close(parentfd)
        identities={(s.st_dev,s.st_ino) for _,_,s in targets} | {(lockstat.st_dev,lockstat.st_ino)}
        if identities & protected: raise ValueError('cleanup target aliases selected build')
        for process in proc.iterdir():
            if not process.name.isdigit() or int(process.name)==os.getpid(): continue
            try:
                for handle in (process/'fd').iterdir():
                    try: s=handle.stat()
                    except FileNotFoundError: continue
                    if (s.st_dev,s.st_ino) in identities: raise ValueError('cleanup target is open by PID '+process.name)
                with (process/'maps').open() as maps:
                    for line in maps:
                        fields=line.split(None,5)
                        if len(fields)<5: raise ValueError('invalid process maps')
                        major,minor=(int(x,16) for x in fields[3].split(':'))
                        if any((os.major(dev),os.minor(dev),ino)==(major,minor,int(fields[4])) for dev,ino in identities):
                            raise ValueError('cleanup target is mapped by PID '+process.name)
            except FileNotFoundError:
                if process.exists(): raise
        for fd,name,old in targets:
            cur=os.stat(name,dir_fd=fd,follow_symlinks=False)
            if (cur.st_dev,cur.st_ino,cur.st_size,cur.st_mtime_ns)!=(old.st_dev,old.st_ino,old.st_size,old.st_mtime_ns) or read_file(rfd,'active-build').decode().strip()!=newid:
                raise ValueError('cleanup target or selection changed')
            os.unlink(name,dir_fd=fd)
        if stagefd is not None:
            os.close(stagefd);stagefd=None
            os.rmdir('restore-output',dir_fd=nfd)
        os.fsync(nfd)
        current=os.stat('.vram-merge.lock',dir_fd=nfd,follow_symlinks=False)
        if (current.st_dev,current.st_ino)!=(lockstat.st_dev,lockstat.st_ino) or read_file(rfd,'active-build').decode().strip()!=newid:
            raise ValueError('cleanup lock or selection changed')
        os.unlink('.vram-merge.lock',dir_fd=nfd);os.fsync(nfd)
        return len(targets)+1
    finally:
        if stagefd is not None: os.close(stagefd)
        if lock is not None: os.close(lock)
        os.close(rfd);os.close(nfd)


if __name__ == '__main__':
    operation, *args = sys.argv[1:]
    print({'merge':prepare,'cleanup':cleanup}[operation](*args))
