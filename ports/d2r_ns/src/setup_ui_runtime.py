#!/usr/bin/env python3
# INPUT:  已安装的 PortMaster LÖVE、输入程序与独立可执行缓存目录
# OUTPUT: 校验后的 LÖVE/输入程序副本，供 noexec 资源盘上的启动器使用
# POS:    D2R NS 的 UI 执行环境准备，不修改 PortMaster 或其他游戏运行时
import fcntl
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def install(love_root, input_binary, cache_root):
    love_root, input_binary, cache_root = map(Path, (love_root, input_binary, cache_root))
    sources = {'love/love.aarch64': love_root / 'love.aarch64',
               'gptokeyb': input_binary}
    libraries = love_root / 'libs.aarch64'
    if not libraries.is_dir():
        raise ValueError('PortMaster LÖVE libraries are missing')
    for path in sorted(libraries.rglob('*')):
        if path.is_file():
            if libraries.resolve() not in path.resolve().parents:
                raise ValueError('PortMaster LÖVE library escapes its runtime')
            sources['love/libs.aarch64/' + path.relative_to(libraries).as_posix()] = path
    files = {}
    for name, source in sources.items():
        if not source.is_file():
            raise ValueError('PortMaster UI executable is missing: ' + name)
        files[name] = {'bytes': source.stat().st_size, 'sha256': sha256(source)}
    identity = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    if cache_root.is_symlink():
        raise ValueError('linked UI cache directory is not supported')
    cache_root.mkdir(parents=True, exist_ok=True)
    target = cache_root / ('ui-' + identity[:16])
    with (cache_root / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not target.exists():
            staging = Path(tempfile.mkdtemp(prefix='.install-', dir=cache_root))
            for name, source in sources.items():
                destination = staging / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                destination.chmod(0o755 if name in ('gptokeyb', 'love/love.aarch64') else 0o644)
            for name, info in files.items():
                if sha256(staging / name) != info['sha256']:
                    raise ValueError('PortMaster UI copy checksum mismatch')
            (staging / '.complete').write_text(identity + '\n')
            staging.rename(target)
        if target.is_symlink() or (target / '.complete').read_text().strip() != identity:
            raise ValueError('invalid installed UI runtime')
        for name, info in files.items():
            path = target / name
            if path.is_symlink() or path.stat().st_size != info['bytes'] or sha256(path) != info['sha256']:
                raise ValueError('installed UI runtime checksum mismatch: ' + name)
    return target


if __name__ == '__main__':
    try:
        print(install(*sys.argv[1:4]))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('D2R NS UI: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
