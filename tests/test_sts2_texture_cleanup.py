# INPUT: explicit patch cleanup helper and synthetic patch/process trees
# OUTPUT: dry-run, restricted removal, manifest and process-reference checks
# POS: local fixture; never connects to a device
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('texture_cleanup', ROOT / 'ports/sts2/src/tools/device_tools/cleanup_patch.py')
cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup)


class CleanupSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / 'trial'
        self.patches = self.root / 'patches'
        self.patches.mkdir(parents=True)
        self.proc = self.base / 'proc'
        self.proc.mkdir()
        self.old = self.make_patch('old')
        self.active = self.make_patch('active')
        (self.root / 'active-patch').write_text(self.active)

    def make_patch(self, content):
        temp = self.patches / content
        temp.mkdir()
        hashes = {}
        for name in cleanup.FILES - {'manifest.json'}:
            data = (content + name).encode()
            (temp / name).write_bytes(data)
            hashes[name] = hashlib.sha256(data).hexdigest()
        data = json.dumps({'files': hashes}).encode()
        (temp / 'manifest.json').write_bytes(data)
        identity = hashlib.sha256(data).hexdigest()
        temp.rename(self.patches / identity)
        return identity

    def go(self, **kwargs):
        return cleanup.cleanup(str(self.root), self.old, self.active, proc=self.proc, **kwargs)

    def test_dry_run_and_explicit_remove(self):
        self.assertTrue(self.go()['dry_run'])
        self.assertTrue((self.patches / self.old).exists())
        self.assertFalse(self.go(apply=True)['dry_run'])
        self.assertFalse((self.patches / self.old).exists())
        self.assertTrue((self.patches / self.active).exists())

    def test_refuses_symlinked_patch_directory(self):
        outside = self.base / 'outside'; outside.mkdir()
        protected = outside / 'user.dat'; protected.write_bytes(b'keep')
        self.patches.rename(self.root / 'original')
        self.patches.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            self.go(apply=True)
        self.assertEqual(protected.read_bytes(), b'keep')

    def test_refuses_modified_manifest_or_payload(self):
        (self.patches / self.old / 'sts2.dll').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'payload mismatch'):
            self.go(apply=True)
        self.assertTrue((self.patches / self.old).exists())

    def test_refuses_process_fd_and_maps(self):
        process = self.proc / '123'; (process / 'fd').mkdir(parents=True)
        (process / 'maps').write_text('')
        handle = process / 'fd' / '5'
        handle.symlink_to(self.patches / self.old / 'sts2.dll')
        with self.assertRaisesRegex(ValueError, 'open by PID'):
            self.go(apply=True)
        handle.unlink()
        (process / 'maps').write_text(str(self.patches / self.old / 'sts2.dll'))
        with self.assertRaisesRegex(ValueError, 'mapped by PID'):
            self.go(apply=True)
        self.assertTrue((self.patches / self.old).exists())


if __name__ == '__main__':
    unittest.main()
