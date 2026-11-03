#!/usr/bin/env python3
# INPUT:  EGL 适配 C 源码、明确的 ARM64 clang 与 ELF linker
# OUTPUT: Release loong-egl-compat.so 及源码/二进制构建身份
# POS:    可重复重建余烬灯塔的进程内 MiniLoong GLES 适配库
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

COMPAT = Path(__file__).resolve().parents[1] / 'compat'


def build():
    source = COMPAT / 'egl_client_extensions.c'
    cc = os.environ.get('EMBERWARD_CC', 'clang')
    linker = os.environ.get('EMBERWARD_LD', 'ld.lld')
    compile_args = ['--target=aarch64-linux-gnu', '-std=c11', '-O2', '-DNDEBUG',
                    '-fPIC', '-ffreestanding', '-fno-builtin', '-Wall', '-Wextra', '-Werror']
    link_args = ['-shared', '-soname', 'libEGL.so.1', '-z', 'relro', '-z', 'now',
                 '-z', 'noexecstack', '--strip-all']
    with tempfile.TemporaryDirectory(prefix='emberward-egl-') as temporary:
        obj = Path(temporary) / 'adapter.o'
        binary = Path(temporary) / 'adapter.so'
        subprocess.run([cc, *compile_args, '-c', str(source), '-o', str(obj)], check=True)
        subprocess.run([linker, *link_args, str(obj), '-o', str(binary)], check=True)
        data = binary.read_bytes()
        if data[:6] != b'\x7fELF\x02\x01' or int.from_bytes(data[18:20], 'little') != 183:
            raise ValueError('compatibility library must be an ARM64 Linux ELF')
        (COMPAT / 'loong-egl-compat.so').write_bytes(data)
    info = dict(source='egl_client_extensions.c', source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                binary_sha256=hashlib.sha256(data).hexdigest(), bytes=len(data), build_type='Release',
                target='aarch64-linux-gnu; stock MiniLoong Mali g13p0; single-window Godot 4.3 GLES',
                compiler=subprocess.check_output([cc, '--version'], text=True).splitlines()[0],
                linker=subprocess.check_output([linker, '--version'], text=True).splitlines()[0],
                compile_args=compile_args, link_args=link_args)
    (COMPAT / 'loong-egl-compat.json').write_text(json.dumps(info, indent=2) + '\n')
    print(json.dumps(info))


if __name__ == '__main__':
    build()
