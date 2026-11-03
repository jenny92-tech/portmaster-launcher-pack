# INPUT: archived SFX helper, optional previously downloaded private UnRAR/input
# OUTPUT: parameter validation, sandbox boundary and small member CRC checks
# POS: host-only regression; never runs a game executable or extracts full game
import importlib.util
import os
import socket
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'ports/sts2/src/tools/godot_pck/extract_windows_sfx.py'
UNRAR = Path(os.environ.get('STS2_SFX_UNRAR', '/unused/unrar-fixture'))
SOURCE = Path(os.environ.get('STS2_SFX_SOURCE', '/unused/sts2-fixture.exe'))
spec = importlib.util.spec_from_file_location('sts2_sfx', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SfxArchiveTest(unittest.TestCase):
    def test_invalid_hash_fails_before_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'output'
            p = subprocess.run([sys.executable, str(SCRIPT), '--source', str(SOURCE),
                '--source-sha256', 'bad', '--output-dir', str(output), '--unrar', str(UNRAR)],
                capture_output=True, text=True)
            self.assertNotEqual(p.returncode, 0)
            self.assertFalse(output.exists())

    def test_comparison_counts_recorded_resource_identities(self):
        sys.path.insert(0, str(SCRIPT.parent))
        try:
            compare_spec = importlib.util.spec_from_file_location('sts2_compare', SCRIPT.parent / 'compare_pck_inventory.py')
            compare = importlib.util.module_from_spec(compare_spec)
            compare_spec.loader.exec_module(compare)
            left = {'a.gdshader': (0, 2, 'same'), 'b.tscn': (2, 2, 'one'), 'x.astc.ctex': (4, 2, 'left')}
            right = {'a.gdshader': (0, 2, 'same'), 'b.tscn': (2, 2, 'two'), 'y.bptc.ctex': (4, 2, 'right')}
            result = compare.compare(left, right)
            self.assertEqual((result['common'], result['same_entry_md5'], result['left_only'], result['right_only']), (2, 1, 1, 1))
            self.assertEqual(result['left_vram_formats']['astc'], 1)
            self.assertEqual(result['right_vram_formats']['bptc'], 1)
        finally:
            sys.path.pop(0)

    @unittest.skipUnless(sys.platform == 'darwin' and bool(os.environ.get('STS2_SFX_UNRAR')) and bool(os.environ.get('STS2_SFX_SOURCE')) and UNRAR.is_file() and SOURCE.is_file(),
                         'requires private UnRAR/input and macOS sandbox-exec')
    def test_generated_sandbox_denies_private_read_and_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp).resolve()
            secret = temp / 'probe.txt'
            secret.write_text('dummy data')
            profile = temp / 'profile.sb'
            profile.write_text(module.sandbox_profile(SOURCE.resolve(), UNRAR.resolve()))
            run = lambda *args: subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile), *map(str,args)], capture_output=True)
            self.assertNotEqual(run('/bin/cat', secret).returncode, 0)
            with socket.socket() as server:
                server.bind(('127.0.0.1', 0)); server.listen()
                args = ['/usr/bin/nc', '-z', '-w', '1', '127.0.0.1', str(server.getsockname()[1])]
                self.assertEqual(subprocess.run(args, capture_output=True).returncode, 0)
                self.assertNotEqual(run(*args).returncode, 0)
            result = run(UNRAR, 'p', '-inul', '-cfg-', '-@', '-p-', '--', SOURCE,
                         'Slay the Spire 2/controller_config/game_actions_2868840.vdf')
            self.assertEqual(result.returncode, 0)
            self.assertEqual((len(result.stdout), zlib.crc32(result.stdout)), (10635, 0x623A0C71))
            denied = run(UNRAR, 'e', '-inul', '-cfg-', '-@', '-p-', '--', SOURCE,
                         'Slay the Spire 2/controller_config/game_actions_2868840.vdf', str(temp) + '/')
            self.assertNotEqual(denied.returncode, 0)
            self.assertFalse((temp / 'game_actions_2868840.vdf').exists())


if __name__ == '__main__':
    unittest.main()
