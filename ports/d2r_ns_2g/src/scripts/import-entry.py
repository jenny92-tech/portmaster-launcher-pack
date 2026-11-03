#!/usr/bin/env python3
# INPUT:  显式指定的 C197 2G 正式入口和新的安装路径清单位置
# OUTPUT: 不含设备状态的 install-paths.json
# POS:    只解析已准备入口中的固定路径赋值，不执行来源脚本
import json
from pathlib import Path
import shlex
import subprocess
import sys


def extract(entry):
    entry = Path(entry)
    if entry.is_symlink() or not entry.is_file():
        raise ValueError('a regular prepared D2R entry is required')
    source = entry.read_text()
    if not all(token in source for token in ('D2R_CLASSIC30=1', 'D2R_NATIVE_HD_MASK=7',
                                             'DM_LINUX_CPU_POOL_TRIM=0', '--check')):
        raise ValueError('requires the prepared C197 classic 2G entry')
    subprocess.run(['/bin/bash', '-n', str(entry)], check=True)
    names = {'runtime': 'runtime', 'game': 'game', 'profile': 'profile', 'controllers': 'controllers',
             'patches': 'native', 'export D2R_OVERLAY_ROOT': 'overlay',
             'export D2R_PIPELINE_CACHE': 'cache'}
    paths = {}
    for line in source.splitlines():
        name, separator, value = line.partition('=')
        if separator and name in names:
            tokens = shlex.split(value)
            if (len(tokens) != 1 or not Path(tokens[0]).is_absolute() or
                    any(char in tokens[0] for char in ('$', '`', '\0', '\n', '\r'))):
                raise ValueError('entry must contain literal absolute installation paths: ' + name)
            if names[name] in paths:
                raise ValueError('ambiguous installation path: ' + name)
            paths[names[name]] = tokens[0]
    if set(paths) != set(names.values()):
        raise ValueError('prepared entry installation paths are incomplete')
    # The accepted C197 entry keeps these writable directories beside its cache.
    root = Path(paths['cache']).parent
    paths.update({key: str(root / name) for key, name in
                  [('state', 'visual-runs'), ('shader_misses', 'shader-misses'),
                   ('snapshot_cache', 'snapshot-cache'), ('launcher_logs', 'launcher')]})
    return paths


if __name__ == '__main__':
    try:
        data = extract(sys.argv[1])
        Path(sys.argv[2]).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit('D2R 2G import: ' + str(error))
