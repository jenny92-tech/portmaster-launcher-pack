# INPUT:  Explicit PCK patch tools and synthetic metadata/payload fixtures
# OUTPUT: Original/replacement-hash rejection, idempotence and explicit-input regression checks
# POS:    Verifies offline byte patching without original game data
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'ports/sts2/src/tools/csharp-godot-arm64-kit'


class PckBlobPatchTests(unittest.TestCase):
    def fixture(self, root):
        old, new = b'original', b'replaced'
        pck = root / 'fixture.pck'
        pck.write_bytes(hashlib.md5(old).digest() + old + b'unchanged')
        meta = root / 'patch_meta.json'
        meta.write_text(json.dumps({'blob_ofs': 16, 'blob_size': len(old),
            'gdext_ofs': 16, 'gdext_size': len(old), 'md5_pos': 0,
            'orig_md5': hashlib.md5(old).hexdigest(), 'new_md5': hashlib.md5(new).hexdigest()}))
        blob = root / 'fmod.gdextension.patched'
        blob.write_bytes(new)
        return pck, meta, blob, hashlib.md5(new).digest() + new + b'unchanged'

    def run_patch(self, tool, pck, meta, blob):
        args = [str(meta), str(blob)] if tool == 'apply_pck_blob_patch.py' else [str(meta.parent)]
        return subprocess.run([sys.executable, str(TOOLS / tool), str(pck), *args], capture_output=True)

    def test_explicit_inputs_patch_and_repeat_without_other_changes(self):
        for tool in ('apply_pck_blob_patch.py', 'apply_gdext_patch.py'):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as tmp:
                pck, meta, blob, expected = self.fixture(Path(tmp))
                for _ in range(2):
                    self.assertEqual(self.run_patch(tool, pck, meta, blob).returncode, 0)
                    self.assertEqual(pck.read_bytes(), expected)

    def test_missing_patch_arguments_never_modify_input(self):
        for tool in ('apply_pck_blob_patch.py', 'apply_gdext_patch.py'):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as tmp:
                pck, _, _, _ = self.fixture(Path(tmp))
                before = pck.read_bytes()
                result = subprocess.run([sys.executable, str(TOOLS / tool), str(pck)], capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(pck.read_bytes(), before)

    def test_wrong_original_hash_never_modifies_input(self):
        for tool in ('apply_pck_blob_patch.py', 'apply_gdext_patch.py'):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as tmp:
                pck, meta, blob, _ = self.fixture(Path(tmp))
                before = b'bad-data' + pck.read_bytes()[8:]
                pck.write_bytes(before)
                # Corrupt the checked payload, not only its directory entry.
                before = before[:16] + b'corrupt!' + before[24:]
                pck.write_bytes(before)
                self.assertEqual(self.run_patch(tool, pck, meta, blob).returncode, 1)
                self.assertEqual(pck.read_bytes(), before)

    def test_wrong_same_size_blob_never_modifies_input(self):
        for tool in ('apply_pck_blob_patch.py', 'apply_gdext_patch.py'):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as tmp:
                pck, meta, blob, _ = self.fixture(Path(tmp))
                before = pck.read_bytes()
                # Keep the expected length while changing the replacement bytes.
                blob.write_bytes(b'wrong!!!')
                self.assertEqual(self.run_patch(tool, pck, meta, blob).returncode, 1)
                self.assertEqual(pck.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
