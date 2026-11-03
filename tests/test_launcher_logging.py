#!/usr/bin/env python3
# INPUT:  shared launcher platform and exit cleanup, isolated scripts and command fixtures
# OUTPUT: quiet success, retained error/failure context and conditional kernel-log assertions
# POS:    verifies production log policy without starting a UI, game or device process
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LauncherLoggingTests(unittest.TestCase):
    def run_case(self, status=0, error=False, diagnostics=False, cleanup=True, large=False):
        with tempfile.TemporaryDirectory(prefix='launcher-logging-') as temporary:
            base = Path(temporary)
            log = base / 'log.txt'
            log.write_text('previous session')
            body = f'''
source {shlex.quote(str(ROOT/'_kit/launcher_platform.sh'))}
source {shlex.quote(str(ROOT/'_kit/portmaster_common.sh'))}
GAMEDIR={shlex.quote(str(base))}
launcher_platform_release_display() {{ :; }}
dmesg() {{ echo kernel-context; }}
sync() {{ :; }}
launcher_platform_start_log "$GAMEDIR/log.txt" || exit 1
'''
            if cleanup:
                body += 'install_exit_trap\n'
            body += 'echo normal-ui-startup\n'
            if error:
                body += "echo '[ERROR] [SDL] operational failure' >&2\n"
            if large:
                body += "awk 'BEGIN { for(i=0;i<4000;i++) print \"context-line-abcdefghijklmnopqrstuvwxyz0123456789\"; print \"last-context\" }'\n"
            body += f'exit {status}\n'
            environment = dict(os.environ)
            for name in ('RUDROID_DIAGNOSTICS', 'BOGODROID_DIAGNOSTICS'):
                environment.pop(name, None)
            if diagnostics:
                environment['RUDROID_DIAGNOSTICS'] = '1'
            result = subprocess.run(['bash', '-c', body], env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)
            retained = bool(status or error or diagnostics)
            self.assertEqual('normal-ui-startup' in log.read_text(), retained)
            self.assertEqual((base/'dmesg_exit.log').exists(), retained and cleanup)
            if error:
                self.assertIn('operational failure', log.read_text())
            if large:
                self.assertLessEqual(log.stat().st_size, 65536)
                self.assertIn('last-context', log.read_text())

    def test_clean_success_discards_ui_noise_and_skips_kernel_capture(self):
        self.run_case()

    def test_nonzero_exit_keeps_context_and_exit_code(self):
        self.run_case(status=42)

    def test_recoverable_structured_error_is_kept_even_after_exit_zero(self):
        self.run_case(error=True)

    def test_diagnostics_are_explicit(self):
        self.run_case(diagnostics=True)

    def test_early_menu_exit_is_quiet_and_early_failure_is_preserved(self):
        self.run_case(cleanup=False)
        self.run_case(status=2, cleanup=False)

    def test_large_output_keeps_first_error_and_recent_context_within_limit(self):
        self.run_case(error=True, large=True)

    def test_native_failure_survives_firmware_cleanup_exiting_zero(self):
        with tempfile.TemporaryDirectory(prefix='native-log-exit-') as temporary:
            base = Path(temporary)
            (base/'rudroid.runtime').mkdir()
            loader = base/'unityloader'
            loader.write_text('#!/bin/sh\nsleep 0.05\nexit 42\n')
            loader.chmod(0o755)
            script = f'''
source {shlex.quote(str(ROOT/'_kit/launcher_platform.sh'))}
source {shlex.quote(str(ROOT/'_kit/portmaster_common.sh'))}
source {shlex.quote(str(ROOT/'_kit/launcher_compat.sh'))}
source {shlex.quote(str(ROOT/'_kit/launcher_unity_common.sh'))}
GAMEDIR={shlex.quote(str(base))}; CONFDIR="$GAMEDIR/conf"; UNITY_RUNTIME_DIR="$GAMEDIR"
audio_setup() {{ :; }}
memory_tuning() {{ :; }}
launcher_platform_prepare_game() {{ :; }}
launcher_platform_release_display() {{ :; }}
launcher_platform_finish() {{ exit 0; }}
dmesg() {{ echo kernel-context; }}
sync() {{ :; }}
launcher_platform_start_log "$GAMEDIR/log.txt"
run_unity_game "$GAMEDIR/config.toml"
'''
            environment = dict(os.environ)
            for name in ('RUDROID_DIAGNOSTICS', 'BOGODROID_DIAGNOSTICS'):
                environment.pop(name, None)
            result = subprocess.run(['bash','-c',script], env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('[ERROR] native player exited with status=42', (base/'log.txt').read_text())
            self.assertTrue((base/'dmesg_exit.log').is_file())


if __name__ == '__main__':
    unittest.main()
