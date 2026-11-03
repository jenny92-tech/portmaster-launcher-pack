#!/usr/bin/env python3
# INPUT: exact trial main, verified six-font delta and report, and original reference main
# OUTPUT: private merged PCK and manifest for a Chinese-only isolated test
# POS: preserve every non-font entry; never modify the installed or source PCK
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import tempfile

import merge_texture_pck as pack
import strip_common_font_cache as fonts
import strip_font_cache as sc

REFERENCE = '3abccf4a75ea347b0d4cece05d376beeaf42b4f34a3af1ccc17644bd2762203d'
QUARTER = '7ec4bb3f96fd01dc42bde20b6daa2f98cd16f09cec3b8ef404efd53f089615f1'
APPROVED = {
    '7bb1625409736206bbcf84b7cc58c3c684466e6b63abf91f229a38baa9d13fbc': '08f0b873ad6af5a734c4577faf70b381b6bcd4816c73a138d87e61fc1efd68bc',
    '9be7d434ac96500a7003202a89b26c521dd48d4b78b7de62bc48e4a422c0b654': 'db7f60ba360cdbcf0c0e80eef0ced5878ccccac99acef34763536bd2d4c82d14',
}
CANONICAL = '9be7d434ac96500a7003202a89b26c521dd48d4b78b7de62bc48e4a422c0b654'


def main():
    p = argparse.ArgumentParser(description='Merge only the audited Chinese fallback trial.')
    for name in ('main', 'reference', 'delta', 'report', 'output-dir'):
        p.add_argument('--' + name, type=Path, required=True)
    a = p.parse_args()
    os.umask(0o077)
    inputs = (a.main, a.reference, a.delta, a.report)
    if any(x.is_symlink() or not x.is_file() for x in inputs):
        raise ValueError('inputs must be regular, non-symlink files')
    before = [pack.identity(x) for x in inputs]
    main_sha = pack.sha256_file(a.main)
    delta_sha, report_sha = pack.sha256_file(a.delta), pack.sha256_file(a.report)
    if (main_sha not in (REFERENCE, QUARTER) or pack.sha256_file(a.reference) != REFERENCE or
            APPROVED.get(delta_sha) != report_sha):
        raise ValueError('unapproved main, reference, delta or report identity')
    report = json.loads(a.report.read_text())
    if (report['base_main_sha256'] != REFERENCE or report['delta_sha256'] != delta_sha or
            report['all_six_eager_loading_verified'] is not True or report['examined_codepoints'] != 2493):
        raise ValueError('trial report identity or coverage mismatch')
    if delta_sha == CANONICAL and report.get('canonical_source_cache_identity_both_orders_verified') is not True:
        raise ValueError('canonical cache identity not verified')
    records = {r['original'].removeprefix('res://'): r for r in report['resources']}
    expected_names = {'.godot/imported/' + x for x in fonts.COMMON_OUTPUTS}
    if len(report['resources']) != 6 or set(records) != expected_names:
        raise ValueError('unexpected report resources')
    main, ref, delta = (pack.read_pack(x) for x in (a.main, a.reference, a.delta))
    if set(delta) != expected_names or not expected_names <= main.keys():
        raise ValueError('delta is not the exact six-entry set')
    with a.main.open('rb') as m, a.reference.open('rb') as r, a.delta.open('rb') as d:
        for name, digest in (fonts.COMMON_OUTPUTS | fonts.SC_OUTPUTS).items():
            path = '.godot/imported/' + name
            if pack.entry_sha256(m, main[path]) != digest or pack.entry_sha256(r, ref[path]) != digest:
                raise ValueError('font source identity mismatch: ' + path)
        imports = [x[0] for x in fonts.COMMON.values()] + [x[0] for x in sc.FONTS.values()]
        for path in imports:
            if pack.entry_sha256(m, main[path]) != pack.entry_sha256(r, ref[path]):
                raise ValueError('font import differs: ' + path)
        loc = {x['path']: x['sha256'] for x in report['locale_files']}
        if len(loc) != 46 or set(loc) != {x for x in main if x.startswith('localization/zhs/') and x.endswith('.json')}:
            raise ValueError('localization inventory differs')
        for path, digest in loc.items():
            if pack.entry_sha256(m, main[path]) != digest:
                raise ValueError('localization differs: ' + path)
        for path, item in records.items():
            if (item['missing_after'] or item['latin_metric_samples'] != 42 or not item['settings_preserved'] or
                    item['dependencies'] != [item['fallback']] or pack.entry_sha256(d, delta[path]) != item['output_sha256']):
                raise ValueError('font trial validation failed: ' + path)
    a.output_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
    required = sum((delta.get(n, e)[1] + 15) // 16 * 16 for n, e in main.items()) + 32 * 1024 * 1024
    if shutil.disk_usage(a.output_dir).free < required:
        raise ValueError('insufficient disk space')
    fd, name = tempfile.mkstemp(prefix='.merging-', dir=a.output_dir)
    temp = Path(name)
    try:
        with os.fdopen(fd, 'w+b') as out, a.main.open('rb') as m, a.delta.open('rb') as d:
            out.write(struct.pack('<6I2Q', *pack.HEADER, 2, 112, 0) + bytes(72))
            directory = []
            for index, path in enumerate(sorted(main), 1):
                entry = delta.get(path, main[path])
                offset = out.tell() - 112
                if path in delta:
                    pack.transfer(m, main[path])
                    pack.transfer(d, entry, out)
                else:
                    pack.transfer(m, entry, out)
                directory.append((path, offset, entry[1], entry[2]))
                out.write(bytes(-out.tell() % 16))
                if index % 2048 == 0:
                    print('Merged', index, 'entries', flush=True)
            position = out.tell()
            out.write(struct.pack('<I', len(directory)))
            for path, offset, length, md5 in directory:
                raw = ('res://' + path).encode()
                raw += bytes(-len(raw) % 4)
                out.write(struct.pack('<I', len(raw)) + raw + struct.pack('<QQ16sI', offset, length, md5, 0))
            out.seek(32)
            out.write(struct.pack('<Q', position))
            out.flush()
            os.fsync(out.fileno())
        if [pack.identity(x) for x in inputs] != before:
            raise ValueError('input changed during merge')
        result = pack.read_pack(temp)
        if {n: v[1:] for n, v in result.items()} != {n: delta.get(n, e)[1:] for n, e in main.items()}:
            raise ValueError('output directory differs')
        with temp.open('rb') as f:
            for entry in result.values():
                pack.transfer(f, entry)
        digest = pack.sha256_file(temp)
        final = a.output_dir / (digest + '.pck')
        temp.rename(final)
        manifest = {'main_sha256': main_sha, 'reference_sha256': REFERENCE, 'delta_sha256': delta_sha, 'report_sha256': report_sha,
                    'merged_sha256': digest, 'entries': len(result), 'replaced': sorted(delta),
                    'scope': 'Chinese-only isolated trial; common fonts eagerly load SC fallbacks'}
        (a.output_dir / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print('Merged SHA-256:', digest, flush=True)
    finally:
        if temp.exists():
            temp.unlink()


if __name__ == '__main__':
    main()
