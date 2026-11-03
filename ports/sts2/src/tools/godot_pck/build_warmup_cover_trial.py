#!/usr/bin/env python3
# INPUT:  exact caab compatibility pack, manifest and audited warmup source
# OUTPUT: private small compatibility PCK and complete per-entry SHA report
# POS:    single-resource trial without changing the main pack or formal install
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile

import merge_texture_pck as pack

BASE = 'b6d49aadc25d02007c50eeae571ddea9fe5dbea0b555ba25d68b7e9d3d845d95'
MANIFEST = 'caab60d99a152c3b43d8fcb77b5ac8384a05c013c573d7080ef67d3efe435070'
OLD = '49818b4da2eb9460e2666e091d72e91cc6ac125e1f967817a32f3350ebcc95a4'
NEW = '66ced536fda060f5599bc01f330a57d7cee5a70f44eab2e9813c66d3fc93c636'
TARGET = 'port_compat/combat_warmup.gd'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('base', 'manifest', 'source', 'output-dir'):
        p.add_argument('--' + name, required=True, type=Path)
    a = p.parse_args()
    os.umask(0o077)
    inputs = (a.base, a.manifest, a.source)
    if any(x.is_symlink() or not x.is_file() for x in inputs):
        raise ValueError('inputs must be regular, non-symlink files')
    before = [pack.identity(x) for x in inputs]
    if [pack.sha256_file(x) for x in inputs] != [BASE, MANIFEST, NEW]:
        raise ValueError('unapproved base, manifest or source identity')
    manifest = json.loads(a.manifest.read_text())
    if manifest['files']['port_compat.pck'] != BASE:
        raise ValueError('manifest does not bind base PCK')
    index = pack.read_pack(a.base)
    if TARGET not in index:
        raise ValueError('warmup entry missing')
    replacement = a.source.read_bytes()
    items, records = [], []
    with a.base.open('rb') as f:
        for name, entry in sorted(index.items()):
            f.seek(entry[0])
            old = f.read(entry[1])
            if len(old) != entry[1] or hashlib.md5(old).digest() != entry[2]:
                raise ValueError('base entry integrity mismatch: ' + name)
            old_sha = hashlib.sha256(old).hexdigest()
            if name == TARGET and old_sha != OLD:
                raise ValueError('unexpected old warmup identity')
            data = replacement if name == TARGET else old
            items.append((name, data, hashlib.md5(data).digest()))
            records.append({'path': name, 'before_sha256': old_sha, 'after_sha256': hashlib.sha256(data).hexdigest()})
    if [x['path'] for x in records if x['before_sha256'] != x['after_sha256']] != [TARGET]:
        raise ValueError('replacement set is not exactly the warmup entry')
    a.output_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
    fd, tmp = tempfile.mkstemp(prefix='.warmup-', suffix='.pck', dir=a.output_dir)
    os.close(fd)
    tmp = Path(tmp)
    try:
        writer_path = Path(__file__).resolve().parents[2] / 'scripts/make-overlay-pck.py'
        spec = importlib.util.spec_from_file_location('sts2_overlay_writer', writer_path)
        writer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(writer)
        writer.write_pack([('res://' + n, data, md5) for n, data, md5 in items], tmp)
        if [pack.identity(x) for x in inputs] != before:
            raise ValueError('input changed during build')
        output = pack.read_pack(tmp)
        if set(output) != set(index):
            raise ValueError('output inventory differs')
        with tmp.open('rb') as f:
            for row in records:
                if pack.entry_sha256(f, output[row['path']]) != row['after_sha256']:
                    raise ValueError('output content mismatch: ' + row['path'])
        digest = pack.sha256_file(tmp)
        final = a.output_dir / (digest + '.pck')
        tmp.rename(final)
        report = {'base_sha256': BASE, 'base_manifest_sha256': MANIFEST, 'source_sha256': NEW,
                  'candidate_sha256': digest, 'entry_count': len(records), 'replaced': [TARGET],
                  'entries': records, 'scope': 'isolated warmup cover trial; not a formal install manifest'}
        (a.output_dir / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=True) + '\n')
        print('candidate SHA-256:', digest)
    finally:
        if tmp.exists():
            tmp.unlink()


if __name__ == '__main__':
    main()
