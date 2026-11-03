# INPUT:  路径导入器、2G 执行逻辑和主机临时文件夹具
# OUTPUT: 非执行导入、路径校验及只读预检的回归断言
# POS:    验证 Pack 接入不执行准备脚本、不触碰玩家档案
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

PORT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


importer = module('d2r_2g_import', PORT / 'src/scripts/import-entry.py')
launcher = module('d2r_2g_launch', PORT / 'src/launch.py')


class PackageTests(unittest.TestCase):
    def entry(self, root):
        fields = {'runtime': root / 'runtime', 'game': root / 'game',
                  'profile': root / 'existing profile', 'controllers': root / 'controllers.txt',
                  'patches': root / 'native', 'export D2R_OVERLAY_ROOT': root / 'RomFS',
                  'export D2R_PIPELINE_CACHE': root / 'cache'}
        path = root / 'entry.sh'
        path.write_text('#!/bin/bash\ntouch ' + shlex.quote(str(root / 'must-not-execute')) + '\n' +
                        'D2R_CLASSIC30=1\nD2R_NATIVE_HD_MASK=7\nDM_LINUX_CPU_POOL_TRIM=0\n# --check\n' +
                        ''.join(key + '=' + shlex.quote(str(value)) + '\n' for key, value in fields.items()))
        return path

    def test_import_is_data_only_and_preserves_existing_profile_path(self):
        with tempfile.TemporaryDirectory(prefix='暗黑 2G ') as temporary:
            root = Path(temporary)
            paths = importer.extract(self.entry(root))
            self.assertEqual(paths['profile'], str(root / 'existing profile'))
            self.assertFalse((root / 'must-not-execute').exists())
            config = root / 'install-paths.json'
            config.write_text(json.dumps(paths))
            self.assertEqual(launcher.load_paths(config), paths)
            paths['game'] = 'relative/path'
            config.write_text(json.dumps(paths))
            with self.assertRaises(ValueError):
                launcher.load_paths(config)

    def test_preflight_does_not_create_profile_or_run_the_binary(self):
        with tempfile.TemporaryDirectory(prefix='暗黑 2G ') as temporary:
            root = Path(temporary)
            paths = importer.extract(self.entry(root))
            required = ['runtime/d2r-linux-novideo', 'runtime/run-bringup.sh', 'runtime/log-errors.py',
                        'native/main.patched.bin', 'native/sdk.patched.bin', 'native/subsdk0.patched.bin',
                        'game/Update/RomFS/data/build_manifest.psv', 'RomFS/data/.build.config',
                        'RomFS/data/00-00000002.data', 'controllers.txt']
            for name in required:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('#!/bin/sh\nexit 98\n')
            (root / 'runtime/d2r-linux-novideo').chmod(0o755)
            config = root / 'install-paths.json'
            config.write_text(json.dumps(paths))
            before = sorted(str(p.relative_to(root)) for p in root.rglob('*'))
            result = subprocess.run([sys.executable, str(PORT / 'src/launch.py'), str(config), '--check'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('game was not started', result.stdout)
            self.assertEqual(before, sorted(str(p.relative_to(root)) for p in root.rglob('*')))
            self.assertFalse(Path(paths['profile']).exists())

    def test_import_rejects_shell_substitution_and_ambiguous_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entry = self.entry(root)
            original = entry.read_text()
            entry.write_text(original + 'runtime=/another/runtime\n')
            with self.assertRaises(ValueError):
                importer.extract(entry)
            entry.write_text(original.replace('runtime=', 'runtime=$(echo /runtime)#', 1))
            with self.assertRaises(ValueError):
                importer.extract(entry)
            self.assertFalse((root / 'must-not-execute').exists())

    def test_existing_path_manifest_can_be_repackaged_without_accessing_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = importer.extract(self.entry(root))
            source, output = root / 'paths.json', root / 'imported.json'
            source.write_text(json.dumps(paths))
            result = subprocess.run([sys.executable, str(PORT / 'src/scripts/import-entry.py'),
                                     '--paths', str(source), str(output)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(launcher.load_paths(output), paths)
            self.assertFalse(Path(paths['profile']).exists())
            self.assertFalse((root / 'must-not-execute').exists())

    def test_invalid_path_manifest_does_not_produce_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output = root / 'paths.json', root / 'imported.json'
            for data in ({'profile': 'relative/path'}, list(launcher.FIELDS)):
                source.write_text(json.dumps(data))
                result = subprocess.run([sys.executable, str(PORT / 'src/scripts/import-entry.py'),
                                         '--paths', str(source), str(output)], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
