#!/usr/bin/env python3
# INPUT: project-owned diagnostic, player PCK and its bound texture report
# OUTPUT: small independent diagnostic PCK with private path-only metadata
# POS: opt-in post-start mount; never contains original art or game code
import argparse
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ('texture_diagnostic.gd', 'texture_diagnostic_runner.gd', 'texture_diagnostic.tscn',
         'ui_diagnostic.gd', 'ui_diagnostic.tscn', 'resource_stats.gd', 'font_cache_diagnostic.gd')
TEXTURE_TYPES = {b'AtlasTexture', b'CompressedTexture2D', b'PortableCompressedTexture2D', b'ImageTexture'}

def candidate_metadata(source_pck, report):
    sys.path.insert(0, str(ROOT / 'tools/godot_pck'))
    import low_texture_overlay as low
    import windows_texture_overlay as windows
    if low.file_hash(source_pck) != report.get('source_sha256'):
        raise ValueError('texture report and source PCK identities differ')
    if not re.fullmatch(r'[0-9a-f]{64}', report.get('output_sha256', '')):
        raise ValueError('invalid texture overlay identity')
    entries = low.read_pack(source_pck)
    with source_pck.open('rb') as stream:
        mapping, _, _, _ = windows.windows_import_map(stream, entries)
        texture_records = [x for x in report['resources'] if x.get('kind') == 'texture']
        records = {x['path']: x for x in texture_records}
        if len(records) != len(texture_records) or set(records) != set(mapping): raise ValueError('texture report does not match import mapping')
        paths = set(); font_paths = set()
        for target, (source, _) in mapping.items():
            if records[target]['source_path'] != source:
                raise ValueError('texture source mismatch: ' + target)
            paths.add('res://' + source)
            paths.add('res://' + target)
        for path in entries:
            if path.lower().endswith(('.otf.import', '.ttf.import')):
                data = low.entry_bytes(stream, entries[path])
                if b'type="FontFile"' in data:
                    match = re.search(rb'^path="res://([^"\r\n]+\.fontdata)"', data, re.M)
                    if not match: raise ValueError('unrecognized font import')
                    target = match.group(1).decode('utf-8')
                    if target not in entries: raise ValueError('font import target missing')
                    font_paths.update(('res://' + path[:-7], 'res://' + target))
            if not path.endswith('.tres'): continue
            data = low.entry_bytes(stream, entries[path])
            header = re.match(rb'^\[gd_resource\s+type="([^"\r\n]+)"', data)
            if header and header.group(1) in TEXTURE_TYPES:
                paths.add('res://' + path)
            if header and header.group(1) in (b'FontVariation', b'FontFile'):
                font_paths.add('res://' + path)
    if len(paths) > 30000: raise ValueError('too many texture candidates')
    if len(font_paths) > 512: raise ValueError('too many font candidates')
    for path in paths | font_paths:
        if (not path.startswith('res://') or any(part in ('', '.', '..') for part in path[6:].split('/'))
                or '\\' in path or any(ord(ch) < 32 or 127 <= ord(ch) <= 159 for ch in path)):
            raise ValueError('invalid texture candidate path')
    return {'source_sha256':report['source_sha256'], 'texture_overlay_sha256':report['output_sha256'],
            'paths':sorted(paths), 'font_paths':sorted(font_paths), 'scope':'source/imported texture and font paths and recognized built-in tres; cache membership does not prove simultaneous allocation'}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-pck', required=True, type=Path)
    parser.add_argument('--texture-report', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink(): raise ValueError('diagnostic output already exists')
    if args.output.resolve() in (args.source_pck.resolve(), args.texture_report.resolve()): raise ValueError('output must be separate')
    metadata = candidate_metadata(args.source_pck, json.loads(args.texture_report.read_text()))
    spec = importlib.util.spec_from_file_location('pck_writer', ROOT / 'scripts/make-overlay-pck.py')
    writer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(writer)
    files = []
    for name in FILES:
        content = (ROOT / 'texture_diagnostics' / name).read_bytes()
        files.append(('res://port_diagnostics/' + name, content, hashlib.md5(content).digest()))
    content = (json.dumps(metadata, ensure_ascii=True, separators=(',', ':')) + '\n').encode()
    files.append(('res://port_diagnostics/texture_candidates.json', content, hashlib.md5(content).digest()))
    if sum(len(path.encode()) + len(data) + 128 for path, data, _ in files) + 1024 > 1024 * 1024:
        raise ValueError('diagnostic PCK would exceed 1 MiB')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    writer.write_pack(files, args.output)

if __name__ == '__main__': main()
