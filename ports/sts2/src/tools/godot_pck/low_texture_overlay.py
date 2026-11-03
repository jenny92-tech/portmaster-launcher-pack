#!/usr/bin/env python3
# INPUT:  Godot 4.5.1、玩家 PCK、CPU 纹理转换脚本与私有缓存
# OUTPUT: 独立半分辨率纹理覆盖 PCK 和逐资源 JSON 报告
# POS:    保留逻辑坐标与纹理格式，安全构建可恢复的低清纹理资源
"""Build a private, fail-closed Godot 4.5.1 texture overlay."""
import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
from collections import Counter
from pathlib import Path

WORKER = Path(__file__).with_name('low_texture_worker.gd')
FLAGS = 0x0dc00000
BLOCK = {35: 4, 37: 8}
WEBP_FORMATS = {0, 1, 4, 5}


def digest(data, algorithm='sha256'):
    return hashlib.new(algorithm, data).hexdigest()


def file_hash(path):
    h = hashlib.sha256()
    with path.open('rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def texture_header(blob):
    if len(blob) < 52 or blob[:4] != b'GST2':
        raise ValueError('invalid GST2 header')
    version, lw, lh, flags, limit = struct.unpack_from('<5I', blob, 4)
    dtype, w, h, mips, fmt = struct.unpack_from('<IHHII', blob, 36)
    if version != 1 or not lw or not lh or not w or not h or flags & ~FLAGS or blob[24:36] != bytes(12):
        raise ValueError('unknown GST2 version, flags or dimensions')
    if bool(flags & 0x800000) != bool(mips):
        raise ValueError('mipmap flag and mip count disagree')
    return {'logical': [lw, lh], 'gpu': [w, h], 'flags': flags, 'limit': limit,
            'data_format': dtype, 'image_format': fmt, 'mipmaps': mips, 'bytes': len(blob)}


def webp_dimensions(blob):
    if len(blob) < 20 or blob[:4] != b'RIFF' or blob[8:12] != b'WEBP' or struct.unpack_from('<I', blob, 4)[0] + 8 != len(blob):
        raise ValueError('invalid WebP RIFF length or signature')
    offset, canvas, dimensions = 12, None, None
    while offset < len(blob):
        if offset + 8 > len(blob):
            raise ValueError('truncated WebP chunk')
        kind, size = struct.unpack_from('<4sI', blob, offset)
        start, end = offset + 8, offset + 8 + size
        if end > len(blob):
            raise ValueError('invalid WebP chunk length')
        chunk = blob[start:end]
        if kind == b'VP8X':
            if len(chunk) != 10 or chunk[0] & 2 or canvas is not None:
                raise ValueError('unsupported animated or invalid WebP')
            canvas = (int.from_bytes(chunk[4:7], 'little') + 1, int.from_bytes(chunk[7:10], 'little') + 1)
        elif kind == b'VP8L':
            if len(chunk) < 5 or chunk[0] != 0x2f or dimensions is not None:
                raise ValueError('invalid WebP lossless image')
            bits = struct.unpack_from('<I', chunk, 1)[0]
            if bits >> 29:
                raise ValueError('unsupported WebP lossless version')
            dimensions = (1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff))
        elif kind == b'VP8 ':
            if len(chunk) < 10 or chunk[3:6] != b'\x9d\x01\x2a' or dimensions is not None:
                raise ValueError('invalid WebP lossy image')
            dimensions = tuple(v & 0x3fff for v in struct.unpack_from('<HH', chunk, 6))
        elif kind in (b'ANIM', b'ANMF'):
            raise ValueError('animated WebP unsupported')
        offset = end + (size & 1)
    if offset != len(blob) or dimensions is None or (canvas is not None and canvas != dimensions):
        raise ValueError('invalid WebP canvas or missing image')
    return dimensions


def parse_texture(blob):
    info = texture_header(blob)
    dtype, fmt, mips = (info[k] for k in ('data_format', 'image_format', 'mipmaps'))
    w, h = info['gpu']
    if dtype == 0 and fmt in BLOCK:
        size = sum(((max(1, w >> level) + BLOCK[fmt] - 1) // BLOCK[fmt]) *
                   ((max(1, h >> level) + BLOCK[fmt] - 1) // BLOCK[fmt]) * 16
                   for level in range(mips + 1))
        if mips and mips != max(w, h).bit_length() - 1:
            raise ValueError('incomplete ASTC mip chain')
        if len(blob) != 52 + size:
            raise ValueError('ASTC data length mismatch')
    elif dtype == 2 and fmt in WEBP_FORMATS:
        if mips and mips != max(w, h).bit_length() - 1:
            raise ValueError('incomplete WebP mip chain')
        offset = 52
        for level in range(mips + 1):
            if offset + 4 > len(blob):
                raise ValueError('truncated WebP mip length')
            length, = struct.unpack_from('<I', blob, offset)
            offset += 4
            if offset + length > len(blob):
                raise ValueError('truncated WebP mip data')
            if webp_dimensions(blob[offset:offset + length]) != (max(1, w >> level), max(1, h >> level)):
                raise ValueError('WebP mip dimensions mismatch')
            offset += length
        if offset != len(blob):
            raise ValueError('extra WebP mip data')
    else:
        raise ValueError(f'unsupported texture dtype={dtype} format={fmt} mips={mips}')
    return info


def read_pack(path):
    size = path.stat().st_size
    with path.open('rb') as fh:
        header = fh.read(104)
        if len(header) != 104:
            raise ValueError('truncated PCK header')
        magic, version, major, minor, patch, flags, base, directory = struct.unpack_from('<6I2Q', header)
        if (magic, version, major, minor, patch) != (0x43504447, 3, 4, 5, 1) or flags & ~2 or directory >= size:
            raise ValueError('unsupported PCK header')
        fh.seek(directory)
        raw = fh.read(4)
        if len(raw) != 4:
            raise ValueError('truncated PCK directory')
        count, = struct.unpack('<I', raw)
        if count > 1000000:
            raise ValueError('invalid PCK directory count')
        entries = {}
        for _ in range(count):
            b = fh.read(4)
            if len(b) != 4:
                raise ValueError('truncated PCK directory')
            n, = struct.unpack('<I', b)
            if not 0 < n <= 16384:
                raise ValueError('invalid PCK path length')
            name = fh.read(n).rstrip(b'\0').decode('utf-8')
            fields = fh.read(36)
            if len(fields) != 36:
                raise ValueError('truncated PCK entry')
            off, length, md5, eflags = struct.unpack('<QQ16sI', fields)
            off += base if flags & 2 else 0
            if name.startswith('res://'):
                name = name[6:]
            if not name or name.startswith('/') or '..' in Path(name).parts or name in entries or eflags or off + length > size:
                raise ValueError(f'unsupported PCK entry {name!r}')
            entries[name] = (off, length, md5.hex())
    return entries


def entry_bytes(fh, entry):
    off, size, md5 = entry
    fh.seek(off)
    data = fh.read(size)
    if len(data) != size or digest(data, 'md5') != md5:
        raise ValueError('source entry MD5 mismatch')
    return data


def import_map(fh, entries):
    result = {}
    spine_dirs = set()
    bitmap_font_dirs = {str(Path(name).parent) for name in entries
                        if name.endswith(('.fnt', '.fnt.import', '.fontdata.import'))}
    for name, entry in entries.items():
        if not name.endswith('.import'):
            continue
        data = entry_bytes(fh, entry).decode('utf-8')
        if name.endswith('.atlas.import'):
            spine_dirs.add(str(Path(name).parent))
        source = re.search(r'^source_file="res://([^"\n]+)"', data, re.M)
        targets = re.findall(r'"res://(\.godot/imported/[^"\n]+\.ctex)"', data)
        if not targets:
            continue
        if not source:
            raise ValueError(f'missing texture source_file in {name}')
        for target in targets:
            identity = (source.group(1), data)
            if target in result and result[target] != identity:
                raise ValueError(f'ambiguous import mapping {target}')
            result[target] = identity
    # Godot exports can include a WebP sibling whose source import selects
    # the ASTC variant. The shared imported basename and 128-bit source-path
    # hash identify the same source; never guess across different hashes.
    for target, identity in list(result.items()):
        match = re.fullmatch(r'(.+-[0-9a-f]{32})(?:\.astc)?\.ctex', target)
        if not match:
            continue
        stem = match.group(1)
        for sibling in (stem + '.ctex', stem + '.astc.ctex'):
            if sibling not in entries:
                continue
            if sibling in result and result[sibling] != identity:
                raise ValueError(f'ambiguous sibling import mapping {sibling}')
            if sibling not in result:
                result[sibling] = identity
    return result, spine_dirs, bitmap_font_dirs


def in_directory(source, directory):
    if directory == '.':
        return '/' not in source
    return source == directory or source.startswith(directory + '/')


def is_spine_source(source, spine_dirs):
    lower = source.lower()
    return any(in_directory(source, directory) for directory in spine_dirs) or bool(re.search(r'(^|[/_.-])(spine|spines)([/_.-]|$)', lower))


def protected(name, mapping, spine_dirs, bitmap_font_dirs=(), allow_spine=False):
    if name not in mapping:
        return 'missing source import mapping'
    source, data = mapping[name]
    lower = source.lower()
    if re.search(r'(^|[/_.-])(font|fonts|bitmapfont|pixelfont|glyph|glyphs|charset|sdf|msdf|lut|lookup|normal|normals|normalmap|norm|nrm|roughness|metallic|metalness|heightmap|displacement|occlusion)([/_.-]|$)', lower):
        return 'font, LUT or normal/data texture'
    if any(in_directory(source, directory) for directory in bitmap_font_dirs):
        return 'bitmap font directory'
    if is_spine_source(source, spine_dirs) and not allow_spine:
        return 'Spine coordinates not yet verified'
    # Explicit normal map import: Godot 4 importer uses 1=enabled, 2=disabled.
    if re.search(r'^compress/normal_map=1\s*$', data, re.M):
        return 'normal map import'
    return None


def align(n):
    return (n + 31) & ~31


def write_pack(items, output):
    # PCK v3 relative file offsets; stream payloads rather than loading all into RAM.
    file_base = align(104)
    cursor = file_base
    directory = []
    for name, path in items:
        size = path.stat().st_size
        data_hash = hashlib.md5(path.read_bytes()).digest()
        directory.append((name, cursor - file_base, size, data_hash))
        cursor = align(cursor + size)
    dir_base = cursor
    with output.open('wb') as out:
        out.write(struct.pack('<6I2Q', 0x43504447, 3, 4, 5, 1, 2, file_base, dir_base) + bytes(64))
        out.write(bytes(file_base - out.tell()))
        for (_, path), (_, offset, _, _) in zip(items, directory):
            assert out.tell() == file_base + offset
            with path.open('rb') as fh:
                for chunk in iter(lambda: fh.read(1024 * 1024), b''):
                    out.write(chunk)
            out.write(bytes(align(out.tell()) - out.tell()))
        out.write(struct.pack('<I', len(directory)))
        for name, offset, size, md5 in directory:
            raw = ('res://' + name).encode('utf-8')
            raw += bytes((-len(raw)) % 4)
            out.write(struct.pack('<I', len(raw)) + raw + struct.pack('<QQ16sI', offset, size, md5, 0))
    return {name: md5.hex() for name, _, _, md5 in directory}


def ensure_distinct_paths(paths):
    """Reject aliases, including existing symlinks and hard links, before writes."""
    for index, first in enumerate(paths):
        for second in paths[index + 1:]:
            if first.resolve() == second.resolve() or (first.exists() and second.exists() and os.path.samefile(first, second)):
                raise ValueError(f'input, output, report and temporary output must be distinct: {first} and {second}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--godot', type=Path, required=True)
    p.add_argument('--cache', type=Path, required=True, help='private work and content-addressed conversion cache')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--report', type=Path, required=True)
    p.add_argument('--batch-size', type=int, default=512, help='maximum textures per persistent CPU worker')
    p.add_argument('--verified-spine-loader', action='store_true', help='include Spine pages after verifying that the loader uses Texture2D logical dimensions')
    args = p.parse_args()
    if args.batch_size < 1:
        p.error('batch-size must be positive')
    temp = args.output.with_name(args.output.name + '.tmp')
    ensure_distinct_paths((args.base, args.output, args.report, temp))
    args.cache.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    godot_version = subprocess.run([str(args.godot), '--version'], check=True, capture_output=True, text=True).stdout.strip()
    if not godot_version.startswith('4.5.1.stable.official'):
        raise ValueError(f'official Godot 4.5.1 required: {godot_version}')
    identity = digest((file_hash(args.godot) + file_hash(WORKER) + file_hash(Path(__file__))).encode())
    source_sha = file_hash(args.base)
    entries = read_pack(args.base)
    records = []
    jobs = []
    pending_keys = set()
    items = []
    with args.base.open('rb') as fh:
        mapping, spine_dirs, bitmap_font_dirs = import_map(fh, entries)
        names = sorted(name for name in entries if name.endswith('.ctex'))
        for index, name in enumerate(names, 1):
            if index == 1 or index % 256 == 0 or index == len(names):
                print(f'scanning {index}/{len(names)} textures; {len(items)} eligible so far', flush=True)
            raw = entry_bytes(fh, entries[name])
            record = {'path': name, 'source_md5': entries[name][2], 'source_sha256': digest(raw)}
            info = texture_header(raw)
            record['input'] = info
            reason = protected(name, mapping, spine_dirs, bitmap_font_dirs, args.verified_spine_loader)
            if info['data_format'] == 0 and info['image_format'] == 15:
                reason = 'HDR/data texture retained'
            if name in mapping:
                record['source_path'] = mapping[name][0]
                record['category'] = 'spine_page_or_neighbor' if is_spine_source(mapping[name][0], spine_dirs) else 'other_2d'
                record['mapping'] = 'exact' if f'res://{name}' in mapping[name][1] else 'same imported source hash sibling'
            if reason:
                record['skip_reason'] = reason
                records.append(record)
                continue
            info = parse_texture(raw)
            if info['mipmaps'] == 1:
                record['skip_reason'] = 'tiny mip chain retained'
                records.append(record)
                continue
            if info['gpu'] == [1, 1]:
                record['skip_reason'] = 'already 1x1'
                records.append(record)
                continue
            key = digest((identity + record['source_sha256']).encode())
            src = args.cache / (key + '.source.ctex')
            dst = args.cache / (key + '.ctex')
            checksum = args.cache / (key + '.sha256')
            if key in pending_keys:
                pass
            elif dst.exists() and checksum.exists():
                try:
                    data = dst.read_bytes()
                    if digest(data) != checksum.read_text(encoding='ascii').strip():
                        raise ValueError('cached checksum mismatch')
                    result = parse_texture(data)
                    if result['logical'] != info['logical'] or result['gpu'] != [max(1, v // 2) for v in info['gpu']] or any(result[k] != info[k] for k in ('flags', 'limit', 'data_format', 'image_format')):
                        raise ValueError('cached texture contract mismatch')
                except ValueError:
                    raise ValueError(f'corrupt cached result {dst}')
            elif info['mipmaps'] > 1:
                # The source has a complete chain; its next mip already is the
                # exact half-resolution image, including compression and alpha.
                w, h = info['gpu']
                if info['data_format'] == 0:
                    block = BLOCK[info['image_format']]
                    top_size = ((w + block - 1) // block) * ((h + block - 1) // block) * 16
                else:
                    top_size = 4 + struct.unpack_from('<I', raw, 52)[0]
                reduced = bytearray(raw[:52] + raw[52 + top_size:])
                struct.pack_into('<HHI', reduced, 40, max(1, w // 2), max(1, h // 2), info['mipmaps'] - 1)
                parse_texture(reduced)
                dst.write_bytes(reduced)
                checksum.write_text(digest(reduced) + '\n', encoding='ascii')
            else:
                src.write_bytes(raw)
                temp_dst = args.cache / (key + '.pending.ctex')
                jobs.append({'name': name, 'input': str(src.resolve()), 'output': str(temp_dst.resolve()), 'final': str(dst.resolve()), 'checksum': str(checksum.resolve())})
                pending_keys.add(key)
            record['strategy'] = 'drop highest mip' if info['mipmaps'] > 1 else 'CPU decode and resize'
            record['cache'] = str(dst)
            records.append(record)
            items.append((name, dst))
    missing = [r['path'] for r in records if 'source_path' not in r]
    if missing:
        args.report.write_text(json.dumps({'source_sha256': source_sha, 'error': 'missing source import mapping', 'unmapped_paths': missing, 'resources': records}, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        raise ValueError(f'{len(missing)} textures lack source import mappings; see {args.report}')
    for offset in range(0, len(jobs), args.batch_size):
        jobfile = args.cache / 'jobs.json'
        jobfile.write_text(json.dumps(jobs[offset:offset + args.batch_size]), encoding='utf-8')
        print(f'converting {offset + 1}-{min(offset + args.batch_size, len(jobs))}/{len(jobs)}', flush=True)
        batch = jobs[offset:offset + args.batch_size]
        command = [str(args.godot), '--headless', '--path', str(args.cache.resolve()), '--script', str(WORKER.resolve()), '--', str(jobfile.resolve())]
        completed = set()
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1) as process:
            for line in process.stdout:
                if not line.startswith('TEXTURE_DONE\t'):
                    print(line, end='', flush=True)
                    continue
                fields = line.strip().split('\t')
                if len(fields) != 3 or not fields[1].isdigit():
                    raise ValueError('invalid worker completion')
                index = int(fields[1])
                if index >= len(batch) or index in completed:
                    raise ValueError('unexpected worker completion')
                job = batch[index]
                pending = Path(job['output'])
                data = pending.read_bytes()
                parse_texture(data)
                pending.replace(job['final'])
                Path(job['checksum']).write_text(digest(data) + '\n', encoding='ascii')
                completed.add(index)
                print(f'converted {offset + index + 1}/{len(jobs)} {job["name"]} ({fields[2]} µs)', flush=True)
            code = process.wait()
        if code or len(completed) != len(batch):
            raise ValueError(f'worker failed or omitted completions ({len(completed)}/{len(batch)}, exit {code})')
    for record in records:
        if 'cache' not in record:
            continue
        data = Path(record.pop('cache')).read_bytes()
        result = parse_texture(data)
        info = record['input']
        if result['logical'] != info['logical'] or result['gpu'] != [max(1, v // 2) for v in info['gpu']] or any(result[k] != info[k] for k in ('flags', 'limit', 'data_format', 'image_format')):
            raise ValueError(f'output texture contract mismatch: {record["path"]}')
        record['output'] = result
        record['output_md5'] = digest(data, 'md5')
    if not items:
        raise ValueError('no eligible textures; refusing to publish an empty overlay')
    directory_md5 = write_pack(items, temp)
    written = read_pack(temp)
    if set(written) != set(directory_md5):
        raise ValueError('output PCK directory mismatch')
    with temp.open('rb') as packed:
        for name, entry in written.items():
            entry_bytes(packed, entry)
            if entry[2] != directory_md5[name]:
                raise ValueError(f'output PCK entry mismatch: {name}')
    for record in records:
        if 'output_md5' in record and directory_md5[record['path']] != record['output_md5']:
            raise ValueError('output directory hash mismatch')
    temp.replace(args.output)
    output_sha = file_hash(args.output)
    report = {'source_sha256': source_sha, 'output_sha256': output_sha, 'godot': godot_version, 'encoder_sha256': identity,
              'texture_count': len(records), 'converted_count': len(items),
              'verified_spine_loader': args.verified_spine_loader,
              'category_counts': {category: {'total': sum(r.get('category') == category for r in records), 'converted': sum(r.get('category') == category and 'output' in r for r in records)} for category in ('spine_page_or_neighbor', 'other_2d')},
              'mapping_counts': dict(sorted(Counter(r.get('mapping', 'missing') for r in records).items())),
              'skipped': dict(sorted(Counter(r['skip_reason'] for r in records if 'skip_reason' in r).items())),
              'input_converted_bytes': sum(r['input']['bytes'] for r in records if 'output' in r),
              'output_converted_bytes': sum(r['output']['bytes'] for r in records if 'output' in r),
              'saved_file_bytes': sum(r['input']['bytes'] - r['output']['bytes'] for r in records if 'output' in r),
              'resources': records}
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(f'Wrote {args.output}: {len(items)}/{len(records)} textures; report {args.report}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'low texture build failed: {exc}', file=sys.stderr)
        sys.exit(1)
