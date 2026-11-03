# INPUT: trial launcher diagnostic XDG validation and isolated temporary paths
# OUTPUT: valid fresh data root and guarded shader-cache link checks
# POS: host-only fixture; never reads or changes a device or player saves
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / 'ports/sts2/love/vulkan-trial.sh.template'


class DiagnosticXdgTests(unittest.TestCase):
    def test_diagnostics_are_opt_in_and_focus_compat_preserved(self):
        text = TEMPLATE.read_text()
        start = text.index('    export SLL_INPUT_DIAG=')
        end = text.index('    set -- --force-steam off', start)
        exports = text[start:end]
        names = ('SLL_INPUT_DIAG','SLL_TEXTURE_DIAG','SLL_ASSET_DIAG','SLL_ASSET_DIAG_PATHS','SLL_MALLOC_DIAG','SLL_LOONG_FOCUS_COMPAT')
        command = exports + '\nprintf "%s\\n" ' + ' '.join('"$'+n+'"' for n in names)
        env = {k:v for k,v in os.environ.items() if k not in names}
        result = subprocess.run(['bash','-c',command],env=env,capture_output=True,text=True,check=True)
        self.assertEqual(result.stdout.splitlines(),['0','0','0','0','0','1'])
        env.update({k:'1' for k in names[:-1]});env[names[-1]]='0'
        result = subprocess.run(['bash','-c',command],env=env,capture_output=True,text=True,check=True)
        self.assertEqual(result.stdout.splitlines(),['1','1','1','1','1','0'])

    def test_private_root_and_explicit_shader_cache_only(self):
        text = TEMPLATE.read_text()
        marker = '    python3 - "$SLL_DIAG_XDG_ROOT" "$TESTDIR/conf/data/SlayTheSpire2/shader_cache" <<\'PY\' || exit 1\n'
        code = text.split(marker, 1)[1].split('\nPY\n', 1)[0]
        root = Path('/tmp') / ('sts2-memory-diag-' + uuid.uuid4().hex)
        with tempfile.TemporaryDirectory(prefix='sts2-xdg-fixture-', dir='/tmp') as temp:
            outside = Path(temp)
            source = outside / 'testdir/conf/data/SlayTheSpire2/shader_cache'
            source.mkdir(parents=True)
            try:
                root.mkdir(mode=0o700)
                run = subprocess.run([sys.executable, '-c', code, str(root), str(source)], capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual((root / 'data/SlayTheSpire2/shader_cache').resolve(), source.resolve())
                self.assertTrue((root / 'config').is_dir())
                self.assertTrue((root / 'cache').is_dir())
                bad = root / 'data/SlayTheSpire2/shader_cache'
                bad.unlink()
                bad.symlink_to(outside)
                run = subprocess.run([sys.executable, '-c', code, str(root), str(source)], capture_output=True, text=True)
                self.assertNotEqual(run.returncode, 0)
            finally:
                shutil.rmtree(root)

    def test_symlinked_root_rejected(self):
        text = TEMPLATE.read_text()
        marker = '    python3 - "$SLL_DIAG_XDG_ROOT" "$TESTDIR/conf/data/SlayTheSpire2/shader_cache" <<\'PY\' || exit 1\n'
        code = text.split(marker, 1)[1].split('\nPY\n', 1)[0]
        root = Path('/tmp') / ('sts2-memory-diag-' + uuid.uuid4().hex)
        with tempfile.TemporaryDirectory(prefix='sts2-xdg-fixture-', dir='/tmp') as temp:
            try:
                root.symlink_to(temp)
                run = subprocess.run([sys.executable, '-c', code, str(root), str(Path(temp) / 'missing')], capture_output=True, text=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertFalse((Path(temp) / 'data').exists())
            finally:
                root.unlink()

    def test_preexisting_save_symlink_rejected(self):
        text = TEMPLATE.read_text()
        marker = '    python3 - "$SLL_DIAG_XDG_ROOT" "$TESTDIR/conf/data/SlayTheSpire2/shader_cache" <<\'PY\' || exit 1\n'
        code = text.split(marker, 1)[1].split('\nPY\n', 1)[0]
        root = Path('/tmp') / ('sts2-memory-diag-' + uuid.uuid4().hex)
        with tempfile.TemporaryDirectory(prefix='sts2-xdg-fixture-', dir='/tmp') as temp:
            try:
                root.mkdir(mode=0o700)
                game = root / 'data/SlayTheSpire2'
                game.mkdir(parents=True)
                (game / 'steam').symlink_to(temp)
                run = subprocess.run([sys.executable, '-c', code, str(root), str(Path(temp) / 'missing')], capture_output=True, text=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(list(Path(temp).iterdir()), [])
            finally:
                shutil.rmtree(root)

    def test_shader_cache_parent_symlink_rejected(self):
        text = TEMPLATE.read_text()
        marker = '    python3 - "$SLL_DIAG_XDG_ROOT" "$TESTDIR/conf/data/SlayTheSpire2/shader_cache" <<\'PY\' || exit 1\n'
        code = text.split(marker, 1)[1].split('\nPY\n', 1)[0]
        root = Path('/tmp') / ('sts2-memory-diag-' + uuid.uuid4().hex)
        with tempfile.TemporaryDirectory(prefix='sts2-xdg-fixture-', dir='/tmp') as temp:
            outside = Path(temp)
            testdir = outside / 'testdir'
            target = outside / 'redirect/data/SlayTheSpire2/shader_cache'
            testdir.mkdir()
            target.mkdir(parents=True)
            (testdir / 'conf').symlink_to(outside / 'redirect')
            try:
                root.mkdir(mode=0o700)
                source = testdir / 'conf/data/SlayTheSpire2/shader_cache'
                run = subprocess.run([sys.executable, '-c', code, str(root), str(source)], capture_output=True, text=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertFalse((root / 'data/SlayTheSpire2/shader_cache').exists())
            finally:
                shutil.rmtree(root)


if __name__ == '__main__':
    unittest.main()
