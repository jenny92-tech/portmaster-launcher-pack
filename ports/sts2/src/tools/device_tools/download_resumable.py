#!/usr/bin/env python3
# INPUT: explicit ADB target, remote source, expected size, local destination and report
# OUTPUT: verified resumable local copy and SHA-256 report
# POS: host-side device transfer; never activates game content
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import time

CHUNK_SIZE = 4 * 1024 * 1024
REMOTE = r'''import hashlib,json,os,stat,sys
path,offset,length=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
f=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
s=os.fstat(f)
if not stat.S_ISREG(s.st_mode): raise RuntimeError('source is not a regular file')
data=os.pread(f,length,offset)
a=os.fstat(f)
def meta(x): return [x.st_size,x.st_mtime_ns,x.st_ino,x.st_dev]
if meta(s)!=meta(a): raise RuntimeError('source changed while reading')
os.close(f)
sys.stdout.buffer.write((json.dumps({'stat':meta(s),'size':len(data),'sha256':hashlib.sha256(data).hexdigest()})+'\n').encode()+data)
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def store(path, value):
    fd, temp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


class Adb:
    def __init__(self, target):
        self.target = target

    def chunk(self, source, offset, length):
        command = shlex.join(['python3', '-c', REMOTE, source, str(offset), str(length)])
        p = subprocess.run(['adb', '-s', self.target, 'shell', '-T', command], capture_output=True, timeout=180, check=True)
        header, sep, data = p.stdout.partition(b'\n')
        if not sep:
            raise ValueError('missing chunk metadata')
        meta = json.loads(header)
        if len(data) != length or meta['size'] != length or sha(data) != meta['sha256']:
            raise ValueError('chunk length/hash mismatch')
        return meta, data


def download(adb, source, total, destination, report):
    dest, report = Path(destination), Path(report)
    partial = dest.with_name(dest.name + '.partial')
    state_path = dest.with_name(dest.name + '.state.json')
    if not source.startswith('/') or total <= 0:
        raise ValueError('source must be absolute and size must be positive')
    if len({dest.absolute(), report.absolute(), partial.absolute(), state_path.absolute()}) != 4:
        raise ValueError('destination, report and state paths must be distinct')
    if dest.exists() or dest.is_symlink() or report.exists() or report.is_symlink():
        raise ValueError('destination or report exists; refusing to overwrite')
    if state_path.is_symlink() or partial.is_symlink():
        raise ValueError('unsafe partial or state')
    if state_path.exists():
        state = json.loads(state_path.read_text())
        if (state['target'], state['source'], state['total'], state['chunk_size']) != (adb.target, source, total, CHUNK_SIZE):
            raise ValueError('incompatible state')
    else:
        if partial.exists():
            raise ValueError('partial without state')
        state = {'target': adb.target, 'source': source, 'total': total, 'chunk_size': CHUNK_SIZE, 'source_stat': None, 'chunks': []}
        store(state_path, state)
    committed = 0
    for chunk in state['chunks']:
        n = chunk['length']
        if n != min(CHUNK_SIZE, total - committed) or n <= 0:
            raise ValueError('invalid saved chunk length')
        committed += n
    if committed and not partial.exists():
        raise ValueError('missing partial file')
    partial_fd = os.open(partial, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    info = os.fstat(partial_fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        os.close(partial_fd)
        raise ValueError('unsafe partial file')
    with os.fdopen(partial_fd, 'r+b') as f:
        f.seek(0, 2)
        if f.tell() < committed:
            raise ValueError('partial shorter than committed state')
        f.truncate(committed)
        f.seek(0)
        for chunk in state['chunks']:
            if sha(f.read(chunk['length'])) != chunk['sha256']:
                raise ValueError('saved chunk mismatch')
        while committed < total:
            n = min(CHUNK_SIZE, total - committed)
            for attempt in range(3):
                try:
                    meta, data = adb.chunk(source, committed, n)
                    break
                except (OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
                    if attempt == 2:
                        raise RuntimeError('download paused after three failed attempts') from exc
                    time.sleep(attempt + 1)
            if len(data) != n or meta['size'] != n or sha(data) != meta['sha256']:
                raise ValueError('chunk length/hash mismatch')
            if len(meta['stat']) != 4 or meta['stat'][0] != total:
                raise ValueError('unexpected source metadata')
            if state['source_stat'] is not None and state['source_stat'] != meta['stat']:
                raise ValueError('source metadata changed; refusing resume')
            state['source_stat'] = meta['stat']
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
            state['chunks'].append({'length': n, 'sha256': meta['sha256']})
            store(state_path, state)
            committed += n
    h = hashlib.sha256()
    with partial.open('rb') as f:
        for block in iter(lambda: f.read(CHUNK_SIZE), b''):
            h.update(block)
    # Hard-link publication refuses an existing destination atomically.
    report_data = {'target': adb.target, 'source': source, 'source_stat': state['source_stat'], 'size': total, 'sha256': h.hexdigest()}
    with report.open('x') as f:
        json.dump(report_data, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    try:
        os.link(partial, dest)
    except OSError:
        report.unlink()
        raise
    partial.unlink()
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--target', required=True)
    p.add_argument('--source', required=True)
    p.add_argument('--size', type=int, required=True)
    p.add_argument('--destination', required=True)
    p.add_argument('--report', required=True)
    a = p.parse_args()
    try:
        print(download(Adb(a.target), a.source, a.size, a.destination, a.report))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f'download failed: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
