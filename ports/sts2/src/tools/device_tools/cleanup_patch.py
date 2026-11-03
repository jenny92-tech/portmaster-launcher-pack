#!/usr/bin/env python3
# INPUT: explicit experiment root, old and active patch identities, process filesystem
# OUTPUT: dry-run inventory or removal of one verified inactive patch
# POS: device-side maintenance; no network or device connection
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

FILES = {'sts2.dll', 'sts2_compat.dll', 'sts2.deps.json', 'port_compat.pck', 'manifest.json'}
FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def open_dir(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('root must be an absolute normalized path')
    fd = os.open('/', FLAGS)
    try:
        for part in path.parts[1:]:
            next_fd = os.open(part, FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_file(directory, name):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
            raise ValueError('unsafe file: ' + name)
        with os.fdopen(fd, 'rb', closefd=False) as f:
            data = f.read()
        return data
    finally:
        os.close(fd)


def verify_patch(fd, identity):
    if set(os.listdir(fd)) != FILES:
        raise ValueError('unexpected patch contents')
    manifest_bytes = read_file(fd, 'manifest.json')
    if hashlib.sha256(manifest_bytes).hexdigest() != identity:
        raise ValueError('manifest identity mismatch')
    manifest = json.loads(manifest_bytes)
    if set(manifest['files']) != FILES - {'manifest.json'}:
        raise ValueError('manifest payload shape mismatch')
    for name, expected in manifest['files'].items():
        if hashlib.sha256(read_file(fd, name)).hexdigest() != expected:
            raise ValueError('payload mismatch: ' + name)


def cleanup(root, old_id, active_id, proc='/proc', aliases=(), apply=False):
    if not all(re.fullmatch('[0-9a-f]{64}', x) for x in (old_id, active_id)) or old_id == active_id:
        raise ValueError('patch identities must be distinct lowercase SHA-256 values')
    rootfd = open_dir(root)
    patches = old = active = None
    try:
        patches = os.open('patches', FLAGS, dir_fd=rootfd)
        old = os.open(old_id, FLAGS, dir_fd=patches)
        active = os.open(active_id, FLAGS, dir_fd=patches)
        if read_file(rootfd, 'active-patch').decode().strip() != active_id:
            raise ValueError('active selector changed')
        verify_patch(old, old_id)
        verify_patch(active, active_id)
        prefixes = [str(Path(root) / 'patches' / old_id) + '/'] + [str(Path(p) / 'patches' / old_id) + '/' for p in aliases]
        for process in Path(proc).iterdir():
            if not process.name.isdigit():
                continue
            try:
                for handle in (process / 'fd').iterdir():
                    try:
                        target = os.readlink(handle)
                    except FileNotFoundError:
                        continue
                    if any(target.startswith(prefix) for prefix in prefixes):
                        raise ValueError('old patch open by PID ' + process.name)
                with (process / 'maps').open() as maps:
                    if any(any(prefix in line for prefix in prefixes) for line in maps):
                        raise ValueError('old patch mapped by PID ' + process.name)
            except FileNotFoundError:
                continue
        if read_file(rootfd, 'active-patch').decode().strip() != active_id:
            raise ValueError('active selector changed')
        result = {'patch': old_id, 'files': len(FILES), 'bytes': sum(os.stat(n, dir_fd=old, follow_symlinks=False).st_size for n in FILES), 'dry_run': not apply}
        if apply:
            # Refuse a directory replacement before unlinking the selected entries.
            before, current = os.fstat(old), os.stat(old_id, dir_fd=patches, follow_symlinks=False)
            if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
                raise ValueError('patch directory changed')
            for name in sorted(FILES):
                os.unlink(name, dir_fd=old)
            os.rmdir(old_id, dir_fd=patches)
        return result
    finally:
        for fd in (active, old, patches, rootfd):
            if fd is not None:
                os.close(fd)


def main():
    p = argparse.ArgumentParser(description='Inspect or remove one verified inactive patch; dry-run by default.')
    p.add_argument('--root', required=True)
    p.add_argument('--old-id', required=True)
    p.add_argument('--active-id', required=True)
    p.add_argument('--path-alias', action='append', default=[], help='additional device mount alias of root')
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    try:
        print(json.dumps(cleanup(a.root, a.old_id, a.active_id, aliases=a.path_alias, apply=a.apply)))
    except (OSError, ValueError, KeyError) as exc:
        print(f'cleanup failed: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
