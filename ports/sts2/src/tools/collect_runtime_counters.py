#!/usr/bin/env python3
# INPUT: explicit STS2 device/PID/starttime, trusted dotnet SDK and signed counters package
# OUTPUT: bounded System.Runtime aggregate counters in a new private JSON file
# POS: read-only EventPipe observation; no heap dump, object enumeration or game restart
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile
import zipfile

PACKAGE_SHA256 = 'b14f82342f2e60f8ca034f3c0bb590ad33e9b93306c4cfe77541ffc778f5810f'
PACKAGE_NAME = 'dotnet-counters.9.0.661903.nupkg'
TOOL_PREFIX = 'tools/net8.0/any/'
NAMES = {'Working Set (MB)', 'GC Heap Size (MB)', 'GC Committed Bytes (MB)',
         'LOH Size (B)', 'Allocation Rate (B / 1 sec)', 'Gen 2 GC Count (Count / 1 sec)'}
PROVIDER = r'EventCounters\System.Runtime[gc-heap-size,gc-committed,loh-size,alloc-rate,gen-2-gc-count,working-set]'


def checked_tool(directory):
    ds = directory.stat()
    if not stat.S_ISDIR(ds.st_mode) or ds.st_uid != os.geteuid() or ds.st_mode & 0o077:
        raise ValueError('tool directory must be private and owned by the caller')
    package = directory / PACKAGE_NAME
    if hashlib.sha256(package.read_bytes()).hexdigest() != PACKAGE_SHA256:
        raise ValueError('unexpected signed package SHA-256')
    tool = directory / 'tool'
    tool.mkdir(mode=0o700, exist_ok=True)
    if tool.is_symlink() or not tool.is_dir():
        raise ValueError('unsafe tool directory')
    expected = set()
    with zipfile.ZipFile(package) as archive:
        for info in archive.infolist():
            if not info.filename.startswith(TOOL_PREFIX) or info.is_dir():
                continue
            relative = Path(info.filename[len(TOOL_PREFIX):])
            if relative.is_absolute() or '..' in relative.parts or stat.S_ISLNK(info.external_attr >> 16):
                raise ValueError('unsafe package member')
            if relative in expected:
                raise ValueError('duplicate package member')
            expected.add(relative)
            path = tool / relative
            parent = tool
            for part in relative.parts[:-1]:
                parent = parent / part
                parent.mkdir(mode=0o700, exist_ok=True)
                if parent.is_symlink() or not parent.is_dir():
                    raise ValueError('unsafe tool subdirectory')
            content = archive.read(info)
            if not os.path.lexists(path):
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(content)
            if not stat.S_ISREG(path.lstat().st_mode) or hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(content).digest():
                raise ValueError('tool file differs from signed package')
    actual = set()
    for path in tool.rglob('*'):
        if path.is_symlink():
            raise ValueError('unsafe tool symlink')
        if path.is_file():
            actual.add(path.relative_to(tool))
    if actual != expected:
        raise ValueError('unexpected extracted tool file')
    return tool / 'dotnet-counters.dll'


def device_identity(adb, pid, starttime):
    code = """import os,sys
p=int(sys.argv[1]); wanted=sys.argv[2]
stat=open('/proc/%d/stat'%p).read().rsplit(')',1)[1].split()[19]
args=open('/proc/%d/cmdline'%p,'rb').read().split(b'\\0')
exe=os.readlink('/proc/%d/exe'%p)
assert stat==wanted and args[0]==b'unityloader' and exe.endswith('/game/godot.mono')
assert any(b'/sts2-vk-test/builds/' in a and a.endswith(b'/main.pck') for a in args)
"""
    subprocess.run(adb + ['shell', '-T', shlex.join(['python3', '-c', code, str(pid), starttime])],
                   check=True, stdout=subprocess.DEVNULL, timeout=15)


def collect(args):
    if not re.fullmatch(r'[0-9]+', args.starttime) or args.pid <= 0 or not 15 <= args.seconds <= 30:
        raise ValueError('invalid PID, starttime or 15–30 second duration')
    tool = checked_tool(Path(args.tool_dir).resolve())
    output = Path(args.output)
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise ValueError('output must be a new absolute path')
    adb = ['adb', '-s', args.target]
    device_identity(adb, args.pid, args.starttime)
    remote = f'localfilesystem:/tmp/dotnet-diagnostic-{args.pid}-{args.starttime}-socket'
    with tempfile.TemporaryDirectory(prefix='sts2-counters-', dir='/tmp') as td:
        local = str(Path(td) / 'runtime.sock')
        forward = 'localfilesystem:' + local
        raw = Path(td) / 'counters.json'
        try:
            subprocess.run(adb + ['forward', '--no-rebind', forward, remote],
                           check=True, stdout=subprocess.DEVNULL, timeout=15)
            if not stat.S_ISSOCK(os.lstat(local).st_mode):
                raise ValueError('ADB did not create the expected Unix socket')
            os.chmod(local, 0o600)
            cmd = ['env', 'DOTNET_ROLL_FORWARD=Major', str(Path(args.dotnet).resolve()), str(tool),
                   'collect', '--diagnostic-port', local + ',connect', '--counters', PROVIDER,
                   '--refresh-interval', '1', '--duration', f'00:00:{args.seconds:02d}',
                   '--resume-runtime:false', '--format', 'json', '--output', str(raw)]
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, timeout=args.seconds + 45)
            device_identity(adb, args.pid, args.starttime)
            data = json.loads(raw.read_text())
            events = [{'timestamp': e['timestamp'], 'name': e['name'], 'value': e['value']}
                      for e in data['Events'] if e.get('provider') == 'System.Runtime' and e.get('name') in NAMES]
            if not events or not any(e['name'] == 'GC Heap Size (MB)' for e in events):
                raise ValueError('requested runtime counters missing')
            report = {'pid': args.pid, 'starttime_ticks': args.starttime,
                      'package_sha256': PACKAGE_SHA256, 'duration_seconds': args.seconds,
                      'events': events, 'notes': 'Aggregate counters only; no forced GC or heap/object dump.'}
            fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as stream:
                json.dump(report, stream, indent=2)
                stream.write('\n')
        finally:
            removed = subprocess.run(adb + ['forward', '--remove', forward],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
            if removed.returncode:
                raise RuntimeError('ADB forward cleanup failed; inspect adb forward --list')
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('target', 'starttime', 'dotnet', 'tool-dir', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--seconds', type=int, default=15)
    collect(parser.parse_args())


if __name__ == '__main__':
    main()
