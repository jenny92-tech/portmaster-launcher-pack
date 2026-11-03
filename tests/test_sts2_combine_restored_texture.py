# INPUT: synthetic source, reviewed candidates and texture overlay/delta PCKs
# OUTPUT: source/spec/quality binding and fail-closed composition regression
# POS: offline temporary fixtures; never reads player files or devices
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ports/sts2/src/tools/godot_pck'))
import low_texture_overlay as low
import combine_restored_texture as combine


def digest(data):
    return hashlib.sha256(data).hexdigest()


def texture(dtype, fmt, payload):
    return (b'GST2' + struct.pack('<5I', 1, 8, 8, 0, 0xffffffff) + bytes(12)
            + struct.pack('<IHHII', dtype, 4, 4, 0, fmt) + payload)


class CompositionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.names = ['.godot/imported/a.ctex', '.godot/imported/b.ctex']
        self.before = texture(2, 5, b'webp-payload')
        self.after = texture(0, 35, bytes(range(16)))
        self.source = self.pack('source', {n: self.before for n in self.names})
        self.base = self.pack('base', {n: self.before for n in self.names})
        self.delta = self.pack('delta', {self.names[0]: self.after})
        before = low.texture_header(self.before)
        after = low.texture_header(self.after)
        md5 = hashlib.md5(self.before).hexdigest()
        self.items = []
        for n in self.names:
            self.items.append({'source': 'res://' + n[-7:-5] + '.png', 'target': 'res://' + n,
                               'source_md5': md5, 'source_sha256': digest(self.before),
                               'old_sibling_sha256': digest(self.before), 'installed_md5': md5,
                               'old_selected': 'res://' + n + '.astc', 'old_selected_sha256': 'a' * 64,
                               'old_import_sha256': 'b' * 64, 'eligible': True, 'retained_reasons': [],
                               'input': before, 'role': 'visual', 'direct_fields': []})
        base_records = [{'path': n, 'kind': 'texture', 'source_path': i['source'][6:],
                         'source_md5': md5, 'source_sha256': digest(self.before),
                         'output_md5': md5, 'output': before} for n, i in zip(self.names, self.items)]
        self.base_report = self.write('base.json', {'source_sha256': low.file_hash(self.source),
            'output_sha256': low.file_hash(self.base), 'resources': base_records})
        self.specs = self.write('specs.json', {'old_pck_sha256': combine.OLD_SOURCE_SHA256,
            'source_pck_sha256': low.file_hash(self.source), 'texture_overlay_sha256': low.file_hash(self.base),
            'resources': self.items})
        self.specsha = low.file_hash(self.specs)
        quality = {'status': 'accepted', 'sample_step': 1, 'sample_count': 16, 'visible_samples': 16,
                   'alpha_p99': .01, 'alpha_max': .02, 'visible_rgb_p99': .01,
                   'limits': {'alpha_p99': .04, 'alpha_max': .25, 'visible_rgb_p99': .04},
                   'output_sha256': digest(self.after)}
        good = dict(self.items[0], base_entry_sha256=digest(self.before), output_sha256=digest(self.after),
                    output_md5=hashlib.md5(self.after).hexdigest(), output=after, quality=quality, strategy='fixture')
        bad_quality = dict(quality, status='quality_rejected', alpha_p99=.05, alpha_max=.06)
        bad_quality.pop('output_sha256')
        rejected = dict(self.items[1], retained_reasons=['sampled ASTC quality threshold exceeded'], quality=bad_quality)
        godot_sha = 'd' * 64
        worker_sha = low.file_hash(Path(combine.__file__).with_name('restore_vram_texture_worker.gd'))
        self.report = {'source_sha256': low.file_hash(self.source), 'old_source_sha256': combine.OLD_SOURCE_SHA256,
                       'base_texture_sha256': low.file_hash(self.base), 'delta_sha256': low.file_hash(self.delta),
                       'encoder_sha256': digest((godot_sha + worker_sha).encode()), 'godot_sha256': godot_sha,
                       'builder_sha256': low.file_hash(Path(combine.__file__).with_name('restore_vram_texture.py')),
                       'specs_sha256': self.specsha,
                       'texture_report_sha256': low.file_hash(self.base_report), 'accepted_count': 1,
                       'quality_rejected_count': 1, 'resources': [good, rejected]}
        self.delta_report = self.write('delta.json', self.report)

    def write(self, name, value):
        p = self.root / name
        p.write_text(json.dumps(value))
        return p

    def pack(self, name, values):
        pairs = []
        for index, (key, data) in enumerate(values.items()):
            f = self.root / (name + str(index)); f.write_bytes(data); pairs.append((key, f))
        result = self.root / (name + '.pck'); low.write_pack(pairs, result); return result

    def run_combine(self, suffix):
        with patch.object(combine, 'SPECS_SHA256', self.specsha):
            return combine.combine(self.source, self.base, self.base_report, self.delta,
                                   self.delta_report, self.specs, self.root / suffix)

    def test_accepted_and_rejected_candidates(self):
        merged = self.run_combine('good')
        entries = low.read_pack(merged)
        with merged.open('rb') as f:
            self.assertEqual(low.entry_bytes(f, entries[self.names[0]]), self.after)
            self.assertEqual(low.entry_bytes(f, entries[self.names[1]]), self.before)

    def test_forged_candidates_fail_without_mutating_inputs(self):
        source_before = self.source.read_bytes(); base_before = self.base.read_bytes()
        for key, mutate in {
            'old import': lambda r: r['resources'][0].update(old_import_sha256='f' * 64),
            'reason': lambda r: r['resources'][1].update(retained_reasons=[]),
            'quality': lambda r: r['resources'][0]['quality'].update(alpha_max=.9),
            'encoder': lambda r: r.update(godot_sha256='e' * 64),
            'missing': lambda r: r['resources'].pop(),
            'duplicate': lambda r: r['resources'].append(copy.deepcopy(r['resources'][0])),
        }.items():
            with self.subTest(key=key):
                r = copy.deepcopy(self.report); mutate(r); self.write('delta.json', r)
                with self.assertRaises(ValueError): self.run_combine('bad-' + key)
        self.assertEqual(self.source.read_bytes(), source_before)
        self.assertEqual(self.base.read_bytes(), base_before)


if __name__ == '__main__': unittest.main()
