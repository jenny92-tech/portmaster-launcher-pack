#!/usr/bin/env python3
# INPUT:  audited private clients, installed PortMaster Weston image and a native command
# OUTPUT: bounded Vulkan preflight or one owned game/compositor session with its exit status
# POS:    provide optional Wayland on KMS firmware without changing the system GPU stack
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
"""Private compositor lifetime; the calling launcher owns the frontend display lease."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import stat
import subprocess
import sys
import tempfile
import time


class SessionError(Exception):
    pass


def validate(runtime, image):
    if platform.system() != 'Linux' or platform.machine() not in ('aarch64', 'arm64'):
        raise SessionError('portable Wayland requires ARM64 Linux')
    if os.geteuid() != 0:
        raise SessionError('portable Weston needs permission to mount its private runtime')
    clients = runtime / 'portable-wayland'
    manifest = json.loads((clients / 'manifest.json').read_text())
    libc = os.confstr('CS_GNU_LIBC_VERSION').split()
    minimum = tuple(map(int, manifest['minimum_glibc'].split('.')))
    if libc[0] != 'glibc' or tuple(map(int, libc[1].split('.'))) < minimum:
        raise SessionError('portable clients require glibc ' + manifest['minimum_glibc'])
    for name, entry in manifest['files'].items():
        if Path(name).name != name or name in ('.', '..'):
            raise SessionError('invalid client manifest path')
        path = clients / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size != entry['size']:
            raise SessionError('missing or invalid client: ' + name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise SessionError('client checksum mismatch: ' + name)
    if not {'libSDL2-2.0.so.0', 'libvulkan.so.1'} <= manifest['files'].keys():
        raise SessionError('incomplete client manifest')
    if not image.is_file() or not Path('/dev/dri/card0').exists():
        raise SessionError('portable Weston image or DRM device is missing')
    for name in ('libVkLayer_window_system_integration.so', 'VkLayer_window_system_integration.json'):
        if not (runtime / 'vulkan-wsi' / name).is_file():
            raise SessionError('private Vulkan WSI is missing')


def server_environment(package, xdg):
    libraries = package / 'lib_aarch64'
    modules = {name: libraries / 'libweston-14' / (name + '.so')
               for name in ('drm-backend', 'headless-backend', 'wayland-backend', 'gl-renderer')}
    modules['kiosk-shell'] = libraries / 'weston/kiosk-shell.so'
    for path in [package / 'wp_weston', *modules.values()]:
        if not path.is_file():
            raise SessionError('incomplete PortMaster Weston runtime: ' + path.name)
    return dict(PATH=os.defpath + ':/usr/trimui/bin',
                LD_LIBRARY_PATH=str(libraries) + ':/usr/lib', XDG_RUNTIME_DIR=str(xdg),
                WESTON_MODULE_MAP=';'.join(k + '.so=' + str(v) for k, v in modules.items()) + ';',
                WESTON_DATA_DIR=str(package / 'data'), WESTON_LIBEXEC_DIR=str(package / 'libexec'),
                XKB_CONFIG_ROOT=str(package / 'share/xkb'), LIBSEAT_BACKEND='builtin')


def client_environment(runtime, package, endpoint, inherited):
    env = dict(inherited)
    paths = [runtime / 'portable-wayland', package / 'lib_aarch64',
             package / 'lib_aarch64/extra_wayland']
    env['LD_LIBRARY_PATH'] = ':'.join(map(str, paths)) + (
        ':' + env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')
    env.update(SDL_VIDEODRIVER='wayland', WAYLAND_DISPLAY=str(endpoint), DISABLE_WSI_LAYER='1',
               XKB_CONFIG_ROOT=str(package / 'share/xkb'),
               VK_LAYER_PATH=str(runtime / 'vulkan-wsi'),
               RUDROID_VULKAN_WSI_LIBRARY=str(runtime / 'vulkan-wsi/libVkLayer_window_system_integration.so'))
    env.pop('LIBGL_FB', None)
    # An absolute display socket leaves the game's Pulse/XDG audio route intact.
    return env


def stop_owned(process, seconds=5):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        print('[WAYLAND] owned child did not stop; terminating its process group', file=sys.stderr)
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def wait_game(client, compositor):
    # Block on child exits: no gameplay polling, diagnostic thread or periodic I/O.
    while True:
        pid, status = os.waitpid(-1, 0)
        if pid == client.pid:
            client.returncode = os.waitstatus_to_exitcode(status)
            return client.returncode
        if pid == compositor.pid:
            compositor.returncode = os.waitstatus_to_exitcode(status)
            print('[WAYLAND] compositor exited before the game', file=sys.stderr)
            stop_owned(client, seconds=10)
            return 1


def run_session(runtime, image, logs, command, probe=False):
    logs.mkdir(parents=True, exist_ok=True)
    # One DRM lease across titles; never kill another compositor or game.
    descriptor = os.open('/tmp/rudroid-wayland-session.lock', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _owned_session(runtime, image, logs, command, probe)


def _owned_session(runtime, image, logs, command, probe):
    # Only this fresh directory may be mounted, unmounted or removed.
    root = Path(tempfile.mkdtemp(prefix='rudroid-wayland-'))
    package, xdg = root / 'weston', root / 'xdg'
    package.mkdir(); xdg.mkdir(mode=0o700)
    mounted = False
    compositor = client = None
    previous = {}
    def cancel(signum, _frame):
        if client is None:
            raise SessionError('portable session cancelled')
        # wait_game owns reaping. poll() here could consume the game's exit
        # while waitpid is interrupted, leaving it waiting on Weston forever.
        if client.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(client.pid, signum)
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous[sig] = signal.signal(sig, cancel)
        subprocess.run(['mount', '-o', 'loop,ro,exec,nosuid,nodev', str(image), str(package)],
                       check=True, timeout=10, stdout=sys.stderr)
        mounted = True
        env = server_environment(package, xdg)
        endpoint = xdg / 'rudroid-vulkan'
        server = [str(package / 'wp_weston'), '--backend=drm', '--drm-device=card0', '--renderer=gl',
                  '--shell=kiosk-shell.so', '--socket=rudroid-vulkan', '--no-config', '--idle-time=0',
                  '--continue-without-input', '--current-mode', '--log=' + str(logs / 'weston.log')]
        with (logs / 'weston-stderr.log').open('w') as output:
            compositor = subprocess.Popen(server, env=env, stdin=subprocess.DEVNULL,
                                          stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 8
            while compositor.poll() is None and time.monotonic() < deadline:
                if endpoint.exists() and stat.S_ISSOCK(endpoint.stat().st_mode):
                    break
                time.sleep(0.05)
            else:
                raise SessionError('Weston did not establish its private display')
            env = client_environment(runtime, package, endpoint, os.environ)
            client = subprocess.Popen(command, env=env, start_new_session=True)
            with contextlib.suppress(OSError):
                Path('/proc', str(client.pid), 'oom_score_adj').write_text('0')
            if probe:
                try:
                    return client.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    raise SessionError('Vulkan preflight timed out')
            return wait_game(client, compositor)
    finally:
        stop_owned(client)
        stop_owned(compositor)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if mounted:
            # Failed unmounts retain the mountpoint; never walk a mounted runtime.
            subprocess.run(['umount', str(package)], check=True, timeout=10, stdout=sys.stderr)
        import shutil
        shutil.rmtree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--weston-image', required=True, type=Path)
    parser.add_argument('--log-dir', type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--probe', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        runtime, image = args.runtime.resolve(), args.weston_image.resolve()
        validate(runtime, image)
        if args.check:
            return 0
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if args.probe:
            command = [str(runtime / 'unityloader'), str(runtime / 'rudroid.runtime'), '--probe-vulkan']
        if not command or args.log_dir is None:
            parser.error('--log-dir and a command (or --probe) are required')
        result = run_session(runtime, image, args.log_dir.resolve(), command, args.probe)
        return result if result >= 0 else 128 - result
    except (SessionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('[WAYLAND] ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
