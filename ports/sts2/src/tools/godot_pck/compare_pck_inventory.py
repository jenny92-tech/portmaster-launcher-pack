#!/usr/bin/env python3
# INPUT: two explicit Godot PCKs and optional game DLL/release metadata paths
# OUTPUT: private JSON with input hashes and per-path PCK inventory differences
# POS: read-only comparison; matching resource bytes do not establish provenance
import argparse
import hashlib
import json
from pathlib import Path

from low_texture_overlay import read_pack


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def compare(left, right):
    common = left.keys() & right.keys()
    same = lambda paths: sum(left[p][2] == right[p][2] for p in paths)
    suffixes = {}
    for suffix in ('.gdshader', '.tscn', '.cs', '.import', '.ctex'):
        paths = [p for p in common if p.endswith(suffix)]
        suffixes[suffix] = {'common': len(paths), 'same_md5': same(paths)}
    def formats(index):
        return {name: sum(p.endswith('.' + name + '.ctex') for p in index)
                for name in ('astc', 'etc2', 's3tc', 'bptc')}
    return {'left_entries': len(left), 'right_entries': len(right),
            'common': len(common), 'same_entry_md5': same(common),
            'different_entry_md5': len(common)-same(common),
            'left_only': len(left.keys()-right.keys()),
            'right_only': len(right.keys()-left.keys()), 'suffixes': suffixes,
            'left_vram_formats': formats(left), 'right_vram_formats': formats(right),
            'limitation': 'Directory MD5 compares recorded resource content, not source provenance or version identity.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--left-pck', type=Path, required=True)
    parser.add_argument('--right-pck', type=Path, required=True)
    parser.add_argument('--left-dll', type=Path)
    parser.add_argument('--right-dll', type=Path)
    parser.add_argument('--release-info', type=Path, help='unverified metadata from the left input')
    parser.add_argument('--deps', type=Path, help='dependency target metadata from the left input')
    parser.add_argument('--output', type=Path, required=True, help='new private JSON file')
    args = parser.parse_args()
    left = read_pack(args.left_pck)
    right = read_pack(args.right_pck)
    report = {'left_pck_sha256': sha256(args.left_pck),
              'right_pck_sha256': sha256(args.right_pck),
              'pck_comparison': compare(left, right),
              'left_audio_bank_count': sum(p.endswith('.bank') for p in left)}
    for name in ('left_dll', 'right_dll'):
        path = getattr(args, name)
        if path is not None:
            report[name + '_sha256'] = sha256(path)
    if args.release_info is not None:
        report['release_info_unverified'] = json.loads(args.release_info.read_text())
    if args.deps is not None:
        report['runtime_target'] = json.loads(args.deps.read_text())['runtimeTarget']['name']
    with args.output.open('x', encoding='utf8') as stream:
        json.dump(report, stream, indent=2, ensure_ascii=False)
        stream.write('\n')


if __name__ == '__main__':
    main()
