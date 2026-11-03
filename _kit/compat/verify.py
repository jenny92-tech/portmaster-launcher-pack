#!/usr/bin/env python3
# INPUT:  本目录 artifact.json、SHA256、明确列出的归档文件及 ARM64 ELF 头
# OUTPUT: verify_archive() 与静态归档校验结果，不加载或执行二进制
# POS:    在复用兼容产物前验证实体、完整性、路径及架构
import argparse
import hashlib
import json
from pathlib import Path
import struct


def archive_file(root, relative):
    name = Path(relative)
    if name.is_absolute() or not name.parts or '..' in name.parts:
        raise ValueError('archive path escapes its directory: ' + relative)
    file = root / name
    if file.is_symlink() or not file.resolve().is_relative_to(root.resolve()):
        raise ValueError('archive path escapes its directory: ' + relative)
    return file


def verify_archive(directory):
    root = Path(directory)
    record = json.loads((root / 'artifact.json').read_text(encoding='utf-8'))
    binary = record['binary']
    library = archive_file(root, binary['path'])
    data = library.read_bytes()
    if data.startswith(b'version https://git-lfs.github.com/spec/v1'):
        raise ValueError('LFS pointer is not an ELF; restore this artifact with git lfs pull')
    if (len(data) < 64 or data[:6] != b'\x7fELF\x02\x01' or
            struct.unpack_from('<HH', data, 16) != (3, 183)):
        raise ValueError('binary must be an ELF64 little-endian AArch64 shared object')
    if len(data) != binary['bytes'] or hashlib.sha256(data).hexdigest() != binary['sha256']:
        raise ValueError('binary size/SHA256 mismatch')
    if binary['path'] not in record['files']:
        raise ValueError('binary is missing from the archive file list')
    actual = set()
    for file in root.rglob('*'):
        if file.is_symlink():
            raise ValueError('archive must not contain symbolic links')
        if file.is_file() and file.name != 'artifact.json':
            actual.add(file.relative_to(root).as_posix())
    if actual != set(record['files']):
        raise ValueError('archive file list differs from its recorded contents')
    for relative, expected in record['files'].items():
        payload = archive_file(root, relative).read_bytes()
        if len(payload) != expected['bytes'] or hashlib.sha256(payload).hexdigest() != expected['sha256']:
            raise ValueError('archive file size/SHA256 mismatch: ' + relative)
    return {'artifact_id': record['artifact_id'], 'binary_bytes': len(data),
            'binary_sha256': binary['sha256'], 'files_verified': len(record['files'])}


def main():
    parser = argparse.ArgumentParser(description='Verify archived compatibility files without executing them.')
    parser.add_argument('directory', nargs='?', type=Path)
    args = parser.parse_args()
    targets = [args.directory] if args.directory else [p.parent for p in sorted(Path(__file__).parent.glob('*/artifact.json'))]
    if not targets:
        parser.error('no compatibility artifacts found')
    try:
        for target in targets:
            print(json.dumps(verify_archive(target), ensure_ascii=False))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
