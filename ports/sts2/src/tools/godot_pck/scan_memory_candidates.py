#!/usr/bin/env python3
# INPUT: player PCK, its texture-build report, and observed or candidate res:// roots
# OUTPUT: private static dependency inventory and bounded texture-size estimates
# POS: offline triage; neither executes game code nor measures RSS or GPU allocation
import argparse
import json
import re
from pathlib import Path
import low_texture_overlay as low

TEXT_TYPES = ('.tscn', '.tres', '.gdshader', '.gdshaderinc')
REFERENCES = re.compile(rb'(?:\bpath\s*=\s*"|#include\s+")res://([^"\r\n]+)')


def texture_estimate(info):
    width, height = info['gpu']
    levels = info['mipmaps'] + 1
    dimensions = [(max(1, width >> i), max(1, height >> i)) for i in range(levels)]
    pixels = sum(w*h for w, h in dimensions)
    dtype, fmt = info['data_format'], info['image_format']
    if dtype == 2 and fmt in (0, 1, 4, 5):
        bpp = {0:1, 1:2, 4:3, 5:4}[fmt]
        return {'nominal_min_bytes': pixels*bpp, 'nominal_max_bytes': pixels*(4 if fmt == 4 else bpp),
                'basis': 'decoded WebP pixels; RGB may be promoted to RGBA'}
    if dtype == 0 and fmt in (35, 37):
        block = 4 if fmt == 35 else 8
        size = sum(((w+block-1)//block)*((h+block-1)//block)*16 for w,h in dimensions)
        return {'nominal_min_bytes': size, 'nominal_max_bytes': size,
                'basis': 'ASTC block storage if the device supports the format; unsupported hardware may expand it'}
    if dtype == 0 and fmt == 5:
        return {'nominal_min_bytes': pixels*4, 'nominal_max_bytes': pixels*4, 'basis': 'RGBA8 pixels'}
    return None


def spine_atlas_pages(source, entries, stream):
    """Read exported Spine JSON metadata; return image paths, not asset data."""
    import_path = source + '.import'
    if import_path not in entries:
        return None
    metadata = low.entry_bytes(stream, entries[import_path])
    match = re.search(rb'(?m)^path="res://([^"\r\n]+\.spatlas)"', metadata)
    if not match:
        return None
    target = match.group(1).decode('utf-8')
    if target not in entries: return None
    atlas = json.loads(low.entry_bytes(stream, entries[target]))
    if atlas.get('source_path') != 'res://' + source or not isinstance(atlas.get('atlas_data'), str):
        raise ValueError('Spine atlas source identity mismatch: '+source)
    lines = atlas['atlas_data'].splitlines()
    pages = []
    for i in range(len(lines)-1):
        name = lines[i].strip()
        if name and lines[i+1].strip().startswith('size:'):
            if '/' in name or '\\' in name or name in ('.','..') or not name.lower().endswith(('.png','.webp','.jpg','.jpeg')):
                raise ValueError('Unrecognized Spine atlas page: '+source)
            pages.append(str(Path(source).parent / name))
    if not pages:
        raise ValueError('No recognizable Spine atlas pages: '+source)
    return pages


def scan(source_pck, report, roots):
    source_sha = low.file_hash(source_pck)
    if report.get('source_sha256') != source_sha:
        raise ValueError('texture report and source PCK identities differ')
    entries = low.read_pack(source_pck)
    textures = {}
    for item in report.get('resources', []):
        if item.get('kind') != 'texture': continue
        source = item['source_path']
        if source in textures: raise ValueError('duplicate source texture: '+source)
        textures[source] = item
    seen = set(); stack = []
    for root in roots:
        if not isinstance(root, str) or not root.startswith('res://') or '..' in root.split('/'):
            raise ValueError('invalid resource path')
        stack.append(root[6:])
    missing = set()
    with source_pck.open('rb') as stream:
        while stack:
            path = stack.pop()
            if path in seen: continue
            seen.add(path)
            # Source image paths are represented by import metadata and CTEX.
            if path in textures: continue
            if path.endswith('.atlas'):
                pages = spine_atlas_pages(path, entries, stream)
                if pages is not None:
                    stack.extend(pages)
                    continue
            if path not in entries:
                missing.add(path); continue
            if path.endswith(TEXT_TYPES):
                blob = low.entry_bytes(stream, entries[path])
                for target in REFERENCES.findall(blob):
                    stack.append(target.decode('utf-8'))
    results = []
    for path in sorted(seen & textures.keys()):
        item = textures[path]
        info = item.get('output', item['input'])
        results.append({'path':'res://'+path, 'texture_path':'res://'+item['path'],
            'physical_size':info['gpu'], 'logical_size':info['logical'], 'data_format':info['data_format'],
            'image_format':info['image_format'], 'mipmaps':info['mipmaps'],
            'texture_bytes_estimate':texture_estimate(info), 'strategy':item.get('strategy'),
            'retained_reason':item.get('skip_reason')})
    known = [x['texture_bytes_estimate'] for x in results if x['texture_bytes_estimate'] is not None]
    return {'source_sha256':source_sha, 'texture_overlay_sha256':report.get('output_sha256'),
        'roots':sorted(set(roots)), 'closure_paths':len(seen), 'texture_count':len(results),
        'texture_bytes_nominal_min':sum(x['nominal_min_bytes'] for x in known),
        'texture_bytes_nominal_max':sum(x['nominal_max_bytes'] for x in known),
        'unestimated_texture_count':len(results)-len(known),
        'missing_or_non_pck_paths':['res://'+x for x in sorted(missing)], 'textures':results,
        'limitations':['Static text ext_resource, res:// includes and exported Spine .spatlas page names only; no UID-only, dynamic, native, runtime-generated, or other binary dependency expansion.',
            'Inputs can be candidates or observed loads; closure is not proof of simultaneous residency.',
            'Nominal estimates are image/block sizes for supported formats, not upper bounds on RSS or GPU allocation; device fallback, alignment, staging and lifetime can change them.',
            'Texture report describes an overlay; independently verify the active main PCK and report identities.']}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-pck', type=Path, required=True)
    p.add_argument('--texture-report', type=Path, required=True)
    p.add_argument('--roots', type=Path, required=True, help='UTF-8 file with one res:// path per line')
    p.add_argument('--output', type=Path, required=True, help='fresh private JSON output')
    args = p.parse_args()
    low.ensure_distinct_paths((args.source_pck, args.texture_report, args.roots, args.output))
    if args.output.exists(): raise ValueError('output already exists')
    roots = [line.strip() for line in args.roots.read_text().splitlines() if line.strip()]
    result = scan(args.source_pck, json.loads(args.texture_report.read_text()), roots)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')

if __name__ == '__main__':
    main()
