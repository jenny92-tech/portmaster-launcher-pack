# INPUT:  optional Wayland session helper, isolated child processes and temporary runtime paths
# OUTPUT: ownership, audio-environment isolation and failure-cleanup regression checks
# POS:    exercise the private compositor lifecycle without touching a device or GPU
import importlib.util
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wayland_session', ROOT / '_kit/wayland_session.py')
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)


class SessionTests(unittest.TestCase):
    def test_private_clients_preserve_audio_and_do_not_mutate_parent(self):
        inherited = dict(XDG_RUNTIME_DIR='/audio', PULSE_SERVER='unix:/audio/pulse/native',
                         SDL_AUDIODRIVER='alsa', AUDIODEV='pulse', LD_LIBRARY_PATH='/game/libs',
                         LIBGL_FB='4', VK_ICD_FILENAMES='/firmware/driver.json')
        original = dict(inherited)
        child = session.client_environment(Path('/runtime'), Path('/weston'), Path('/private/socket'), inherited)
        self.assertEqual(inherited, original)
        for key in ('XDG_RUNTIME_DIR', 'PULSE_SERVER', 'SDL_AUDIODRIVER', 'AUDIODEV', 'VK_ICD_FILENAMES'):
            self.assertEqual(child[key], inherited[key])
        self.assertEqual(child['WAYLAND_DISPLAY'], '/private/socket')
        self.assertTrue(child['LD_LIBRARY_PATH'].startswith('/runtime/portable-wayland:'))
        self.assertTrue(child['LD_LIBRARY_PATH'].endswith(':/game/libs'))
        self.assertNotIn('LIBGL_FB', child)

    def test_native_exit_code_survives_a_live_compositor(self):
        compositor = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'], start_new_session=True)
        client = subprocess.Popen([sys.executable, '-c', 'import sys; sys.exit(42)'], start_new_session=True)
        try:
            self.assertEqual(session.wait_game(client, compositor), 42)
            self.assertIsNone(compositor.poll())
        finally:
            session.stop_owned(client)
            session.stop_owned(compositor)
        self.assertEqual(compositor.returncode, -signal.SIGTERM)

    def test_compositor_crash_only_stops_its_own_game(self):
        other = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'], start_new_session=True)
        compositor = subprocess.Popen([sys.executable, '-c', 'import sys; sys.exit(9)'], start_new_session=True)
        client = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'], start_new_session=True)
        try:
            self.assertEqual(session.wait_game(client, compositor), 1)
            self.assertIsNotNone(client.poll())
            self.assertIsNone(other.poll(), 'a separate game/session must remain alive')
        finally:
            for process in (client, compositor, other):
                session.stop_owned(process)

    def test_portable_menu_probe_isolated_and_failed_cleanup_rejects_success_token(self):
        for code in (0, 1):
            with self.subTest(exit=code), tempfile.TemporaryDirectory(prefix='wl-menu-') as temporary:
                root = Path(temporary)
                for name in ('rudroid.runtime', 'portable-wayland', 'vulkan-wsi', 'bin', 'libs'):
                    (root/name).mkdir()
                (root/'portable-wayland/manifest.json').write_text('{}')
                (root/'libs/weston_pkg_0.2.squashfs').write_text('image')
                for name in ('libVkLayer_window_system_integration.so', 'VkLayer_window_system_integration.json'):
                    (root/'vulkan-wsi'/name).write_text('wsi')
                loader = root/'unityloader'
                loader.write_text('#!/bin/sh\necho sdl2,gles,vulkan,vulkan-scale,vulkan-linear\n')
                loader.chmod(0o755)
                (root/'bin/wayland-session.py').write_text(
                    'import sys\nif "--check" in sys.argv: sys.exit(0)\n'
                    'print("RUDROID_VULKAN=1")\nsys.exit(' + str(code) + ')\n')
                body = r'''source "$1"
GAMEDIR="$2"; UNITY_RUNTIME_DIR="$2"; controlfolder="$2"; LOG_PREFIX=test
XDG_RUNTIME_DIR=/audio; SDL_VIDEODRIVER=kmsdrm; unset WAYLAND_DISPLAY
launcher_platform_acquire_display() { LAUNCHER_PLATFORM_RUNNERS=owned; }
launcher_platform_release_display() { LAUNCHER_PLATFORM_RUNNERS=; }
prepare_unity_graphics_options 1 >/dev/null
printf '%s|%s|%s|%s|%s|%s' "$PORTKIT_VULKAN_AVAILABLE" "$PORTKIT_VULKAN_PLATFORM_SUPPORTED" "$UNITY_WAYLAND_SESSION" "$XDG_RUNTIME_DIR" "$SDL_VIDEODRIVER" "${LAUNCHER_PLATFORM_RUNNERS:-}"
'''
                result = subprocess.check_output(['bash', '-c', body, 'test',
                    str(ROOT/'_kit/launcher_unity_common.sh'), str(root)], text=True)
                expected = '1' if code == 0 else '0'
                self.assertEqual(result, f'{expected}|{expected}|portable|/audio|kmsdrm|')

    def lifecycle(self, failure=None, cancel=False):
        with tempfile.TemporaryDirectory(prefix='wl-lifecycle-') as temporary:
            root = Path(temporary)
            owned = root / 'owned'
            owned.mkdir()
            events, processes, sockets = [], [], []
            class Child:
                def __init__(self, command, **kwargs):
                    self.pid = 10000 + len(processes)
                    self.returncode = None
                    self.role = 'weston' if len(processes) == 0 else 'game'
                    processes.append(self)
                    events.append('start:' + self.role)
                    if self.role == 'weston':
                        sock = socket.socket(socket.AF_UNIX)
                        sock.bind(str(Path(kwargs['env']['XDG_RUNTIME_DIR']) / 'rudroid-vulkan'))
                        sockets.append(sock)
                def poll(self):
                    if failure == 'server' and self.role == 'weston':
                        self.returncode = 9
                    return self.returncode
                def wait(self, timeout=None):
                    if failure == 'probe' and self.role == 'game' and self.returncode is None:
                        raise subprocess.TimeoutExpired('probe', timeout)
                    if self.returncode is None:
                        self.returncode = 0
                    return self.returncode
            def run(command, **kwargs):
                events.append(command[0])
                if command[0] == 'mount':
                    self.assertIn('ro', command[2].split(','))
                if command[0] == 'umount' and failure == 'unmount':
                    raise subprocess.CalledProcessError(1, command)
            def kill(pid, sig):
                target = next(p for p in processes if p.pid == pid)
                target.returncode = -sig
                events.append('stop:' + target.role)
            def wait(client, compositor):
                if cancel:
                    with patch.object(client, 'poll', side_effect=AssertionError('signal handler must not reap the game')):
                        signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
                    self.assertEqual(client.returncode, -signal.SIGTERM)
                    return client.returncode
                client.returncode = 42
                events.append('game:exit42')
                return 42
            try:
                with patch.object(session.tempfile, 'mkdtemp', return_value=str(owned)), \
                     patch.object(session, 'server_environment', side_effect=lambda wp, xdg: {'XDG_RUNTIME_DIR':str(xdg)}), \
                     patch.object(session.subprocess, 'run', side_effect=run), \
                     patch.object(session.subprocess, 'Popen', side_effect=Child), \
                     patch.object(session.os, 'killpg', side_effect=kill), \
                     patch.object(session, 'wait_game', side_effect=wait):
                    if failure:
                        error = subprocess.CalledProcessError if failure == 'unmount' else session.SessionError
                        with self.assertRaises(error):
                            session._owned_session(root, root/'image', root, ['/game'], failure == 'probe')
                    else:
                        expected = -signal.SIGTERM if cancel else 42
                        self.assertEqual(session._owned_session(root, root/'image', root, ['/game'], False), expected)
                self.assertEqual(owned.exists(), failure == 'unmount')
                self.assertEqual(events[-1], 'umount')
                if failure == 'server':
                    self.assertNotIn('start:game', events)
                else:
                    self.assertLess(events.index('start:game'), events.index('stop:weston'))
                return events
            finally:
                for sock in sockets:
                    sock.close()

    def test_game_exit_stops_compositor_before_unmount(self):
        events = self.lifecycle()
        self.assertLess(events.index('game:exit42'), events.index('stop:weston'))

    def test_cancel_leaves_game_reaping_to_the_session_waiter(self):
        events = self.lifecycle(cancel=True)
        self.assertLess(events.index('stop:game'), events.index('stop:weston'))

    def test_failed_server_cannot_launch_a_game(self):
        self.lifecycle('server')

    def test_probe_timeout_cleans_up_both_owned_children(self):
        events = self.lifecycle('probe')
        self.assertLess(events.index('stop:game'), events.index('stop:weston'))

    def test_failed_unmount_retains_the_mountpoint(self):
        self.lifecycle('unmount')


if __name__ == '__main__':
    unittest.main()
