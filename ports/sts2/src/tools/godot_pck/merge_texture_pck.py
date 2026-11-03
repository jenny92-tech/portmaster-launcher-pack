#!/usr/bin/env python3
# INPUT:  original Godot 4.5.1 PCK, audited texture overlay and build report
# OUTPUT: immutable merged PCK and sidecar binding both inputs and file identities
# POS:    stream replacement texture entries without changing the original game data
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import sys
import tempfile

BLOCK = 1024 * 1024
HEADER = (0x43504447, 3, 4, 5, 1)
AUDITED_FONT_SOURCE_SHA256 = {
    '.godot/imported/SourceHanSerifSC-Bold.otf-04194762e7aa80a4d47a9f4f008eea67.fontdata': 'cf9d9a2948cf582e73a27c3c4d6f225c1483495057f4fffa66df9242b65d29ce',
    '.godot/imported/SourceHanSerifSC-Medium.otf-8b1ba143f94f2163fdbd47c3f56634f6.fontdata': 'e73efe426dd1f713e31b58ee34544bb0567949645b51d14059486c604478494e',
    '.godot/imported/NotoSansMonoCJKsc-Regular.otf-305974efdd77ba2d99a45c70df2b9c8e.fontdata': '89b8497ad0ca58e9e53e45e522ef2a345fa944f6a26fbdebf3c3261eb9b28df9',
}


AUDITED_COMMON_FONT_SOURCE_SHA256 = {'.godot/imported/bitter_medium_italic.ttf-92c479ff6780df2f74f735b7f108e0e9.fontdata': '021b61ec6ffe4e921b029fbcaf6db2aca58bbefd28d7341e6fee57e1e6715d4e', '.godot/imported/kreon_bold.ttf-a39b3c2b8efde4e39050a84b27e67a76.fontdata': '7a3e3911f7b942bff4a76bac91ca487d0aa44469a49ea86932b6c7953a908f59', '.godot/imported/kreon_regular.ttf-a20220d5ba8adf850addcf353acfb496.fontdata': 'd1afbadb7e8ecceb64f3ab9fdcdc6ef2c87698d54ae665dc993976a55a512482', '.godot/imported/source_code_pro_medium.ttf-42cc704cdf728adbe8d0ac6480960df4.fontdata': 'e0a1f371ee06f94991252baf6e09a4c11262ea2abbbf28ba8ed2e9ea7f46acb7', '.godot/imported/source_code_pro_semibold.ttf-d97019f12ae606d07c23e8b03c8070e7.fontdata': '1c2ee7f683ba76c20ea03205d677575f60befcdc75bd9bff00db89ce2c03fdc6', '.godot/imported/spectral_bold.ttf-e378b9e7ebaebc8fb5ecb687a6943388.fontdata': '691a1191d783a2f4eebe50c1f55554e645ec097bb21c88526ae818a8605900f1'}

def identity(path):
    s = path.stat()
    if not stat.S_ISREG(s.st_mode):
        raise ValueError('not a regular file: ' + str(path))
    return {'size': s.st_size, 'mtime_ns': s.st_mtime_ns, 'ctime_ns': s.st_ctime_ns,
            'device': s.st_dev, 'inode': s.st_ino}


def sha256_file(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(BLOCK), b''):
            h.update(block)
    return h.hexdigest()


def read_pack(path):
    size = path.stat().st_size
    with path.open('rb') as f:
        data = f.read(104)
        if len(data) != 104:
            raise ValueError('truncated PCK header')
        magic, version, major, minor, patch, flags, base, directory = struct.unpack_from('<6I2Q', data)
        if (magic, version, major, minor, patch) != HEADER or flags not in (0, 2) or directory < 104 or directory + 4 > size:
            raise ValueError('unsupported PCK header')
        f.seek(directory)
        count, = struct.unpack('<I', f.read(4))
        if count > 1000000:
            raise ValueError('invalid PCK count')
        entries = {}
        for _ in range(count):
            raw = f.read(4)
            if len(raw) != 4: raise ValueError('truncated PCK directory')
            n, = struct.unpack('<I', raw)
            if not 0 < n <= 16384 or n % 4: raise ValueError('invalid PCK path length')
            raw = f.read(n)
            fields = f.read(36)
            if len(raw) != n or len(fields) != 36: raise ValueError('truncated PCK entry')
            name = raw.rstrip(b'\0').decode('utf-8')
            if '\0' in name: raise ValueError('invalid PCK path')
            if name.startswith('res://'): name = name[6:]
            offset, length, md5, eflags = struct.unpack('<QQ16sI', fields)
            offset += base if flags == 2 else 0
            if (not name or name.startswith('/') or '\\' in name or
                any(part in ('', '.', '..') for part in name.split('/')) or name in entries or
                eflags or offset < 104 or offset + length > directory):
                raise ValueError('unsupported PCK entry: ' + name)
            entries[name] = (offset, length, md5)
        if f.tell() > size: raise ValueError('PCK directory outside file')
    return entries


def transfer(src, entry, output=None):
    offset, length, expected = entry
    src.seek(offset)
    md5 = hashlib.md5()
    remaining = length
    while remaining:
        block = src.read(min(BLOCK, remaining))
        if not block: raise ValueError('truncated PCK payload')
        md5.update(block)
        if output is not None: output.write(block)
        remaining -= len(block)
    if md5.digest() != expected: raise ValueError('PCK entry checksum mismatch')


def entry_sha256(src, entry):
    offset, length, expected = entry
    src.seek(offset); sha = hashlib.sha256(); md5 = hashlib.md5()
    while length:
        block = src.read(min(BLOCK, length))
        if not block: raise ValueError('truncated PCK payload')
        sha.update(block); md5.update(block); length -= len(block)
    if md5.digest() != expected: raise ValueError('PCK entry checksum mismatch')
    return sha.hexdigest()


def separate(path, inputs):
    for other in inputs:
        if path.resolve() == other.resolve() or (path.exists() and other.exists() and os.path.samefile(path, other)):
            raise ValueError('output aliases input: ' + str(other))
    if path.is_symlink(): raise ValueError('output must not be a symlink')


def prepare(source, overlay, report, outdir, compat=None, compat_report=None, approved_font_hashes=None):
    if (compat is None) != (compat_report is None): raise ValueError('compat pack and report must be supplied together')
    if approved_font_hashes is not None and approved_font_hashes not in (AUDITED_FONT_SOURCE_SHA256, AUDITED_COMMON_FONT_SOURCE_SHA256):
        raise ValueError('font approval must match the exact audited source identities')
    sources = (source, overlay, report) + ((compat, compat_report) if compat is not None else ())
    for i, first in enumerate(sources):
        for second in sources[i + 1:]:
            if first.resolve() == second.resolve() or os.path.samefile(first, second):
                raise ValueError('inputs must be distinct')
    if source.is_symlink() or overlay.is_symlink():
        raise ValueError('PCK inputs must be regular non-symlink files')
    stats = [identity(p) for p in sources]
    build = json.loads(report.read_text(encoding='utf-8'))
    source_sha, overlay_sha = build['source_sha256'], build['output_sha256']
    if not all(isinstance(v, str) and re.fullmatch(r'[0-9a-f]{64}', v) for v in (source_sha, overlay_sha)):
        raise ValueError('invalid build report hashes')
    if sha256_file(source) != source_sha or sha256_file(overlay) != overlay_sha:
        raise ValueError('build report/input SHA-256 mismatch')
    source_entries, overlay_entries = read_pack(source), read_pack(overlay)
    compat_entries = {}
    if compat is not None:
        compatibility = json.loads(compat_report.read_text(encoding='utf-8'))
        if compatibility.get('source_pck_sha256') != source_sha or compatibility.get('overlay_sha256') != sha256_file(compat):
            raise ValueError('compat report/input SHA-256 mismatch')
        compat_entries = read_pack(compat)
        declared = compatibility.get('resources')
        if not isinstance(declared, list) or len(set(declared)) != len(declared) or set(declared) != {'res://' + n for n in compat_entries}:
            raise ValueError('compat PCK does not match its source-bound report')
        if set(compat_entries) & set(overlay_entries): raise ValueError('texture and compat overlays conflict')
    reported = {}
    report_records = {}
    for r in build['resources']:
        if 'output_md5' in r:
            if r['path'] in reported: raise ValueError('duplicate reported texture')
            reported[r['path']] = r['output_md5']
            report_records[r['path']] = r
    if not overlay_entries or set(overlay_entries) != set(reported):
        raise ValueError('overlay does not match report texture set')
    with source.open('rb') as original, overlay.open('rb') as replacement:
        for name, (_, _, md5) in overlay_entries.items():
            if name not in source_entries or reported[name] != md5.hex():
                raise ValueError('unapproved texture replacement: ' + name)
            if name.startswith('.godot/imported/') and name.endswith('.ctex'):
                continue
            record = report_records[name]
            if approved_font_hashes is not None and name in approved_font_hashes:
                expected = approved_font_hashes[name]
                if (record.get('kind') != 'audited_font' or record.get('source_sha256') != expected or
                    not isinstance(record.get('output_sha256'), str) or not re.fullmatch(r'[0-9a-f]{64}', record['output_sha256']) or
                    entry_sha256(original, source_entries[name]) != expected or
                    entry_sha256(replacement, overlay_entries[name]) != record['output_sha256']):
                    raise ValueError('font entry differs from audited source or output: ' + name)
                continue
            if not name.endswith('.import') or record.get('kind') != 'import' or source_entries[name][1] > 1024*1024 or overlay_entries[name][1] > 1024*1024:
                raise ValueError('unapproved texture import replacement: ' + name)
            # Only accept the exact desktop-to-mobile import rewrite linked to
            # another reported texture in this overlay, never an arbitrary file.
            import windows_texture_overlay
            original.seek(source_entries[name][0]); old = original.read(source_entries[name][1])
            replacement.seek(overlay_entries[name][0]); new = replacement.read(overlay_entries[name][1])
            transfer(original, source_entries[name]); transfer(replacement, overlay_entries[name])
            if hashlib.md5(old).hexdigest() != record.get('source_md5'):
                raise ValueError('texture import source mismatch: ' + name)
            paths = re.findall(rb'^path\.(bptc|s3tc)="res://(\.godot/imported/[^"\n]+\.ctex)"', old, re.M)
            if len(paths) != 1: raise ValueError('unexpected source texture import: ' + name)
            variant, target = (part.decode('utf8') for part in paths[0])
            if target not in overlay_entries or report_records[target].get('kind') != 'texture' or windows_texture_overlay.rewrite_import(old,variant,target) != new:
                raise ValueError('invalid texture import rewrite: ' + name)
    names = sorted(source_entries.keys() | compat_entries.keys())
    directory_size = 4 + sum(4 + ((len(('res://' + n).encode()) + 3) // 4 * 4) + 36 for n in names)
    def selected(n):
        return compat_entries.get(n) or overlay_entries.get(n) or source_entries[n]
    data_size = sum((selected(n)[1] + 15) // 16 * 16 for n in names)
    needed = 112 + data_size + directory_size
    outdir.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(outdir).free < needed + 16 * 1024 * 1024:
        raise ValueError('insufficient free space for merged PCK and safety margin')
    fd, temp_name = tempfile.mkstemp(prefix='.texture-merge-', suffix='.incoming', dir=outdir)
    temp = Path(temp_name)
    final = None
    newly_installed = None
    committed = False
    try:
        with os.fdopen(fd, 'w+b') as out, source.open('rb') as src, overlay.open('rb') as ov, (compat.open('rb') if compat is not None else open(os.devnull, 'rb')) as cv:
            out.write(struct.pack('<6I2Q', *HEADER, 2, 112, 0) + bytes(64) + bytes(8))
            directory = []
            for index, name in enumerate(names, 1):
                is_compat = name in compat_entries
                is_overlay = name in overlay_entries
                entry = selected(name)
                offset = out.tell() - 112
                if is_compat:
                    if name in source_entries: transfer(src, source_entries[name])
                    transfer(cv, entry, out)
                elif is_overlay:
                    transfer(src, source_entries[name])
                    transfer(ov, entry, out)
                else:
                    transfer(src, entry, out)
                directory.append((name, offset, entry[1], entry[2]))
                out.write(bytes((-out.tell()) % 16))
                if index % 1024 == 0 or index == len(names):
                    print('merged entries {}/{}'.format(index, len(names)), flush=True)
            dir_offset = out.tell()
            out.write(struct.pack('<I', len(directory)))
            for name, offset, length, md5 in directory:
                raw = ('res://' + name).encode('utf-8')
                raw += bytes((-len(raw)) % 4)
                out.write(struct.pack('<I', len(raw)) + raw + struct.pack('<QQ16sI', offset, length, md5, 0))
            out.seek(32)
            out.write(struct.pack('<Q', dir_offset))
            os.fchmod(out.fileno(), 0o644)
            out.flush()
            os.fsync(out.fileno())
        if [identity(p) for p in sources] != stats: raise ValueError('input changed during merge')
        result = read_pack(temp)
        expected = {n: selected(n)[1:] for n in names}
        if {n: v[1:] for n, v in result.items()} != expected:
            raise ValueError('merged directory mismatch')
        with temp.open('rb') as f:
            for n in names: transfer(f, result[n])
        merged_sha = sha256_file(temp)
        final = outdir / (merged_sha + '.pck')
        sidecar = outdir / (merged_sha + '.json')
        separate(final, sources)
        separate(sidecar, sources)
        if final.exists():
            if sha256_file(final) != merged_sha: raise ValueError('existing merged file checksum mismatch')
            temp.unlink()
        else:
            os.rename(temp, final)
            newly_installed = identity(final)
        if [identity(p) for p in sources] != stats: raise ValueError('input changed before manifest')
        manifest = {'source_sha256': source_sha, 'overlay_sha256': overlay_sha, 'merged_sha256': merged_sha,
                    'source_stat': {k: stats[0][k] for k in ('size', 'mtime_ns')},
                    'merged_stat': {k: identity(final)[k] for k in ('size', 'mtime_ns')}}
        if compat is not None:
            manifest['compat_sha256'] = compatibility['overlay_sha256']
        manifest_fd, manifest_name = tempfile.mkstemp(prefix='.' + merged_sha + '-', suffix='.incoming', dir=outdir)
        try:
            with os.fdopen(manifest_fd, 'w', encoding='utf-8') as f:
                json.dump(manifest, f, sort_keys=True)
                f.write('\n')
                os.fchmod(f.fileno(), 0o644)
                f.flush()
                os.fsync(f.fileno())
            os.replace(manifest_name, sidecar)
        finally:
            if os.path.exists(manifest_name): os.unlink(manifest_name)
        print('merged SHA-256: ' + merged_sha, flush=True)
        committed = True
        return final
    finally:
        if temp.exists(): temp.unlink()
        if not committed and newly_installed is not None and final.exists() and identity(final) == newly_installed:
            final.unlink()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--report', type=Path, required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    p.add_argument('--compat', type=Path)
    p.add_argument('--compat-report', type=Path)
    args = p.parse_args()
    prepare(args.source, args.overlay, args.report, args.output_dir, args.compat, args.compat_report)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, struct.error) as exc:
        raise SystemExit('texture merge failed: ' + str(exc))
