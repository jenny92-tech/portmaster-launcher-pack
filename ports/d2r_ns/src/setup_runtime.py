#!/usr/bin/env python3
# INPUT:  包内执行文件清单、明确的可执行目录和独立游戏档案路径
# OUTPUT: 已校验私有 runtime 路径、缺失时创建的新默认设置
# POS:    在 noexec SD 上隔离安装 D2R NS 程序且保留已有存档
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import time


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def checked_files(manifest):
    files = manifest['files']
    required = {'runtime/d2r-linux-novideo', 'runtime/run-bringup.sh',
                'runtime/wayland-wsi/libVkLayer_window_system_integration.so',
                'runtime/wayland-wsi/VkLayer_window_system_integration.json',
                'native/main.patched.bin', 'native/sdk.patched.bin',
                'native/subsdk0.patched.bin', 'bin/portkit-launcher'}
    if not required <= files.keys():
        raise ValueError('D2R NS runtime files are incomplete')
    for name, info in files.items():
        path = PurePosixPath(name)
        if (path.is_absolute() or '..' in path.parts or str(path) != name or
                not name.startswith(('runtime/', 'native/', 'bin/')) or
                type(info['bytes']) is not int or info['bytes'] < 0 or
                len(info['sha256']) != 64 or info['mode'] not in (0o644, 0o755)):
            raise ValueError('invalid D2R NS runtime manifest')
    return files


def verify(root, files):
    resolved = root.resolve()
    for name, info in files.items():
        path = root / name
        if resolved not in path.resolve().parents:
            raise ValueError('D2R NS runtime path escapes its directory')
        if (path.is_symlink() or not path.is_file() or
                path.stat().st_size != info['bytes'] or sha256(path) != info['sha256']):
            raise ValueError('D2R NS runtime checksum mismatch: ' + name)


def install(bundle, runtime_root, profile):
    bundle, runtime_root, profile = (Path(p).expanduser().absolute() for p in
                                     (bundle, runtime_root, profile))
    raw = (bundle / 'runtime-files.json').read_bytes()
    files = checked_files(json.loads(raw))
    identity = hashlib.sha256(raw).hexdigest()
    if runtime_root.is_symlink():
        raise ValueError('linked D2R NS runtime directory is not supported')
    runtime_root.mkdir(parents=True, exist_ok=True)
    target = runtime_root / ('kit-' + identity[:16])
    with (runtime_root / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.exists():
            if target.is_symlink() or (target / '.complete').read_text().strip() != identity:
                raise ValueError('invalid D2R NS installed runtime')
            verify(target, files)
        else:
            verify(bundle, files)
            staging = Path(tempfile.mkdtemp(prefix='.install-', dir=runtime_root))
            for name, info in files.items():
                source, destination = bundle / name, staging / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                destination.chmod(info['mode'])
            verify(staging, files)
            (staging / '.complete').write_text(identity + '\n')
            staging.rename(target)
    profile.mkdir(parents=True, exist_ok=True)
    with (profile / 'session.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        settings = profile / 'save/Settings'
        settings.mkdir(parents=True, exist_ok=True)
        (profile / 'identity').mkdir(exist_ok=True)
        destination = settings / 'Settings.json'
        meta = settings / 'Settings.json.meta'
        if destination.is_symlink() or meta.is_symlink():
            raise ValueError('linked D2R NS settings are not supported')
        if not destination.exists():
            if meta.exists():
                raise ValueError('orphan D2R NS settings metadata; existing files preserved')
            defaults = json.loads((bundle / 'config/default-settings.json').read_text())
            if not defaults or any(type(v) is not int for v in defaults.values()):
                raise ValueError('invalid D2R NS default settings')
            pending = []
            try:
                for path, value in ((meta, {'last_modified_time': time.time_ns()}),
                                    (destination, defaults)):
                    descriptor, name = tempfile.mkstemp(prefix='.settings-', dir=settings)
                    temp = Path(name)
                    pending.append((temp, path))
                    with os.fdopen(descriptor, 'w') as stream:
                        stream.write(json.dumps(value, indent=2) + '\n')
                        stream.flush()
                        os.fsync(stream.fileno())
                for temp, path in pending:
                    temp.replace(path)
            except OSError:
                for temp, _ in pending:
                    temp.unlink(missing_ok=True)
                if not destination.exists():
                    meta.unlink(missing_ok=True)
                raise
    return target


if __name__ == '__main__':
    try:
        print(install(*sys.argv[1:4]))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('D2R NS: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
