# INPUT: synthetic signed-package fixtures and local sockets
# OUTPUT: verification of extraction guards and failed-forward cleanup
# POS: offline tests; does not connect to a device or run a diagnostics tool
import hashlib
import importlib.util
from pathlib import Path
import argparse
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('sts2_runtime_counters', ROOT / 'ports/sts2/src/tools/collect_runtime_counters.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RuntimeCountersTests(unittest.TestCase):
    def package(self, directory, names):
        path = directory / MODULE.PACKAGE_NAME
        with zipfile.ZipFile(path, 'w') as archive:
            for name, content in names.items():
                archive.writestr(MODULE.TOOL_PREFIX + name, content)
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_package_identity_extraction_and_tamper(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            original = MODULE.PACKAGE_SHA256
            try:
                MODULE.PACKAGE_SHA256 = self.package(directory, {'dotnet-counters.dll': b'fixture', 'sub/a': b'data'})
                tool = MODULE.checked_tool(directory)
                self.assertEqual(tool.read_bytes(), b'fixture')
                self.assertEqual(MODULE.checked_tool(directory), tool)
                extra = tool.parent / 'foreign.dll'
                extra.write_bytes(b'unexpected')
                with self.assertRaises(ValueError):
                    MODULE.checked_tool(directory)
                extra.unlink()
                tool.write_bytes(b'changed')
                with self.assertRaises(ValueError):
                    MODULE.checked_tool(directory)
            finally:
                MODULE.PACKAGE_SHA256 = original

    def test_package_path_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            original = MODULE.PACKAGE_SHA256
            try:
                MODULE.PACKAGE_SHA256 = self.package(directory, {'../outside': b'forbidden'})
                with self.assertRaises(ValueError):
                    MODULE.checked_tool(directory)
                self.assertFalse((directory / 'outside').exists())
            finally:
                MODULE.PACKAGE_SHA256 = original

    def test_forward_timeout_still_removes_known_unix_endpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = argparse.Namespace(pid=123, starttime='456', seconds=15,
                tool_dir=tmp, output=str(Path(tmp) / 'report.json'), target='device', dotnet='/tool/dotnet')
            calls = []

            def run(command, **kwargs):
                calls.append(command)
                if '--no-rebind' in command:
                    raise subprocess.TimeoutExpired(command, 15)
                return subprocess.CompletedProcess(command, 0)

            with mock.patch.object(MODULE, 'checked_tool', return_value=Path('/tool/counters.dll')):
                with mock.patch.object(MODULE, 'device_identity'):
                    with mock.patch.object(MODULE.subprocess, 'run', side_effect=run):
                        with self.assertRaises(subprocess.TimeoutExpired):
                            MODULE.collect(args)
            create, remove = calls
            local = create[create.index('--no-rebind') + 1]
            self.assertTrue(local.startswith('localfilesystem:/tmp/sts2-counters-'))
            self.assertEqual(remove[-2:], ['--remove', local])

    def test_failed_forward_cleanup_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = argparse.Namespace(pid=123, starttime='456', seconds=15,
                tool_dir=tmp, output=str(Path(tmp) / 'report.json'), target='device', dotnet='/tool/dotnet')

            def run(command, **kwargs):
                if '--no-rebind' in command:
                    raise subprocess.TimeoutExpired(command, 15)
                return subprocess.CompletedProcess(command, 1)

            with mock.patch.object(MODULE, 'checked_tool', return_value=Path('/tool/counters.dll')):
                with mock.patch.object(MODULE, 'device_identity'):
                    with mock.patch.object(MODULE.subprocess, 'run', side_effect=run):
                        with self.assertRaisesRegex(RuntimeError, 'forward cleanup failed'):
                            MODULE.collect(args)


if __name__ == '__main__':
    unittest.main()
