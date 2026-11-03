#!/usr/bin/env python3
# INPUT: verified 3ab main PCK, its six common and three SC FontFiles, official Godot
# OUTPUT: isolated six-font fallback delta and localization coverage evidence
# POS: Chinese-only host experiment; no deployment, runtime hook or default policy
import argparse
import hashlib
import json
import os
import subprocess
import unicodedata
from pathlib import Path

import low_texture_overlay as low
import strip_common_font_cache as fonts
import strip_font_cache as sc_fonts

MAIN_SHA = '3abccf4a75ea347b0d4cece05d376beeaf42b4f34a3af1ccc17644bd2762203d'
GODOT_SHA = '0d214c6c85e47e7060ac13b035b404ce4dda653992503914963e149a45cd0dca'
SC_DATA = {
    'SourceHanSerifSC-Bold': '4564e8fb84d572e0b8b4e2980f3e23efc0c9956e64c84affce715a6de77cee27',
    'SourceHanSerifSC-Medium': '210dc788c6cc15ed693c8ecde93ee83bf7714b759befa6aead042d6f6e1b878a',
    'NotoSansMonoCJKsc-Regular': '2b1dbdc50df666a00c50ecd77377e2394c6babd35a71e37505ab411ff55c7906',
}
MAPPING = {
    'bitter_medium_italic': 'SourceHanSerifSC-Medium',
    'kreon_bold': 'SourceHanSerifSC-Bold',
    'kreon_regular': 'SourceHanSerifSC-Medium',
    'source_code_pro_medium': 'NotoSansMonoCJKsc-Regular',
    'source_code_pro_semibold': 'NotoSansMonoCJKsc-Regular',
    'spectral_bold': 'SourceHanSerifSC-Bold',
}
WORKER = Path(__file__).with_suffix('.gd')


def collect_strings(value, codepoints):
    if isinstance(value, str):
        codepoints.update(map(ord, value))
    elif isinstance(value, dict):
        for child in value.values(): collect_strings(child, codepoints)
    elif isinstance(value, list):
        for child in value: collect_strings(child, codepoints)


def matching(names, prefix):
    found = [name for name in names if name.startswith(prefix + '.')]
    if len(found) != 1: raise ValueError('unexpected font identity: ' + prefix)
    return found[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('base-main', 'godot', 'work-dir', 'output', 'report'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    low.ensure_distinct_paths((args.base_main, args.godot, args.output, args.report))
    if any(path.exists() or path.is_symlink() for path in (args.work_dir, args.output, args.report)):
        raise ValueError('fresh work, output and report paths required')
    if low.file_hash(args.base_main) != MAIN_SHA or low.file_hash(args.godot) != GODOT_SHA:
        raise ValueError('base PCK or official Godot identity mismatch')
    version = subprocess.run([str(args.godot), '--version'], capture_output=True, text=True, check=True).stdout.strip()
    if not version.startswith('4.5.1.stable.official'): raise ValueError('unexpected Godot version')

    os.umask(0o077)
    args.work_dir.mkdir(parents=True, mode=0o700)
    project = args.work_dir / 'project'
    imported = project / '.godot' / 'imported'
    imported.mkdir(parents=True)
    (project / 'project.godot').write_text('[application]\nconfig/name="Isolated font fallback trial"\n')
    index = low.read_pack(args.base_main)
    identity = fonts.COMMON_OUTPUTS | fonts.SC_OUTPUTS
    locale_files = sorted(path for path in index if path.startswith('localization/zhs/') and path.endswith('.json'))
    if len(locale_files) != 46: raise ValueError('unexpected simplified-Chinese localization file count')
    codepoints = set()
    locale_identities = []
    with args.base_main.open('rb') as stream:
        for name, expected in identity.items():
            entry = '.godot/imported/' + name
            if entry not in index: raise ValueError('missing font: ' + entry)
            data = low.entry_bytes(stream, index[entry])
            if hashlib.sha256(data).hexdigest() != expected: raise ValueError('font input hash mismatch: ' + entry)
            (imported / name).write_bytes(data)
        for name in fonts.SC_OUTPUTS:
            import_path = sc_fonts.FONTS[name][0]
            data = low.entry_bytes(stream, index[import_path])
            destination = project / import_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        for path in locale_files:
            data = low.entry_bytes(stream, index[path])
            locale_identities.append({'path': path, 'sha256': hashlib.sha256(data).hexdigest()})
            collect_strings(json.loads(data.decode('utf-8-sig')), codepoints)
    skipped = sorted(cp for cp in codepoints if unicodedata.category(chr(cp)) in ('Cc', 'Cf'))
    printable = sorted(codepoints.difference(skipped))
    if not printable: raise ValueError('empty localization corpus')

    manifest = {'codepoints': printable, 'fonts': []}
    for number, (prefix, fallback_prefix) in enumerate(MAPPING.items()):
        common = matching(fonts.COMMON_OUTPUTS, prefix)
        sc = matching(fonts.SC_OUTPUTS, fallback_prefix)
        source_path = sc_fonts.FONTS[sc][0].removesuffix('.import')
        manifest['fonts'].append({'original': 'res://.godot/imported/' + common,
            'fallback': 'res://' + source_path, 'output': 'res://candidate-' + str(number) + '.res',
            'original_data_sha256': fonts.COMMON[common][2], 'fallback_data_sha256': SC_DATA[fallback_prefix]})
    manifest_path = project / 'manifest.json'
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=True))
    command = [str(args.godot.resolve()), '--headless', '--path', str(project.resolve()),
               '--script', str(WORKER.resolve()), '--', str(manifest_path.resolve())]
    run = subprocess.run(command, capture_output=True, text=True, timeout=300)
    rows = [line.partition('\t')[2] for line in run.stdout.splitlines() if line.startswith('FONT_FALLBACK_RESULT\t')]
    if run.returncode or len(rows) != 1:
        raise RuntimeError('Godot fallback worker failed: ' + run.stdout + '\n' + run.stderr)
    result = json.loads(rows[0])
    if len(result.get('resources', [])) != 6: raise ValueError('incomplete fallback results')
    for item in manifest['fonts']:
        for order in ('eager', 'preload'):
            eager = subprocess.run(command[:-1] + [order, item['output'], item['fallback']],
                                   capture_output=True, text=True, timeout=30)
            if eager.returncode or 'FONT_FALLBACK_EAGER_OK' not in eager.stdout:
                raise RuntimeError('fresh-process cache identity check failed: ' + eager.stdout + '\n' + eager.stderr)
    entries = []
    for item, result_item in zip(manifest['fonts'], result['resources']):
        file = project / item['output'].removeprefix('res://')
        original_file = project / item['original'].removeprefix('res://')
        if not file.is_file() or file.stat().st_size > original_file.stat().st_size + 8192:
            raise ValueError('candidate missing or unexpectedly bundled a large dependency')
        if result_item['original'] != item['original'] or result_item['fallback'] != item['fallback']:
            raise ValueError('result identity mismatch')
        result_item['output_sha256'] = low.file_hash(file)
        result_item['output_bytes'] = file.stat().st_size
        entries.append((item['original'].removeprefix('res://'), file))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    staged_output = args.work_dir / 'verified-delta.pck'
    staged_report = args.work_dir / 'verified-report.json'
    low.write_pack(sorted(entries), staged_output)
    overlay = low.read_pack(staged_output)
    if set(overlay) != {item[0] for item in entries}: raise ValueError('unexpected delta members')
    with staged_output.open('rb') as stream:
        for item, result_item in zip(manifest['fonts'], result['resources']):
            path = item['original'].removeprefix('res://')
            if hashlib.sha256(low.entry_bytes(stream, overlay[path])).hexdigest() != result_item['output_sha256']:
                raise ValueError('overlay entry mismatch')
    report = {'base_main_sha256': MAIN_SHA, 'delta_sha256': low.file_hash(staged_output),
        'godot_sha256': GODOT_SHA, 'godot_version': version, 'builder_sha256': low.file_hash(Path(__file__)),
        'worker_sha256': low.file_hash(WORKER), 'locale_files': locale_identities,
        'unique_localization_codepoints': len(codepoints), 'examined_codepoints': len(printable),
        'all_six_eager_loading_verified': True,
        'canonical_source_cache_identity_both_orders_verified': True,
        'control_or_format_codepoints_skipped': skipped, 'resources': result['resources'],
        'limitations': ['Chinese-only experiment: external fallbacks load eagerly even in English.',
            'System fallback remains enabled for characters missing from both selected fonts.',
            'ThemeDB default font and other fonts may bypass these six resources.',
            'Coverage checks codepoints, not shaping sequences, runtime-generated text or device visuals.']}
    staged_report.write_text(json.dumps(report, ensure_ascii=True, indent=2) + '\n')
    staged_output.replace(args.output)
    staged_report.replace(args.report)
    print('Wrote isolated delta', args.output, 'sha256', report['delta_sha256'])


if __name__ == '__main__': main()
