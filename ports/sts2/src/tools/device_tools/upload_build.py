#!/usr/bin/env python3
# INPUT: explicit ADB target, host build files and remote directory
# OUTPUT: resumable, per-chunk and final-SHA-verified immutable transfer
# POS: host-side build transfer; never activates game content
"""Upload a verified texture overlay in independently checked, resumable chunks.

No game configuration or activation is changed. The report must contain a
top-level output_sha256. ADB is invoked only after local validation succeeds.
"""
import argparse
import hashlib
import fcntl
import json
import re
import secrets
import os
import stat
import shlex
import subprocess
import sys
import time
from pathlib import Path

CHUNK_SIZE = 4 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def local_manifest(path, report):
    expected = json.loads(Path(report).read_text())['output_sha256']
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('report output_sha256 must be a lowercase SHA-256')
    whole = hashlib.sha256()
    chunks = []
    with Path(path).open('rb') as source:
        while data := source.read(CHUNK_SIZE):
            whole.update(data)
            chunks.append(digest(data))
    if not chunks or whole.hexdigest() != expected:
        raise ValueError('overlay is empty or does not match report output_sha256')
    return expected, chunks


class Adb:
    def __init__(self, target):
        self.target = target
        self.base = ['adb', '-s', target]

    def reconnect(self, attempt):
        time.sleep(2 ** attempt)
        for command_args in (['reconnect'], ['wait-for-device']):
            try:
                subprocess.run(self.base + command_args, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=30, check=False)
            except (subprocess.SubprocessError, OSError):
                pass

    def run(self, command, data=None, timeout=180):
        last = None
        for attempt in range(4):
            try:
                result = subprocess.run(self.base + ['shell', '-T', command], input=data,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        timeout=timeout, check=True)
                return result.stdout.decode('utf-8').strip()
            except (subprocess.SubprocessError, OSError) as exc:
                last = exc
                if attempt == 3:
                    break
                self.reconnect(attempt)
        raise RuntimeError(f'ADB operation failed after retries: {last}') from last


# Executed on the target with python3. Directory FDs and O_NOFOLLOW keep
# symlinked path components and files from redirecting reads or writes.
REMOTE = r"""
import ctypes, errno, hashlib, os, stat, sys
op, directory, name = sys.argv[1:4]
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
fd = os.open('/', flags)
for i, part in enumerate(directory.strip('/').split('/')):
    if i == len(directory.strip('/').split('/')) - 1:
        try: os.mkdir(part, 0o700, dir_fd=fd)
        except FileExistsError: pass
    nextfd = os.open(part, flags, dir_fd=fd)
    os.close(fd)
    fd = nextfd

def safe_open(name, flags):
    f = os.open(name, flags | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    st = os.fstat(f)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        os.close(f)
        raise RuntimeError('unsafe file: ' + name)
    return f

def file_hash(f, offset=None, length=None):
    h = hashlib.sha256()
    if offset is not None: os.lseek(f, offset, os.SEEK_SET)
    while length is None or length > 0:
        data = os.read(f, min(1024 * 1024, length) if length is not None else 1024 * 1024)
        if not data: break
        h.update(data)
        if length is not None: length -= len(data)
    return h.hexdigest()

def owned(f, token, dev, ino):
    st = os.fstat(f)
    if (st.st_dev, st.st_ino) != (int(dev), int(ino)):
        raise RuntimeError('partial inode does not match owner state')
    marker = safe_open(name + '.owner', os.O_RDONLY)
    try:
        if os.read(marker, 256) != token.encode():
            raise RuntimeError('partial owner token mismatch')
    finally: os.close(marker)
    return st

if op == 'hash':
    try: f = safe_open(name, os.O_RDONLY)
    except FileNotFoundError: print('MISSING')
    else:
        if len(sys.argv) > 4: print(file_hash(f, int(sys.argv[4]), int(sys.argv[5])))
        else: print(file_hash(f))
        os.close(f)
elif op == 'claim':
    token = sys.argv[4]
    f = safe_open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL)
    st = os.fstat(f)
    try:
        marker = safe_open(name + '.owner', os.O_WRONLY | os.O_CREAT | os.O_EXCL)
        try:
            if os.write(marker, token.encode()) != len(token): raise RuntimeError('short owner token write')
            os.fsync(marker)
        finally: os.close(marker)
        os.fsync(f)
        os.fsync(fd)
    finally: os.close(f)
    print(str(st.st_dev) + ':' + str(st.st_ino))
elif op == 'inspect':
    token, dev, ino = sys.argv[4:7]
    f = safe_open(name, os.O_RDONLY)
    st = owned(f, token, dev, ino)
    print(str(st.st_size) + ':' + file_hash(f))
    os.close(f)
elif op == 'write':
    offset, length, chunk_hash = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
    token, dev, ino = sys.argv[7:10]
    data = sys.stdin.buffer.read(length + 1)
    if len(data) != length or offset < 0 or length <= 0 or hashlib.sha256(data).hexdigest() != chunk_hash: raise RuntimeError('incorrect input length, offset or chunk hash')
    f = safe_open(name, os.O_RDWR)
    st = owned(f, token, dev, ino)
    if st.st_size != offset:
        raise RuntimeError('partial offset changed; refusing to write')
    # Match inode as well as pathname, including alternate mount paths.  Failure
    # to read any process metadata is a refusal, except for exited processes.
    proc = '/proc'
    for pid in os.listdir(proc):
        if not pid.isdigit() or int(pid) == os.getpid(): continue
        base = os.path.join(proc, pid)
        try:
            for entry in os.listdir(os.path.join(base, 'fd')):
                try: other = os.stat(os.path.join(base, 'fd', entry))
                except FileNotFoundError: continue
                if (other.st_dev, other.st_ino) == (st.st_dev, st.st_ino):
                    raise RuntimeError('partial is open by PID ' + pid)
            with open(os.path.join(base, 'maps')) as maps:
                for line in maps:
                    fields = line.split(None, 5)
                    if len(fields) < 5: raise RuntimeError('invalid process maps')
                    major, minor = (int(x, 16) for x in fields[3].split(':'))
                    if (major, minor, int(fields[4])) == (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino):
                        raise RuntimeError('partial is mapped by PID ' + pid)
        except FileNotFoundError:
            if os.path.exists(base): raise RuntimeError('cannot inspect live process ' + pid)
            continue
    current = os.stat(name, dir_fd=fd, follow_symlinks=False)
    after = os.fstat(f)
    if (current.st_dev, current.st_ino, current.st_nlink, after.st_size, after.st_mtime_ns) != (st.st_dev, st.st_ino, 1, st.st_size, st.st_mtime_ns):
        raise RuntimeError('partial changed before write')
    done = 0
    while done < length:
        n = os.pwrite(f, data[done:], offset + done)
        if n <= 0: raise RuntimeError('short write')
        done += n
    os.fsync(f)
    if file_hash(f, offset, length) != chunk_hash:
        raise RuntimeError('written chunk checksum mismatch')
    os.close(f)
elif op == 'finish':
    final, wanted, token, dev, ino = sys.argv[4:9]
    final_fd = safe_open(final, os.O_RDONLY)
    try:
        st = os.fstat(final_fd)
        if (st.st_dev, st.st_ino) != (int(dev), int(ino)) or file_hash(final_fd) != wanted:
            raise RuntimeError('published file does not match owner state')
    finally: os.close(final_fd)
    try: marker = safe_open(name + '.owner', os.O_RDONLY)
    except FileNotFoundError: marker = None
    if marker is not None:
        try:
            marker_st = os.fstat(marker)
            if os.read(marker, 256) != token.encode(): raise RuntimeError('owner token changed')
            current_marker = os.stat(name + '.owner', dir_fd=fd, follow_symlinks=False)
            if (marker_st.st_dev, marker_st.st_ino, current_marker.st_nlink) != (current_marker.st_dev, current_marker.st_ino, 1): raise RuntimeError('owner changed')
            os.unlink(name + '.owner', dir_fd=fd)
        finally: os.close(marker)
elif op == 'publish':
    final, wanted, token, dev, ino = sys.argv[4:9]
    f = safe_open(name, os.O_RDONLY)
    st = owned(f, token, dev, ino)
    if file_hash(f) != wanted: raise RuntimeError('partial checksum mismatch')
    current = os.stat(name, dir_fd=fd, follow_symlinks=False)
    if (st.st_dev, st.st_ino, current.st_nlink) != (current.st_dev, current.st_ino, 1):
        raise RuntimeError('partial changed before publish')
    marker = ('STS2_TEXTURE_UPLOAD_PENDING_V1:' + wanted).encode()
    libc = ctypes.CDLL(None, use_errno=True)
    if hasattr(libc, 'renameat2'):
        rename, no_replace = libc.renameat2, 1  # Linux RENAME_NOREPLACE
    elif hasattr(libc, 'renameatx_np'):
        rename, no_replace = libc.renameatx_np, 4  # macOS RENAME_EXCL (offline tests)
    else:
        rename, no_replace = None, 0
    if rename is None:
        ctypes.set_errno(errno.ENOSYS)
        result = -1
    else:
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = rename(fd, os.fsencode(name), fd, os.fsencode(final), no_replace)
    if result != 0:
        error = ctypes.get_errno()
        if error not in (errno.EEXIST, errno.EINVAL, errno.ENOSYS, errno.EOPNOTSUPP):
            raise OSError(error, os.strerror(error))
        # Filesystems lacking no-replace rename: reserve an identifiable final
        # entry exclusively, then atomically replace only our verified marker.
        try:
            reserved = os.open(final, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        except FileExistsError:
            reserved = None
        if reserved is not None:
            try:
                written = os.write(reserved, marker)
                if written != len(marker): raise RuntimeError('short reservation write')
                os.fsync(reserved)
            finally: os.close(reserved)
        reserved = safe_open(final, os.O_RDONLY)
        try:
            st_final = os.fstat(reserved)
            if os.read(reserved, len(marker) + 1) != marker:
                raise RuntimeError('final path is not a complete upload reservation; refusing to overwrite')
            current_final = os.stat(final, dir_fd=fd, follow_symlinks=False)
            if (st_final.st_dev, st_final.st_ino, current_final.st_nlink) != (current_final.st_dev, current_final.st_ino, 1):
                raise RuntimeError('reservation changed before publish')
            os.replace(name, final, src_dir_fd=fd, dst_dir_fd=fd)
        finally: os.close(reserved)
    os.close(f)
    owner = safe_open(name + '.owner', os.O_RDONLY)
    try:
        owner_st = os.fstat(owner)
        if os.read(owner, 256) != token.encode(): raise RuntimeError('owner token changed')
        current_owner = os.stat(name + '.owner', dir_fd=fd, follow_symlinks=False)
        if (owner_st.st_dev, owner_st.st_ino, current_owner.st_nlink) != (current_owner.st_dev, current_owner.st_ino, 1): raise RuntimeError('owner changed')
        os.unlink(name + '.owner', dir_fd=fd)
    finally: os.close(owner)
else: raise RuntimeError('unknown operation')
os.close(fd)
"""


def remote(adb, directory, op, name, *args, data=None):
    command = shlex.join(['python3', '-c', REMOTE, op, directory, name, *map(str, args)])
    return adb.run(command, data)


def remote_hash(adb, directory, name, index=None):
    args = () if index is None else (index * CHUNK_SIZE, CHUNK_SIZE)
    result = remote(adb, directory, 'hash', name, *args)
    if result == 'MISSING':
        return None
    if not re.fullmatch(r'[0-9a-f]{64}', result):
        raise RuntimeError('invalid remote SHA-256 response')
    return result


def owner_identity(adb, directory, partial, expected, state_dir):
    identity = {'target': adb.target, 'directory': directory, 'partial': partial, 'sha256': expected}
    return identity, Path(state_dir) / (digest(json.dumps(identity, sort_keys=True).encode()) + '.json')


def finish_transfer(adb, directory, partial, final, expected, state_dir):
    """Mark a published, identity-verified partial complete; tolerate absent state."""
    identity, state_path = owner_identity(adb, directory, partial, expected, state_dir)
    try:
        state_fd = os.open(state_path, os.O_RDWR | os.O_NOFOLLOW)
    except FileNotFoundError:
        return
    with os.fdopen(state_fd, 'r+b') as state_file:
        fcntl.flock(state_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        info = os.fstat(state_file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('unsafe upload state')
        state = json.load(state_file)
        if any(state.get(k) != v for k, v in identity.items()):
            raise ValueError('incompatible upload state')
        if state.get('status') == 'complete': return
        if state.get('status') != 'owned':
            raise ValueError('incomplete upload state; refusing finalization')
        token, dev, ino = state['token'], state['dev'], state['ino']
        remote(adb, directory, 'finish', partial, final, expected, token, dev, ino)
        state['status'] = 'complete'
        state_file.seek(0); state_file.truncate()
        state_file.write(json.dumps(state).encode())
        state_file.flush(); os.fsync(state_file.fileno())


def transfer_partial(adb, directory, partial, path, expected, state_dir):
    """Resume only a partial whose token and inode match durable host state."""
    if not re.fullmatch(r'[0-9a-f]{64}', expected) or expected not in partial or '/' in partial:
        raise ValueError('partial name must include the source SHA-256')
    path = Path(path)
    whole = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(CHUNK_SIZE), b''):
            whole.update(block)
    if whole.hexdigest() != expected:
        raise ValueError('source does not match expected SHA-256')
    identity, state_path = owner_identity(adb, directory, partial, expected, state_dir)
    try:
        state_fd = os.open(state_path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        created = True
    except FileExistsError:
        state_fd = os.open(state_path, os.O_RDWR | os.O_NOFOLLOW)
        created = False
    with os.fdopen(state_fd, 'r+b') as state_file:
        fcntl.flock(state_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state_stat = os.fstat(state_file.fileno())
        if not stat.S_ISREG(state_stat.st_mode) or state_stat.st_nlink != 1:
            raise ValueError('unsafe upload state')
        if not created:
            state = json.load(state_file)
            if any(state.get(k) != v for k, v in identity.items()):
                raise ValueError('incompatible upload state')
            if state.get('status') == 'complete':
                created = True
            elif state.get('status') != 'owned':
                raise ValueError('upload state is incomplete; refusing resume')
        if created:
            state = {**identity, 'token': secrets.token_hex(32), 'status': 'pending'}
            state_file.seek(0); state_file.truncate()
            state_file.write(json.dumps(state).encode())
            state_file.flush(); os.fsync(state_file.fileno())
            directory_fd = os.open(state_path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
            result = remote(adb, directory, 'claim', partial, state['token'])
            match = re.fullmatch(r'([0-9]+):([0-9]+)', result)
            if not match: raise RuntimeError('invalid remote claim response')
            state.update(status='owned', dev=int(match.group(1)), ino=int(match.group(2)))
            state_file.seek(0); state_file.truncate()
            state_file.write(json.dumps(state).encode())
            state_file.flush(); os.fsync(state_file.fileno())
        token, dev, ino = state['token'], state['dev'], state['ino']
        if not isinstance(token, str) or not re.fullmatch(r'[0-9a-f]{64}', token) or not isinstance(dev, int) or not isinstance(ino, int):
            raise ValueError('invalid upload owner state')
        result = remote(adb, directory, 'inspect', partial, token, dev, ino)
        match = re.fullmatch(r'(0|[1-9][0-9]*):([0-9a-f]{64})', result)
        if not match: raise RuntimeError('invalid remote partial response')
        offset, actual = int(match.group(1)), match.group(2)
        prefix = hashlib.sha256()
        with path.open('rb') as source:
            remaining = offset
            while remaining:
                block = source.read(min(CHUNK_SIZE, remaining))
                if not block: raise RuntimeError('partial exceeds source; refusing to write')
                prefix.update(block)
                remaining -= len(block)
            if prefix.hexdigest() != actual:
                raise RuntimeError('partial does not match source prefix; refusing to write')
            while data := source.read(CHUNK_SIZE):
                chunk_hash = digest(data)
                try:
                    remote(adb, directory, 'write', partial, offset, len(data), chunk_hash, token, dev, ino, data=data)
                except RuntimeError:
                    # A lost response can follow a successful write. Recheck the
                    # entire prefix once before deciding whether to continue.
                    check = remote(adb, directory, 'inspect', partial, token, dev, ino)
                    match = re.fullmatch(r'(0|[1-9][0-9]*):([0-9a-f]{64})', check)
                    updated = prefix.copy(); updated.update(data)
                    if not match or int(match.group(1)) != offset + len(data) or match.group(2) != updated.hexdigest():
                        raise
                prefix.update(data)
                offset += len(data)
        if prefix.hexdigest() != expected:
            raise RuntimeError('source changed during upload')
    return token, dev, ino


def upload(adb, overlay, report, directory, state_dir):
    if not directory.startswith('/') or any(p in ('', '.', '..') for p in directory[1:].split('/')):
        raise ValueError('remote directory must be an absolute normalized path')
    expected, _ = local_manifest(overlay, report)
    final, partial = expected + '.pck', expected + '.partial'
    existing = remote_hash(adb, directory, final)
    marker_hash = digest(('STS2_TEXTURE_UPLOAD_PENDING_V1:' + expected).encode())
    if existing == expected:
        finish_transfer(adb, directory, partial, final, expected, state_dir)
        return f'{directory}/{final}'
    if existing is not None and existing != marker_hash:
        raise RuntimeError('existing final file has an unexpected hash; refusing to overwrite')
    owner = transfer_partial(adb, directory, partial, overlay, expected, state_dir)
    if remote_hash(adb, directory, partial) != expected:
        raise RuntimeError('complete remote partial failed SHA-256 verification')
    remote(adb, directory, 'publish', partial, final, expected, *owner)
    if remote_hash(adb, directory, final) != expected:
        raise RuntimeError('final file was not installed with the expected hash')
    finish_transfer(adb, directory, partial, final, expected, state_dir)
    return f'{directory}/{final}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True, help='ADB device serial')
    parser.add_argument('--report', required=True, help='build report JSON')
    parser.add_argument('--remote-dir', required=True, help='absolute target directory')
    parser.add_argument('--state-dir', required=True, help='existing host directory for durable upload ownership state')
    parser.add_argument('--overlay', required=True, help='host overlay PCK')
    args = parser.parse_args()
    try:
        print(upload(Adb(args.target), args.overlay, args.report, args.remote_dir, args.state_dir))
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        print(f'upload failed: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
