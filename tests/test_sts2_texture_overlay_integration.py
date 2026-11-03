# INPUT:  Vulkan trial main-PCK selection and synthetic merged pack
# OUTPUT: installed identity binding and fail-closed selection regression
# POS:    isolated temporary fixtures; no device or game execution
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tests import test_sts2_texture_merge as fixtures

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / 'ports/sts2/love/vulkan-trial.sh.template'


class MainPackSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.testdir = self.root / 'sts2-vk-test'
        (self.testdir / 'textures').mkdir(parents=True)
        # Reuse the pack writer fixture but keep installation paths realistic.
        self.fixture = fixtures.TextureMergeTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.source = self.fixture.source
        digest = hashlib.sha256(self.fixture.overlay.read_bytes()).hexdigest()
        self.overlay = self.testdir / 'textures' / (digest + '.pck')
        self.fixture.overlay.rename(self.overlay)
        self.fixture.overlay = self.overlay
        self.fixture.write_report()
        result = subprocess.run([sys.executable, str(fixtures.TOOL), '--source', str(self.source), '--overlay', str(self.overlay), '--report', str(self.fixture.report), '--output-dir', str(self.testdir / 'merged')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.pack = next((self.testdir / 'merged').glob('*.pck'))
        text = TEMPLATE.read_text()
        self.verifier = text.split("<<'VERIFY_TEXTURE' || exit 1\n", 1)[1].split('\nVERIFY_TEXTURE', 1)[0]

    def verify(self, pack=None):
        return subprocess.run([sys.executable, '-c', self.verifier, str(self.testdir), str(self.source), str(pack or self.pack)], capture_output=True, text=True)

    def test_installed_and_changed_inputs(self):
        self.assertEqual(self.verify().returncode, 0)
        for path in (self.source, self.pack):
            original = path.read_bytes()
            path.write_bytes(original + b'!')
            self.assertNotEqual(self.verify().returncode, 0)
            path.write_bytes(original)
            result = subprocess.run([sys.executable, str(fixtures.TOOL), '--source', str(self.source), '--overlay', str(self.overlay), '--report', str(self.fixture.report), '--output-dir', str(self.testdir / 'merged')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.verify().returncode, 0)

    def test_overlay_can_be_removed_after_install(self):
        self.overlay.unlink()
        self.assertEqual(self.verify().returncode, 0)

    def test_remount_metadata_does_not_change_identity(self):
        wrapper = '''from pathlib import Path
from types import SimpleNamespace
original = Path.stat
def changed(self, *args, **kwargs):
    v = original(self, *args, **kwargs)
    return SimpleNamespace(st_mode=v.st_mode, st_size=v.st_size, st_mtime_ns=v.st_mtime_ns,
                           st_ctime_ns=v.st_ctime_ns + 999, st_dev=v.st_dev + 1, st_ino=v.st_ino + 1)
Path.stat = changed
'''
        result = subprocess.run([sys.executable, '-c', wrapper + self.verifier, str(self.testdir), str(self.source), str(self.pack)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bad_manifest_and_missing_rejected(self):
        sidecar = self.pack.with_suffix('.json')
        manifest = json.loads(sidecar.read_text())
        manifest['overlay_sha256'] = 'bad'
        sidecar.write_text(json.dumps(manifest))
        self.assertNotEqual(self.verify().returncode, 0)
        sidecar.unlink()
        self.assertNotEqual(self.verify().returncode, 0)
        self.assertNotEqual(self.verify(self.testdir / 'merged/other.pck').returncode, 0)

    def test_dangling_marker_fails(self):
        marker = self.testdir / 'active-texture'
        marker.symlink_to(self.root / 'missing')
        text = TEMPLATE.read_text()
        selection = text.split('if [ -z "${SLL_TEXTURE_MAIN_PACK:-}" ] &&', 1)[1].split('\nif [ -n "${SLL_TEXTURE_MAIN_PACK:-}" ]; then', 1)[0]
        env = {k: v for k, v in os.environ.items() if k != 'SLL_TEXTURE_MAIN_PACK'}
        result = subprocess.run(['/bin/bash', '-c', 'TESTDIR="$1"; LOG_PREFIX=test; if [ -z "${SLL_TEXTURE_MAIN_PACK:-}" ] &&' + selection, 'fixture', str(self.testdir)], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_direct_main_pack_and_default(self):
        text = TEMPLATE.read_text()
        self.assertIn('MAIN_PACK="$ORIGINAL/gamedata/pcks/SlayTheSpire2.pck"', text)
        self.assertIn('--main-pack "$MAIN_PACK"', text)
        self.assertNotIn('cp "$SLL_TEXTURE_MAIN_PACK"', text)
        self.assertIn('unset SLL_TEXTURE_OVERLAY', text)
        self.assertIn('SLL_TEXTURE_OVERLAY is retired', text)
        self.assertLess(text.index("<<'VERIFY_TEXTURE'"), text.index('run_trial_game()'))


if __name__ == '__main__':
    unittest.main()
