#!/usr/bin/env python3
# INPUT:  显式游戏/工具路径、原始命令参数、可选 --quiet 与 Linux mount namespace/mountinfo
# OUTPUT: 完整执行视图中的原命令进程，保留 PID、参数、信号与退出码
# POS:    开发测试的共享启动入口，在私有挂载空间处理相关路径的 noexec
"""Run a command without changing the frontend's mount view."""

import argparse
import errno
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys


NOEXEC = 8


def _inside(path, root):
    return path == root or root in path.parents


def _mount_targets(roots, mountinfo):
    points = set()
    for line in mountinfo.read_text(errors="surrogateescape").splitlines():
        fields = line.split()
        if len(fields) < 10 or "-" not in fields:
            raise ValueError("invalid mountinfo record")
        points.add(Path(re.sub(r"\\([0-7]{3})",
                               lambda match: chr(int(match[1], 8)), fields[4])))
    selected = set()
    for root in roots:
        ancestors = [point for point in points if _inside(root, point)]
        if not ancestors:
            raise ValueError("no mount found for " + str(root))
        selected.add(max(ancestors, key=lambda point: len(point.parts)))
        selected.update(point for point in points if _inside(point, root))
    targets = []
    for point in sorted(selected, key=str):
        flags = os.statvfs(point).f_flag
        if flags & NOEXEC:
            targets.append((point, flags))
    return targets


def _unshare_mounts():
    try:
        import ctypes
    except ImportError as error:
        raise RuntimeError("Python ctypes is unavailable; use the firmware's normal entry") from error
    before = os.readlink("/proc/self/ns/mnt")
    libc = ctypes.CDLL(None, use_errno=True)
    unshare = libc.unshare
    unshare.argtypes = [ctypes.c_int]
    unshare.restype = ctypes.c_int
    if unshare(0x00020000):  # CLONE_NEWNS; no user-namespace privilege shortcut.
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if os.readlink("/proc/self/ns/mnt") == before:
        raise RuntimeError("mount namespace did not change")


def prepare_exec_view(roots, mountinfo=Path("/proc/self/mountinfo")):
    roots = [Path(root).resolve(strict=True) for root in roots]
    if any(root == Path("/") for root in roots):
        raise ValueError("provide game/tool paths below the filesystem root")
    if sys.platform != "linux":
        return []
    targets = _mount_targets(roots, mountinfo)
    if not targets:
        return []
    mount = shutil.which("mount")
    if mount is None:
        raise RuntimeError("mount is unavailable; use the firmware's normal entry")
    _unshare_mounts()
    # Privatize propagation before changing any inherited mount. No bind mount
    # is added: existing runtime submounts must remain visible and usable.
    subprocess.run([mount, "--make-rprivate", "/"], check=True)
    for point, flags in targets:
        subprocess.run([mount, "-o", "remount,bind,exec", str(point)], check=True)
        updated = os.statvfs(point).f_flag
        if updated & NOEXEC or (updated & ~NOEXEC) != (flags & ~NOEXEC):
            raise RuntimeError("mount flags were not preserved for " + str(point))
    # exec replaces this interpreter. Mounts disappear with the last process
    # in this namespace; no supervisor, resource copies or global restore trap.
    return [str(point) for point, _ in targets]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="append", required=True,
                        help="game/tool path; repeat for dependencies on other mounts")
    parser.add_argument("--quiet", action="store_true", help="only report failures")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("provide the original command after --")
    try:
        changed = prepare_exec_view(args.root)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("[exec-view] cannot prepare execution environment: " + str(error),
              file=sys.stderr)
        return 78
    if not args.quiet:
        print("[exec-view] " + ("private exec mounts: " + ", ".join(changed)
                                if changed else "existing execution view"),
              file=sys.stderr, flush=True)
    # Match subprocess's normal restore_signals behavior before replacing
    # Python: its ignored SIGPIPE/SIGXFSZ must not leak into the game launcher.
    for name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ"):
        number = getattr(signal, name, None)
        if number is not None:
            signal.signal(number, signal.SIG_DFL)
    try:
        os.execvp(command[0], command)
    except OSError as error:
        print("[exec-view] cannot execute command: " + str(error), file=sys.stderr)
        return 127 if error.errno == errno.ENOENT else 126


if __name__ == "__main__":
    sys.exit(main())
