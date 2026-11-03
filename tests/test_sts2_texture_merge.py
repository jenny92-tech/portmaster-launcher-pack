# INPUT:  synthetic Godot 4.5.1 source and reviewed texture overlay PCKs
# OUTPUT: merge integrity, rejection, determinism, and Godot loading regressions
# POS:    isolated temporary fixtures; never reads player assets or devices
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace
from sts2_test_inputs import external_file

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'ports/sts2/src/tools/godot_pck/merge_texture_pck.py'
OVERLAY_TOOL = ROOT / 'ports/sts2/src/tools/godot_pck/low_texture_overlay.py'
spec = importlib.util.spec_from_file_location('low_texture_overlay_fixture', OVERLAY_TOOL)
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class TextureMergeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.pck'
        self.overlay = self.root / 'overlay.pck'
        self.report = self.root / 'report.json'
        self.out = self.root / 'out'
        self.texture = '.godot/imported/page.png-0123456789abcdef0123456789abcdef.ctex'
        self.original = {self.texture: b'original texture bytes\x00\xff', 'data/opaque.bin': bytes(range(256)) * 19, 'project.binary': b'opaque project\x00\xff'}
        self.replacement = b'replacement texture bytes\x00\xfe'
        self.write_pack(self.source, self.original)
        self.write_pack(self.overlay, {self.texture: self.replacement})
        self.write_report()

    def write_pack(self, target, entries):
        items = []
        for index, (name, content) in enumerate(entries.items()):
            path = self.root / f'payload-{target.stem}-{index}'
            path.write_bytes(content)
            items.append((name, path))
        pack.write_pack(items, target)

    def write_report(self, resources=None):
        if resources is None:
            resources = [{'path': self.texture, 'output_md5': hashlib.md5(self.replacement).hexdigest()}]
        self.report.write_text(json.dumps({'source_sha256': sha(self.source), 'output_sha256': sha(self.overlay), 'resources': resources}))

    def run_merge(self, output=None):
        return subprocess.run([sys.executable, str(TOOL), '--source', str(self.source), '--overlay', str(self.overlay), '--report', str(self.report), '--output-dir', str(output or self.out)], capture_output=True, text=True)

    def assert_rejected(self):
        source_before = self.source.read_bytes()
        overlay_before = self.overlay.read_bytes()
        result = self.run_merge()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.source.read_bytes(), source_before)
        self.assertEqual(self.overlay.read_bytes(), overlay_before)
        self.assertEqual(list(self.out.glob('*.pck')), [])

    def merged(self, output=None):
        output = output or self.out
        result = self.run_merge(output)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        paths = list(output.glob('*.pck'))
        self.assertEqual(len(paths), 1)
        result_path = paths[0]
        digest = sha(result_path)
        self.assertEqual(result_path.name, digest + '.pck')
        sidecar = output / (digest + '.json')
        self.assertTrue(sidecar.is_file())
        metadata = json.loads(sidecar.read_text())
        self.assertEqual(metadata['source_sha256'], sha(self.source))
        self.assertEqual(metadata['overlay_sha256'], sha(self.overlay))
        self.assertEqual(metadata['merged_sha256'], digest)
        for name in ('source_stat', 'merged_stat'):
            self.assertEqual(metadata[name]['size'], {'source_stat': self.source, 'merged_stat': result_path}[name].stat().st_size)
            self.assertEqual(set(metadata[name]), {'size', 'mtime_ns'})
        return result_path, sidecar

    def test_replaces_only_reviewed_texture_and_is_deterministic(self):
        result, sidecar = self.merged()
        entries = pack.read_pack(result)
        self.assertEqual(set(entries), set(self.original))
        with result.open('rb') as fh:
            for name, original in self.original.items():
                self.assertEqual(pack.entry_bytes(fh, entries[name]), self.replacement if name == self.texture else original)
        second, second_sidecar = self.merged(self.root / 'second')
        self.assertEqual(result.read_bytes(), second.read_bytes())
        first_meta, second_meta = json.loads(sidecar.read_text()), json.loads(second_sidecar.read_text())
        for key in ('source_sha256', 'overlay_sha256', 'merged_sha256'):
            self.assertEqual(first_meta[key], second_meta[key])

    def test_rejects_wrong_hashes_and_unreviewed_resources(self):
        for mutation in ('source_hash', 'overlay_hash', 'missing', 'wrong_md5', 'extra', 'duplicate'):
            with self.subTest(mutation=mutation):
                data = json.loads(self.report.read_text())
                if mutation == 'source_hash': data['source_sha256'] = '0' * 64
                if mutation == 'overlay_hash': data['output_sha256'] = '0' * 64
                if mutation == 'missing': data['resources'] = []
                if mutation == 'wrong_md5': data['resources'][0]['output_md5'] = '0' * 32
                if mutation == 'extra': data['resources'].append({'path': 'missing.ctex', 'output_md5': '0' * 32})
                if mutation == 'duplicate': data['resources'].append(data['resources'][0].copy())
                self.report.write_text(json.dumps(data))
                self.assert_rejected()
                self.write_report()

    def test_rejects_non_texture_and_missing_source_entry(self):
        for name in ('data/opaque.bin', 'missing.ctex'):
            with self.subTest(name=name):
                self.write_pack(self.overlay, {name: self.replacement})
                self.write_report([{'path': name, 'output_md5': hashlib.md5(self.replacement).hexdigest()}])
                self.assert_rejected()

    def test_rejects_damaged_header_and_payload_md5(self):
        for target in (self.source, self.overlay):
            original = target.read_bytes()
            for kind in ('header', 'payload'):
                with self.subTest(target=target.name, kind=kind):
                    data = bytearray(original)
                    offset = 0 if kind == 'header' else next(iter(pack.read_pack(target).values()))[0]
                    data[offset] ^= 1
                    target.write_bytes(data)
                    # Bind the report to corrupted bytes so the internal PCK check is exercised.
                    self.write_report()
                    self.assert_rejected()
                    target.write_bytes(original)
            self.write_report()

    def test_rejects_directory_outside_file(self):
        for target in (self.source, self.overlay):
            with self.subTest(target=target.name):
                original = target.read_bytes()
                damaged = bytearray(original)
                damaged[32:40] = (len(damaged) + 100).to_bytes(8, 'little')
                target.write_bytes(damaged)
                self.write_report()
                self.assert_rejected()
                target.write_bytes(original)
                self.write_report()

    def test_replaced_source_entry_checksum_is_verified(self):
        raw = bytearray(self.source.read_bytes())
        offset = pack.read_pack(self.source)[self.texture][0]
        raw[offset] ^= 1
        self.source.write_bytes(raw)
        self.write_report()
        self.assert_rejected()

    def test_insufficient_space_does_not_publish(self):
        merge_spec = importlib.util.spec_from_file_location('merge_fixture', TOOL)
        merge = importlib.util.module_from_spec(merge_spec)
        merge_spec.loader.exec_module(merge)
        with mock.patch.object(merge.shutil, 'disk_usage', return_value=SimpleNamespace(free=0)):
            with self.assertRaisesRegex(ValueError, 'insufficient free space'):
                merge.prepare(self.source, self.overlay, self.report, self.out)
        self.assertEqual(list(self.out.glob('*.pck')), [])
        self.assertEqual(list(self.out.glob('*.incoming')), [])

    def test_sidecar_write_failure_does_not_publish_new_pack(self):
        merge_spec = importlib.util.spec_from_file_location('merge_failure_fixture', TOOL)
        merge = importlib.util.module_from_spec(merge_spec)
        merge_spec.loader.exec_module(merge)
        with mock.patch.object(merge.os, 'replace', side_effect=OSError('fixture write failure')):
            with self.assertRaisesRegex(OSError, 'fixture write failure'):
                merge.prepare(self.source, self.overlay, self.report, self.out)
        self.assertEqual(list(self.out.glob('*.pck')), [])
        self.assertEqual(list(self.out.glob('*.json')), [])
        self.assertEqual(list(self.out.glob('*.incoming')), [])

    def test_sidecar_write_failure_preserves_existing_pack(self):
        existing, sidecar = self.merged()
        original, original_sidecar = existing.read_bytes(), sidecar.read_bytes()
        merge_spec = importlib.util.spec_from_file_location('merge_existing_fixture', TOOL)
        merge = importlib.util.module_from_spec(merge_spec)
        merge_spec.loader.exec_module(merge)
        with mock.patch.object(merge.os, 'replace', side_effect=OSError('fixture write failure')):
            with self.assertRaisesRegex(OSError, 'fixture write failure'):
                merge.prepare(self.source, self.overlay, self.report, self.out)
        self.assertEqual(existing.read_bytes(), original)
        self.assertEqual(sidecar.read_bytes(), original_sidecar)
        self.assertEqual(list(self.out.glob('*.incoming')), [])

    def test_existing_output_alias_cannot_modify_input(self):
        result, _ = self.merged(self.root / 'known')
        name = result.name
        self.out.mkdir()
        for kind in ('symlink', 'hardlink'):
            alias = self.out / name
            if kind == 'symlink': alias.symlink_to(self.source)
            else: os.link(self.source, alias)
            original = self.source.read_bytes()
            result = self.run_merge()
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.source.read_bytes(), original)
            alias.unlink()

    def test_godot_loads_merged_opaque_and_replacement_resources(self):
        GODOT=external_file(self,'STS2_TEST_GODOT')
        result, _ = self.merged()
        (self.root / 'project.godot').write_text('[application]\nconfig/name="merge fixture"\n')
        script = self.root / 'verify.gd'
        script.write_text('''extends SceneTree
func _initialize():
    var args = OS.get_cmdline_user_args()
    if not ProjectSettings.load_resource_pack(args[0]):
        quit(1)
        return
    var expected = {args[1]: args[2], "data/opaque.bin": args[3], "project.binary": args[4]}
    for path in expected:
        if not FileAccess.file_exists("res://" + path):
            quit(2)
            return
        var data = FileAccess.get_file_as_bytes("res://" + path)
        if data.hex_encode() != expected[path]:
            quit(3)
            return
    print("merged resources OK")
    quit(0)
''')
        run = subprocess.run([str(GODOT), '--headless', '--path', str(self.root), '--script', str(script), '--', str(result), self.texture, self.replacement.hex(), self.original['data/opaque.bin'].hex(), self.original['project.binary'].hex()], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('merged resources OK', run.stdout)


if __name__ == '__main__':
    unittest.main()
