#!/usr/bin/env python3
# INPUT: source PCK, verified texture overlay/report and audited ASTC restoration delta/report
# OUTPUT: independent combined texture PCK and source-bound report with per-entry provenance
# POS: streaming composition before main-pack merge; never modifies inputs or device data
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import sys

import low_texture_overlay as low
import merge_texture_pck as merge
from restore_vram_texture import validate_quality

OLD_SOURCE_SHA256 = 'd220c699aa60eeb22e22aebf9e34a3f7f350b58427c979ad2ccd75c25750b528'
SPECS_SHA256 = '95d9d334bb86d2b85f4e337f54306d1b63ee621e21ae1843ffa2478ecb1805b9'
HEX = re.compile(r'[0-9a-f]{64}')


def entry_sha256(stream, entry):
    offset, size, md5 = entry
    stream.seek(offset)
    sha = hashlib.sha256()
    actual_md5 = hashlib.md5()
    remaining = size
    while remaining:
        data = stream.read(min(merge.BLOCK, remaining))
        if not data:
            raise ValueError('truncated PCK entry')
        sha.update(data)
        actual_md5.update(data)
        remaining -= len(data)
    if actual_md5.digest() != md5:
        raise ValueError('PCK entry MD5 mismatch')
    return sha.hexdigest()


def entry_header(stream, entry):
    stream.seek(entry[0])
    header = low.texture_header(stream.read(52))
    header['bytes'] = entry[1]
    return header


def combine(source, base, base_report, delta, delta_report, specs, outdir):
    supplied = [Path(x) for x in (source, base, base_report, delta, delta_report, specs)]
    if any(p.is_symlink() for p in supplied):
        raise ValueError('input files must not be symlinks')
    inputs = [p.resolve(strict=True) for p in supplied]
    if len(set(inputs)) != len(inputs):
        raise ValueError('input paths must be distinct')
    for i, a in enumerate(inputs):
        for b in inputs[i + 1:]:
            if a.samefile(b):
                raise ValueError('input files must not be aliases')
    source, base, base_report, delta, delta_report, specs = inputs
    outpath = Path(outdir).absolute()
    outdir = outpath.parent.resolve(strict=True) / outpath.name
    if outdir.exists() or outdir.is_symlink() or any(outdir == p or outdir in p.parents for p in inputs):
        raise ValueError('output directory must be new and cannot contain inputs')
    baseline = json.loads(base_report.read_text())
    restored = json.loads(delta_report.read_text())
    spec = json.loads(specs.read_text())
    source_sha = merge.sha256_file(source)
    base_sha = merge.sha256_file(base)
    delta_sha = merge.sha256_file(delta)
    if (baseline.get('source_sha256') != source_sha or baseline.get('output_sha256') != base_sha or
        restored.get('source_sha256') != source_sha or restored.get('base_texture_sha256') != base_sha or
        restored.get('old_source_sha256') != OLD_SOURCE_SHA256 or restored.get('delta_sha256') != delta_sha or
        merge.sha256_file(specs) != SPECS_SHA256 or restored.get('specs_sha256') != SPECS_SHA256 or
        restored.get('texture_report_sha256') != merge.sha256_file(base_report) or
        spec.get('old_pck_sha256') != OLD_SOURCE_SHA256 or spec.get('source_pck_sha256') != source_sha or
        spec.get('texture_overlay_sha256') != base_sha):
        raise ValueError('source, overlay or restoration identity mismatch')
    spec_by_target = {}
    for item in spec.get('resources', []):
        target = item.get('target')
        if not isinstance(target, str) or target in spec_by_target:
            raise ValueError('invalid or duplicate audited target')
        spec_by_target[target] = item
    report_targets = set()
    for item in restored.get('resources', []):
        target = item.get('target')
        audited = spec_by_target.get(target)
        if target in report_targets or audited is None:
            raise ValueError('invalid or duplicate restoration report candidate: ' + str(target))
        expected = dict(audited)
        quality = item.get('quality')
        if quality is not None:
            if audited.get('eligible') is not True:
                raise ValueError('quality result for protected candidate: ' + str(target))
            validate_quality(quality, audited['input'])
            if quality['status'] == 'quality_rejected':
                expected['retained_reasons'] = audited['retained_reasons'] + ['sampled ASTC quality threshold exceeded']
                if 'output_sha256' in item:
                    raise ValueError('quality-rejected candidate has output: ' + str(target))
        if any(k not in item or item[k] != v for k, v in expected.items()):
            raise ValueError('restoration report differs from audited candidate: ' + str(target))
        report_targets.add(target)
    if report_targets != set(spec_by_target):
        raise ValueError('restoration report candidate set differs from audited specification')
    encoder = restored.get('encoder_sha256')
    godot_sha = restored.get('godot_sha256')
    worker_sha = merge.sha256_file(Path(__file__).with_name('restore_vram_texture_worker.gd'))
    if (not isinstance(godot_sha, str) or not HEX.fullmatch(godot_sha) or
        restored.get('builder_sha256') != merge.sha256_file(Path(__file__).with_name('restore_vram_texture.py')) or
        encoder != hashlib.sha256((godot_sha + worker_sha).encode()).hexdigest()):
        raise ValueError('invalid restoration encoder identity')
    base_entries, delta_entries = merge.read_pack(base), merge.read_pack(delta)
    records = baseline.get('resources')
    if not isinstance(records, list):
        raise ValueError('invalid base texture report')
    by_path = {}
    for item in records:
        if 'output_md5' not in item:
            continue
        name = item.get('path')
        if not isinstance(name, str) or name in by_path:
            raise ValueError('invalid or duplicate base report entry')
        by_path[name] = item
    if set(by_path) != set(base_entries):
        raise ValueError('base overlay and report entries differ')
    updates = {}
    for item in restored.get('resources', []):
        if 'output_sha256' not in item:
            continue
        target = item.get('target')
        if spec_by_target[target].get('eligible') is not True:
            raise ValueError('restoration target is not eligible: ' + str(target))
        if not isinstance(target, str) or not target.startswith('res://.godot/imported/') or not target.endswith('.ctex'):
            raise ValueError('restoration targets must be imported textures')
        name = target[6:]
        if name in updates or name not in base_entries or name not in delta_entries:
            raise ValueError('duplicate or unknown restoration target')
        old = by_path[name]
        if old.get('kind') != 'texture' or old.get('source_path') != item.get('source', '')[6:]:
            raise ValueError('restoration source path differs from base')
        if (item.get('source_md5') != old.get('source_md5') or item.get('source_sha256') != old.get('source_sha256') or
            item.get('installed_md5') != old.get('output_md5') or item.get('input') != old.get('output')):
            raise ValueError('restoration input differs from base report')
        if item.get('old_sibling_sha256') != item.get('source_sha256') or not all(
                isinstance(item.get(k), str) and HEX.fullmatch(item[k]) for k in ('old_selected_sha256', 'old_import_sha256')):
            raise ValueError('old selected import or identical source evidence missing')
        after = item.get('output')
        before = item['input']
        if not isinstance(after, dict) or any(after.get(k) != before.get(k) for k in ('logical', 'gpu', 'flags', 'limit', 'mipmaps')):
            raise ValueError('restoration changed texture dimensions or flags')
        if before.get('data_format') != 2 or before.get('image_format') not in (4, 5) or after.get('data_format') != 0 or after.get('image_format') != 35:
            raise ValueError('unsupported restoration texture format')
        if item.get('retained_reasons'):
            raise ValueError('protected texture was marked restored')
        quality = item.get('quality')
        validate_quality(quality, before)
        if not isinstance(quality, dict) or quality.get('status') != 'accepted' or quality.get('output_sha256') != item.get('output_sha256'):
            raise ValueError('missing restoration quality evidence')
        if item.get('installed_md5') != base_entries[name][2].hex() or item.get('output_md5') != delta_entries[name][2].hex():
            raise ValueError('restoration entry MD5 differs from report')
        updates[name] = item
    if not updates or len(updates) != restored.get('accepted_count') or set(updates) != set(delta_entries):
        raise ValueError('restoration delta and report entries differ')
    with base.open('rb') as original, delta.open('rb') as replacement:
        for name, item in updates.items():
            if entry_sha256(original, base_entries[name]) != item.get('base_entry_sha256') or entry_sha256(replacement, delta_entries[name]) != item.get('output_sha256'):
                raise ValueError('restoration entry SHA-256 mismatch: ' + name)
            if entry_header(original, base_entries[name]) != item['input'] or entry_header(replacement, delta_entries[name]) != item['output']:
                raise ValueError('restoration header differs from report: ' + name)
            after = item['output']
            w, h = after['gpu']
            mips = after['mipmaps']
            if mips and mips != max(w, h).bit_length() - 1:
                raise ValueError('incomplete restoration mip chain')
            size = sum(((max(1, w >> level) + 3) // 4) * ((max(1, h >> level) + 3) // 4) * 16
                       for level in range(mips + 1))
            if after['bytes'] != 52 + size:
                raise ValueError('restoration ASTC payload length mismatch')
    outdir.mkdir(parents=True)
    adapter = outdir / 'merge-input.json'
    adapter.write_text(json.dumps({'source_sha256': base_sha, 'output_sha256': delta_sha,
                                   'resources': [{'path': n, 'output_md5': v['output_md5']} for n, v in sorted(updates.items())]}) + '\n')
    merged = merge.prepare(base, delta, adapter, outdir / 'packs')
    report = copy.deepcopy(baseline)
    for item in report['resources']:
        new = updates.get(item.get('path'))
        if new is not None:
            item['output'] = new['output']
            item['output_format'] = new['output']['image_format']
            item['output_md5'] = new['output_md5']
            item['output_sha256'] = new['output_sha256']
            item['strategy'] = new['strategy']
            item['vram_restoration'] = {'old_source_sha256': OLD_SOURCE_SHA256, 'quality': new.get('quality')}
    report['output_sha256'] = merged.stem
    report['base_encoder_sha256'] = baseline.get('encoder_sha256')
    report['encoder_sha256'] = hashlib.sha256(('vram-restore-v1:' + str(baseline.get('encoder_sha256')) + ':' + encoder).encode()).hexdigest()
    report['vram_restoration'] = {'old_source_sha256': OLD_SOURCE_SHA256, 'base_texture_sha256': base_sha,
                                  'delta_sha256': delta_sha, 'delta_report_sha256': merge.sha256_file(delta_report),
                                  'specs_sha256': SPECS_SHA256, 'encoder_sha256': encoder, 'accepted_count': len(updates)}
    (outdir / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'combined_pck': str(merged), 'report': str(outdir / 'report.json'), 'sha256': merged.stem}))
    return merged


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'base', 'base-report', 'delta', 'delta-report', 'specs', 'output-dir'):
        p.add_argument('--' + name, required=True, type=Path)
    a = p.parse_args()
    combine(a.source, a.base, a.base_report, a.delta, a.delta_report, a.specs, a.output_dir)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.exit('texture composition failed: ' + str(exc))
