#!/usr/bin/env python3
# INPUT:  已准备的 2G 入口或安装路径 JSON，以及输出位置
# OUTPUT: 不含设备状态的 install-paths.json
# POS:    只解析已准备入口中的固定路径赋值，不执行来源脚本
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from launch import load_paths


def extract(entry):
    entry = Path(entry)
    if entry.is_symlink() or not entry.is_file():
        raise ValueError('a regular prepared D2R entry is required')
    source = entry.read_text()
    if not all(token in source for token in ('D2R_CLASSIC30=1', 'D2R_NATIVE_HD_MASK=7',
                                             'DM_LINUX_CPU_POOL_TRIM=0', '--check')):
        raise ValueError('requires a prepared classic 2G entry')
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
    # Writable session directories share the prepared cache parent.
    root = Path(paths['cache']).parent
    paths.update({key: str(root / name) for key, name in
                  [('state', 'visual-runs'), ('shader_misses', 'shader-misses'),
                   ('snapshot_cache', 'snapshot-cache'), ('launcher_logs', 'launcher')]})
    return paths


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Import prepared D2R 2G installation paths.')
    parser.add_argument('--paths', action='store_true', help='read a validated installation JSON')
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        if args.source.is_symlink() or not args.source.is_file():
            raise ValueError('a regular prepared installation input is required')
        data = load_paths(args.source) if args.paths else extract(args.source)
        args.output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit('D2R 2G import: ' + str(error))
