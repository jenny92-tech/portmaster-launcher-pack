# INPUT:  launch_exec_view.py、临时挂载信息/命令夹具与标准库 mock
# OUTPUT: 执行视图覆盖、权限失败门禁、原进程交接与信号回归
# POS:    无设备副作用地验证共享开发启动入口
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / '_kit/launch_exec_view.py'
SPEC = importlib.util.spec_from_file_location('launch_exec_view', HELPER)
VIEW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VIEW)


class ExecViewTests(unittest.TestCase):
    def fixture(self, root):
        root = root.resolve()
        card = root / 'card with spaces'
        game = card / 'ports/game'
        library = game / 'runtime'
        library.mkdir(parents=True)
        other = root / 'other-card'
        other.mkdir()
        info = root / 'mountinfo'
        points = [Path('/'), card, library, other]
        lines = []
        for index, point in enumerate(points, 20):
            encoded = str(point).replace(' ', r'\040')
            lines.append(f'{index} 1 0:{index} / {encoded} rw - tmpfs tmpfs rw')
        info.write_text('\n'.join(lines) + '\n')
        return card, game, library, other, info

    def test_complete_view_includes_enclosing_card_and_nested_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            card, game, library, other, info = self.fixture(Path(tmp))
            # RW card and RO runtime each retain their unrelated flags.
            flags = {card: 8 | 2 | 4, library: 8 | 1 | 2 | 4, other: 8}
            calls = []

            def run(argv, check):
                calls.append(argv)
                if argv[1] == '-o':
                    flags[Path(argv[-1])] &= ~8

            def statvfs(path):
                return type('Stats', (), {'f_flag': flags[Path(path)]})()

            with patch.object(VIEW.sys, 'platform', 'linux'), \
                    patch.object(VIEW.os, 'statvfs', side_effect=statvfs), \
                    patch.object(VIEW, '_unshare_mounts') as unshare, \
                    patch.object(VIEW.shutil, 'which', return_value='/bin/mount'), \
                    patch.object(VIEW.subprocess, 'run', side_effect=run):
                changed = VIEW.prepare_exec_view([game], info)
            unshare.assert_called_once()
            self.assertEqual(changed, [str(card), str(library)])
            self.assertEqual(calls, [
                ['/bin/mount', '--make-rprivate', '/'],
                ['/bin/mount', '-o', 'remount,bind,exec', str(card)],
                ['/bin/mount', '-o', 'remount,bind,exec', str(library)],
            ])
            self.assertEqual(flags, {card: 6, library: 7, other: 8})

    def test_already_executable_needs_no_mount_tools_or_privileges(self):
        with tempfile.TemporaryDirectory() as tmp:
            card, game, library, other, info = self.fixture(Path(tmp))
            with patch.object(VIEW.sys, 'platform', 'linux'), \
                    patch.dict(sys.modules, {'ctypes': None}), \
                    patch.object(VIEW.os, 'statvfs', return_value=type('Stats', (), {'f_flag': 0})()), \
                    patch.object(VIEW.shutil, 'which') as which, \
                    patch.object(VIEW, '_unshare_mounts') as unshare:
                self.assertEqual(VIEW.prepare_exec_view([game], info), [])
            which.assert_not_called()
            unshare.assert_not_called()

    def test_namespace_denied_never_changes_mounts(self):
        with tempfile.TemporaryDirectory() as tmp:
            card, game, library, other, info = self.fixture(Path(tmp))
            with patch.object(VIEW.sys, 'platform', 'linux'), \
                    patch.object(VIEW.os, 'statvfs', return_value=type('Stats', (), {'f_flag': 8})()), \
                    patch.object(VIEW.shutil, 'which', return_value='/bin/mount'), \
                    patch.object(VIEW, '_unshare_mounts', side_effect=PermissionError('denied')), \
                    patch.object(VIEW.subprocess, 'run') as run:
                with self.assertRaises(PermissionError):
                    VIEW.prepare_exec_view([game], info)
            run.assert_not_called()

    def test_setup_failure_does_not_launch_unprepared_command(self):
        with patch.object(VIEW, 'prepare_exec_view', side_effect=RuntimeError('denied')), \
                patch.object(VIEW.os, 'execvp') as execute:
            self.assertEqual(VIEW.main(['--root', '/game', '--', '/game/start']), 78)
        execute.assert_not_called()

    def test_unexpected_mount_flag_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            card, game, library, other, info = self.fixture(Path(tmp))
            with patch.object(VIEW, '_mount_targets', return_value=[(card, 8 | 1 | 2)]), \
                    patch.object(VIEW.sys, 'platform', 'linux'), \
                    patch.object(VIEW.os, 'statvfs', return_value=type('Stats', (), {'f_flag': 0})()), \
                    patch.object(VIEW.shutil, 'which', return_value='/bin/mount'), \
                    patch.object(VIEW, '_unshare_mounts'), \
                    patch.object(VIEW.subprocess, 'run'):
                with self.assertRaisesRegex(RuntimeError, 'flags were not preserved'):
                    VIEW.prepare_exec_view([game], info)

    def test_command_preserves_pid_arguments_working_directory_and_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            code = 'import json,os,sys;print(json.dumps([os.getpid(),os.getcwd(),sys.argv[1:]]));sys.exit(17)'
            process = subprocess.Popen(
                [sys.executable, str(HELPER), '--root', str(root), '--',
                 sys.executable, '-c', code, 'a b', 'literal;$(no-shell)'],
                cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 17, stderr)
            self.assertEqual(json.loads(stdout),
                             [process.pid, str(root.resolve()), ['a b', 'literal;$(no-shell)']])

    @unittest.skipUnless(os.name == 'posix', 'POSIX signals required')
    def test_python_ignored_sigpipe_is_restored_for_original_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [sys.executable, str(HELPER), '--root', tmp, '--',
                 '/bin/sh', '-c', 'kill -PIPE $$; exit 99'], capture_output=True)
            self.assertEqual(result.returncode, -signal.SIGPIPE, result.stderr)

    @unittest.skipUnless(os.name == 'posix', 'POSIX signals required')
    def test_exec_preserves_direct_signal_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ready = root / 'ready'
            code = 'from pathlib import Path;import os,time;Path("ready").write_text(str(os.getpid()));time.sleep(30)'
            process = subprocess.Popen(
                [sys.executable, str(HELPER), '--root', str(root), '--',
                 sys.executable, '-c', code], cwd=root,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                self.assertEqual(int(ready.read_text()), process.pid)
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), -signal.SIGTERM)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                process.stderr.close()


if __name__ == '__main__':
    unittest.main()
