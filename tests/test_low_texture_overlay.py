#!/usr/bin/env python3
# INPUT:  unittest、Godot 4.5.1 与低清纹理覆盖构建器
# OUTPUT: GST2 格式拒绝、合成 PCK 构建与原生纹理坐标回归
# POS:    验证资源压缩和逻辑尺寸保留契约
import importlib.util
import json
import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from sts2_test_inputs import external_file

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'ports/sts2/src/tools/godot_pck/low_texture_overlay.py'
FIXTURE = ROOT / 'tests/sts2_low_texture_fixture.gd'
spec = importlib.util.spec_from_file_location('low_texture_overlay', TOOL)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LowTextureTest(unittest.TestCase):
    def test_rejects_unknown_or_truncated_texture(self):
        for raw in [b'GST2', bytes(52), b'GST2' + bytes(48)]:
            with self.assertRaises(ValueError):
                module.parse_texture(raw)

    def test_temporary_output_cannot_alias_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / 'source.pck.tmp'
            original = b'player-owned original package'
            base.write_bytes(original)
            output = root / 'source.pck'
            report = root / 'report.json'
            def run():
                return subprocess.run(['python3', str(TOOL), '--base', str(base), '--godot', str(root / 'unused-godot'), '--cache', str(root / 'cache'), '--output', str(output), '--report', str(report)], capture_output=True, text=True)
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('must be distinct', result.stderr)
            self.assertEqual(base.read_bytes(), original)
            # Alias a different source path through a symlink, then a hard link.
            moved = root / 'actual.pck'
            base.rename(moved)
            base.symlink_to(moved)
            for alias in ('symlink', 'hardlink'):
                if alias == 'hardlink':
                    base.unlink()
                    os.link(moved, base)
                result = subprocess.run(['python3', str(TOOL), '--base', str(moved), '--godot', str(root / 'unused-godot'), '--cache', str(root / 'cache'), '--output', str(output), '--report', str(report)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, alias)
                self.assertIn('must be distinct', result.stderr)
                self.assertEqual(moved.read_bytes(), original)

    def test_texture_validation_and_protection(self):
        header = bytearray(52)
        header[:4] = b'GST2'
        struct.pack_into('<5I', header, 4, 1, 8, 8, 0x0c000000, 0xffffffff)
        struct.pack_into('<IHHII', header, 36, 0, 8, 8, 0, 37)
        raw = bytes(header) + bytes(16)
        self.assertEqual(module.parse_texture(raw)['gpu'], [8, 8])
        with self.assertRaisesRegex(ValueError, 'length'):
            module.parse_texture(raw[:-1])
        header[19] |= 0x20
        with self.assertRaisesRegex(ValueError, 'flags'):
            module.parse_texture(bytes(header) + bytes(16))
        mapping = {'tex': ('animations/monster/page.png', '')}
        self.assertEqual(module.protected('tex', mapping, {'animations/monster'}), 'Spine coordinates not yet verified')
        self.assertIsNone(module.protected('tex', mapping, {'animations/monster'}, allow_spine=True))
        self.assertEqual(module.protected('tex', mapping, set(), {'animations/monster'}, allow_spine=True), 'bitmap font directory')
        self.assertEqual(module.protected('missing', mapping, set()), 'missing source import mapping')
        self.assertIsNotNone(module.protected('tex', {'tex': ('art/lut_light.png', '')}, set()))
        self.assertIsNotNone(module.protected('tex', {'tex': ('art/a.png', 'compress/normal_map=1\n')}, set()))

    def test_same_hash_import_sibling_and_ambiguity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stem = '.godot/imported/page.png-' + 'a' * 32
            meta = root / 'page.import'
            meta.write_text('[remap]\npath.astc="res://' + stem + '.astc.ctex"\n[deps]\nsource_file="res://art/page.png"\n')
            content = root / 'content'
            content.write_bytes(b'test')
            base = root / 'base.pck'
            module.write_pack([(stem + '.astc.ctex', content), (stem + '.ctex', content), ('art/page.png.import', meta)], base)
            entries = module.read_pack(base)
            with base.open('rb') as fh:
                mapping, _, _ = module.import_map(fh, entries)
            self.assertEqual(mapping[stem + '.ctex'][0], 'art/page.png')
            self.assertNotIn(stem + '.ctex', mapping[stem + '.ctex'][1])
            other = root / 'other.import'
            other.write_text('[remap]\npath="res://' + stem + '.ctex"\n[deps]\nsource_file="res://art/other.png"\n')
            module.write_pack([(stem + '.astc.ctex', content), (stem + '.ctex', content), ('art/page.png.import', meta), ('art/other.png.import', other)], base)
            entries = module.read_pack(base)
            with base.open('rb') as fh, self.assertRaisesRegex(ValueError, 'ambiguous sibling'):
                module.import_map(fh, entries)

    def test_native_conversion_and_atlas(self):
        GODOT=external_file(self,'STS2_TEST_GODOT')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'project.godot').write_text('[application]\nconfig/name="fixture"\n')
            command = [str(GODOT), '--headless', '--path', str(root), '--script', str(FIXTURE), '--']
            subprocess.run(command + ['generate', str(root)], check=True, capture_output=True, text=True)
            items = []
            for name in ['astc.ctex', 'mips.ctex', 'webp.ctex', 'webp_mips.ctex']:
                items.append((name, root / name))
                meta = root / (name + '.import')
                meta.write_text('[remap]\npath="res://.godot/imported/' + name + '"\n[deps]\nsource_file="res://art/' + name + '.png"\n')
                items.append((name + '.import', meta))
            # A duplicate source exercises content-addressed job deduplication.
            duplicate_meta = root / 'duplicate.ctex.import'
            duplicate_meta.write_text('[remap]\npath="res://.godot/imported/duplicate.ctex"\n[deps]\nsource_file="res://animations/monster/duplicate.png"\n')
            atlas_meta = root / 'spine.atlas.import'
            atlas_meta.write_text('[remap]\nimporter="spine.atlas"\n')
            items.extend([('duplicate.ctex', root / 'astc.ctex'), ('duplicate.ctex.import', duplicate_meta), ('animations/monster/spine.atlas.import', atlas_meta)])
            # Use actual imported paths in the PCK, matching the .import mapping.
            items = [('.godot/imported/' + n if n.endswith('.ctex') else n, path) for n, path in items]
            base = root / 'base.pck'
            module.write_pack(items, base)
            output, report = root / 'overlay.pck', root / 'report.json'
            subprocess.run(['python3', str(TOOL), '--base', str(base), '--godot', str(GODOT), '--cache', str(root / 'cache'), '--output', str(output), '--report', str(report)], check=True, text=True)
            data = json.loads(report.read_text())
            self.assertEqual(data['source_sha256'], module.file_hash(base))
            self.assertEqual(data['output_sha256'], module.file_hash(output))
            self.assertEqual(data['converted_count'], 4)
            self.assertEqual(data['skipped'], {'Spine coordinates not yet verified': 1})
            subprocess.run(['python3', str(TOOL), '--base', str(base), '--godot', str(GODOT), '--cache', str(root / 'cache'), '--output', str(output), '--report', str(report), '--verified-spine-loader'], check=True, text=True)
            data = json.loads(report.read_text())
            self.assertEqual(data['output_sha256'], module.file_hash(output))
            self.assertEqual(data['converted_count'], 5)
            self.assertEqual(data['category_counts']['spine_page_or_neighbor'], {'total': 1, 'converted': 1})
            self.assertEqual(data['skipped'], {})
            entries = module.read_pack(output)
            with output.open('rb') as fh:
                for name, entry in entries.items():
                    raw = module.entry_bytes(fh, entry)
                    info = module.parse_texture(raw)
                    self.assertEqual(info['logical'], [260, 150])
                    self.assertEqual(info['gpu'], [132, 76])
                    (root / Path(name).name).write_bytes(raw)
            result = subprocess.run(command + ['verify', str(output)], check=True, capture_output=True, text=True)
            self.assertIn('logical and atlas sizes OK', result.stdout)
            # Cached rerun produces the same PCK and directory hashes.
            original = output.read_bytes()
            subprocess.run(['python3', str(TOOL), '--base', str(base), '--godot', str(GODOT), '--cache', str(root / 'cache'), '--output', str(output), '--report', str(report), '--verified-spine-loader'], check=True, text=True)
            self.assertEqual(output.read_bytes(), original)
            checksum = next((root / 'cache').glob('*.sha256'))
            checksum.write_text('0' * 64)
            failure = subprocess.run(['python3', str(TOOL), '--base', str(base), '--godot', str(GODOT), '--cache', str(root / 'cache'), '--output', str(output), '--report', str(report)], capture_output=True, text=True)
            self.assertNotEqual(failure.returncode, 0)
            self.assertIn('corrupt cached result', failure.stderr)
            unmapped_base = root / 'unmapped.pck'
            unmapped_output, unmapped_report = root / 'unmapped-overlay.pck', root / 'unmapped-report.json'
            module.write_pack([('.godot/imported/unmapped.ctex', root / 'astc.ctex')], unmapped_base)
            failed = subprocess.run(['python3', str(TOOL), '--base', str(unmapped_base), '--godot', str(GODOT), '--cache', str(root / 'other-cache'), '--output', str(unmapped_output), '--report', str(unmapped_report)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse(unmapped_output.exists())
            self.assertEqual(json.loads(unmapped_report.read_text())['error'], 'missing source import mapping')


if __name__ == '__main__':
    unittest.main()
