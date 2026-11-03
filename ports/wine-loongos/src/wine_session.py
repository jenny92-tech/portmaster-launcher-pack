#!/usr/bin/env python3
# INPUT:  Linux namespace、机型环境、共享图形实现、原游戏与本地准备副本
# OUTPUT: 独立 prefix 中的 Vulkan/Wayland 游戏会话、正常关窗请求与退出码
# POS:    按环境选择共享实现，为每个游戏隔离文件、存档、网络和正常退出
from __future__ import annotations

import argparse
import ctypes as c
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import time

from wine_catalog import GAME_ENV, load_definition, relative_path, resolve_components


GRAPHICS_ENV = GAME_ENV


def session_directory(runtime: Path, game: Path) -> Path:
    identity = hashlib.sha256(os.fsencode(game.resolve())).hexdigest()[:16]
    return runtime / "sessions" / identity


def request_close(state: Path, token=""):
    # The guest can write work/, so never follow a guest-created symlink here.
    fd = os.open(state / "work/close-request", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, ("close " + token + "\n").encode() if token else b"close\n")
    finally:
        os.close(fd)


def ensure_not_running(state: Path):
    pid_file = state / "namespace-pid.txt"
    if pid_file.is_file():
        pid = int(pid_file.read_text().strip())
        try:
            root = os.readlink("/proc/" + str(pid) + "/root")
        except FileNotFoundError:
            return
        if root == str(state / "root"):
            raise RuntimeError("该游戏会话仍在运行或等待正常退出")


def prepare(runtime: Path, game: Path, executable: str, override: Path | None, graphics=None) -> Path:
    state = session_directory(runtime, game)
    work, staged = state / "work", state / "game"
    for directory in (state, work, staged):
        if directory.is_symlink():
            raise RuntimeError("会话目录不能是符号链接")
        directory.mkdir(parents=True, exist_ok=True)
    for name in ("home", "cache"):
        if (work / name).is_symlink():
            raise RuntimeError("游戏用户目录不能是符号链接")
        (work / name).mkdir(exist_ok=True)
    template, prefix = runtime / "prefixes/default", work / "prefix"
    if prefix.is_symlink():
        raise RuntimeError("游戏 prefix 不能是符号链接")
    if not prefix.exists():
        for source in template.rglob("*"):
            relative = source.relative_to(template)
            target = prefix / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_symlink():
                target.symlink_to(source.readlink())
            elif source.is_dir():
                target.mkdir(exist_ok=True)
            elif source.suffix == ".reg" or "users" in relative.parts or (
                source.stat().st_size < 65536 and source.suffix.lower() not in {".dll", ".exe", ".drv", ".cpl", ".ocx"}
            ):
                shutil.copy2(source, target)
            else:
                target.symlink_to(Path("/prefix-original") / relative)
    dlls = graphics["dlls"] if graphics else []
    for target in staged.iterdir():
        if target.is_symlink() and str(target.readlink()).startswith("/runtime/graphics/") and target.name not in dlls:
            target.unlink()
    for source in game.iterdir():
        if source.name in {executable, *dlls}:
            continue
        target = staged / source.name
        if not target.is_symlink() and not target.exists():
            target.symlink_to(Path("/game-original") / source.name)
    for name in (executable, *dlls):
        target = staged / name
        if name == executable and override is not None:
            if target.is_symlink():
                raise RuntimeError("已准备的 EXE 类型与当前配置不一致")
            shutil.copy2(override, target)
        else:
            source = Path("/game-original") / name if name == executable else Path("/runtime") / graphics["directory"] / name
            if target.is_symlink():
                if target.readlink() != source:
                    if str(target.readlink()).startswith("/runtime/graphics/"):
                        target.unlink()
                        target.symlink_to(source)
                    else:
                        raise RuntimeError("已准备的游戏链接与当前配置不一致")
            elif not target.exists():
                target.symlink_to(source)
            else:
                raise RuntimeError("已准备的游戏文件与当前配置不一致")
    return state


def isolate(runtime: Path, state: Path, game: Path, machine_environment, resource_overrides):
    libc = c.CDLL(None, use_errno=True)
    libc.mount.argtypes = [c.c_char_p, c.c_char_p, c.c_char_p, c.c_ulong, c.c_char_p]
    libc.mount.restype = libc.prctl.restype = c.c_int
    root = state / "root"
    root.mkdir(exist_ok=True)

    def check(result, operation):
        if result < 0:
            error = c.get_errno()
            raise OSError(error, operation + ": " + os.strerror(error))

    def mount(source, target, kind=None, flags=0, data=None):
        values = [os.fsencode(x) if x is not None else None for x in (source, target, kind, data)]
        check(libc.mount(values[0], values[1], values[2], flags, values[3]), "mount " + str(target))

    def bind(source, destination, readonly=True):
        source, target = Path(source), root / destination.lstrip("/")
        if source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.touch(exist_ok=True)
        mount(source, target, flags=4096)
        if readonly:
            mount(None, target, flags=4096 | 32 | 1 | 2)

    mount(None, "/", flags=(1 << 18) | 16384)
    # A fresh root prevents a previous guest from leaving host-side mount targets.
    mount("tmpfs", root, "tmpfs", 2 | 4, "size=32m,mode=755")
    for name in ("usr", "proc", "dev/shm", "run", "tmp", "etc", "work", "root"):
        (root / name).mkdir(parents=True, exist_ok=True)
    for name, target in (("lib", "usr/lib"), ("lib64", "lib"), ("bin", "usr/bin"), ("sbin", "usr/sbin")):
        (root / name).symlink_to(target)
    bind("/usr", "/usr")
    bind("/etc/ld.so.cache", "/etc/ld.so.cache")
    if Path("/etc/fonts").is_dir():
        bind("/etc/fonts", "/etc/fonts")
    for name, text in {
        "passwd": "root:x:0:0:Wine:/root:/bin/sh\n", "group": "root:x:0:\n",
        "nsswitch.conf": "passwd: files\ngroup: files\nhosts: files\n",
        "hosts": "127.0.0.1 localhost\n::1 localhost\n",
    }.items():
        (root / "etc" / name).write_text(text)
    mount("tmpfs", root / "tmp", "tmpfs", 2 | 4, "size=128m,mode=1777")
    mount("tmpfs", root / "dev/shm", "tmpfs", 2 | 4 | 8, "size=64m,mode=1777")
    for source in filter(None, machine_environment["bind_files"].values()):
        if Path(source).exists():
            bind(source, source, readonly=False)
    for directory in map(Path, filter(None, machine_environment["bind_device_directories"].values())):
        if directory.is_dir():
            for source in directory.iterdir():
                if directory.name == "dma_heap" or source.name.startswith("control") or source.name.endswith("p") or source.name == "timer":
                    bind(source, str(source), readonly=False)
    bind(runtime / "runtime", "/runtime")
    bind(runtime / "prefixes/default", "/prefix-original")
    bind(game, "/game-original")
    bind(state / "game", "/game")
    bind(state / "work", "/work", readonly=False)
    if (state / "work/loading.bgra").is_file():
        bind(state / "work/loading.bgra", "/work/loading.bgra")
    mount("proc", root / "proc", "proc", 1 | 2 | 4 | 8)
    mount(None, root, flags=32 | 1 | 2 | 4)
    os.chroot(root)
    os.chdir("/game")
    for target, source in resource_overrides.items():
        # The private namespace overlays prepared copies; the host's original
        # game files remain read-only and are never rewritten.
        mount("/game-original/" + source, "/game/" + target, flags=4096)
        mount(None, "/game/" + target, flags=4096 | 32 | 1 | 2)
    for capability in range(64):
        result = libc.prctl(24, capability, 0, 0, 0)
        if result < 0 and c.get_errno() != errno.EINVAL:
            check(result, "drop capability")
    check(libc.prctl(28, 3, 0, 0, 0), "securebits")

    class Header(c.Structure):
        _fields_ = [("version", c.c_uint32), ("pid", c.c_int)]

    class Data(c.Structure):
        _fields_ = [("effective", c.c_uint32), ("permitted", c.c_uint32), ("inheritable", c.c_uint32)]

    check(libc.capset(c.byref(Header(0x20080522, 0)), (Data * 2)()), "clear capabilities")
    check(libc.prctl(38, 1, 0, 0, 0), "no_new_privs")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_NOFILE, (1024, 1024))
    fields = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
    assert os.getpid() == 1 and fields["NoNewPrivs"].strip() == "1"
    assert all(int(fields[key], 16) == 0 for key in ("CapEff", "CapPrm", "CapBnd", "CapAmb"))
    assert len(Path("/proc/net/dev").read_text().strip().splitlines()) == 3
    assert not Path("/mnt/sdcard").exists()
    for directory in ("/usr", "/runtime", "/game-original", "/game", "/"):
        try:
            (Path(directory) / ".wine-write-check").touch()
        except OSError as exc:
            assert exc.errno == errno.EROFS
        else:
            raise RuntimeError("隔离目录可写：" + directory)
    os.closerange(3, 1024)
    print("ISOLATION_VERIFIED pid=1 capabilities=0 no_new_privs=1 network=lo system_runtime_game=readonly", flush=True)


def coordinate(executable: str, arguments: list[str], environment: dict[str, str], machine_environment, graphics=None, borderless_size=None, presentation_token="") -> int:
    wine_root = "/runtime/" + machine_environment["wine_root"]
    dlls = ",".join(Path(name).stem for name in graphics["dlls"]) if graphics else ""
    overrides = (dlls + "=n;" if dlls else "") + "winemenubuilder.exe=d;mscoree,mshtml="
    env = dict(machine_environment["process_environment"], **environment)
    env.update(PATH="/usr/bin:/bin", HOME="/work/home", XDG_CACHE_HOME="/work/cache", USER="root", LOGNAME="root", LANG="C.UTF-8",
               LD_LIBRARY_PATH="/runtime/native-lib", WINEPREFIX="/work/prefix", WINEARCH="win64", WINEDEBUG="-all",
               WINEDLLOVERRIDES=overrides, BOX64_LOG="0", BOX64_NOBANNER="1",
               BOX64_PATH=wine_root + "/bin:/runtime/bin", BOX64_LD_LIBRARY_PATH=wine_root + "/lib/wine/x86_64-unix:/runtime/" + machine_environment["x86_library_path"],
               WINELOADER=wine_root + "/bin/wine", WINESERVER=wine_root + "/bin/wineserver", DXVK_LOG_PATH="/work")
    if presentation_token:
        env["WINE_RUNNER_PRESENT_TOKEN"] = presentation_token
    if borderless_size and graphics and machine_environment.get("handheld_startup"):
        env.update(WINE_RUNNER_FULLSCREEN="1", WINE_RUNNER_WIDTH=str(borderless_size[0]), WINE_RUNNER_HEIGHT=str(borderless_size[1]))
    os.environ.clear()
    os.environ.update(env)
    wine = ["/runtime/bin/box64", wine_root + "/bin/wine"]
    target = ["Z:\\game\\" + executable, *arguments]
    if borderless_size:
        target = ["Z:\\runtime\\graphics\\wine-borderless.exe", *map(str, borderless_size), *target]
    process = subprocess.Popen(wine + target, env=env)
    helper, server_wait, close_sent = None, None, False
    # This is PID 1. Retain the namespace on coordination errors; never kill an
    # active vendor graphics client because an input helper or logger failed.
    while True:
        try:
            if process.poll() is not None and server_wait is None:
                print("GAME_PROCESS_EXIT", process.returncode, flush=True)
                server_wait = subprocess.Popen(["/runtime/bin/box64", wine_root + "/bin/wineserver", "-w"], env=env)
            if server_wait is not None and server_wait.poll() is not None:
                print("WINE_SESSION_EXIT", process.returncode, flush=True)
                return process.returncode if server_wait.returncode == 0 else 125
            with Path("/work/close-request").open("rb") as request:
                expected = ("close " + presentation_token + "\n").encode() if presentation_token else b"close\n"
                close_requested = request.read(80) == expected
            if close_requested and not close_sent:
                helper = subprocess.Popen(wine + ["Z:\\runtime\\graphics\\wine-close.exe"], env=env)
                close_sent = True
                print("NORMAL_WINDOW_CLOSE_REQUESTED", flush=True)
            if helper is not None:
                helper.poll()
            time.sleep(.1)
        except BaseException as exc:
            print("COORDINATOR_ERROR_SESSION_RETAINED", type(exc).__name__, flush=True)
            time.sleep(2)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--game", required=True, type=Path)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--override", type=Path)
    parser.add_argument("--environment", default="{}")
    parser.add_argument("--machine-environment", type=Path, required=True)
    parser.add_argument("--graphics-api", default="")
    parser.add_argument("--resource-overrides", default="{}")
    parser.add_argument("--borderless-size", type=int, nargs=2, metavar=("WIDTH", "HEIGHT"))
    parser.add_argument("--presentation-token", default="")
    parser.add_argument("--startup-card", type=Path)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.presentation_token and (len(args.presentation_token) != 32 or any(x not in "0123456789abcdef" for x in args.presentation_token)):
        parser.error("启动画面 token 无效")
    if args.startup_card and (not args.borderless_size or args.startup_card.is_symlink() or not args.startup_card.is_file() or
                             args.startup_card.stat().st_size != args.borderless_size[0] * args.borderless_size[1] * 4):
        parser.error("启动画面与机型全屏尺寸不一致")
    if args.borderless_size and not (320 <= args.borderless_size[0] <= 4096 and 200 <= args.borderless_size[1] <= 4096):
        parser.error("无边框全屏宽高超出支持范围")
    runtime, game = args.runtime.resolve(), args.game.resolve()
    if Path(args.executable).name != args.executable or not (game / args.executable).is_file():
        parser.error("图形会话需要游戏目录顶层的 EXE")
    if args.override:
        args.override = args.override.resolve()
        args.override.relative_to(game)
        if not args.override.is_file():
            parser.error("EXE 副本不存在")
    resource_overrides = json.loads(args.resource_overrides)
    if not isinstance(resource_overrides, dict):
        parser.error("资源覆盖应为对象")
    for target, source in resource_overrides.items():
        relative_path(target)
        prepared = relative_path(source)
        if prepared.parts[:2] != (".wine", "patched"):
            parser.error("资源覆盖必须来自玩家目录中的已准备副本")
        for relative in [target, source]:
            path = game / relative
            path.resolve().relative_to(game)
            if not path.is_file():
                parser.error("资源覆盖文件不存在")
    environment = json.loads(args.environment)
    if not isinstance(environment, dict) or not set(environment).issubset(GRAPHICS_ENV):
        parser.error("图形会话包含不支持的环境选项")
    machine_environment = load_definition(args.machine_environment, args.machine_environment.parent)
    _, graphics = resolve_components(machine_environment, args.graphics_api, args.machine_environment.parent.parent)
    if graphics:
        for name in graphics["dlls"]:
            if not (runtime / "runtime" / graphics["directory"] / name).is_file():
                raise RuntimeError("缺少共享图形组件：" + name)
    if not (runtime / "runtime/graphics/wine-close.exe").is_file():
        raise RuntimeError("缺少正常关窗组件")
    if args.borderless_size and not (runtime / "runtime/graphics/wine-borderless.exe").is_file():
        raise RuntimeError("运行包缺少组件：graphics/wine-borderless.exe")
    state = session_directory(runtime, game)
    state.mkdir(parents=True, exist_ok=True)
    with (runtime / "environment.lock").open("a+") as environment_lock, (state / "session.lock").open("w") as lock:
        fcntl.flock(environment_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        ensure_not_running(state)
        prepare(runtime, game, args.executable, args.override, graphics)
        card = state / "work/loading.bgra"
        if card.is_symlink():
            raise RuntimeError("启动画面不能是符号链接")
        if args.startup_card:
            shutil.copyfile(args.startup_card, card)
        elif card.exists():
            card.unlink()
        # Reuse a regular request file, refusing guest-created links.
        # A request may already belong to this launch while preparation runs.
        # Per-launch tokens make older requests harmless without erasing a new one.
        fd = os.open(state / "work/close-request", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        # Empty means no request; a close request contains the word 'close'.
        libc = c.CDLL(None, use_errno=True)
        if libc.unshare(0x40000000 | 0x20000 | 0x20000000 | 0x08000000 | 0x04000000) < 0:
            raise OSError(c.get_errno(), "unshare")
        child = os.fork()
        if child == 0:
            try:
                isolate(runtime, state, game, machine_environment, resource_overrides)
                arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
                os._exit(coordinate(args.executable, arguments, environment, machine_environment, graphics, args.borderless_size, args.presentation_token))
            except BaseException:
                import traceback
                traceback.print_exc()
                os._exit(125)
        (state / "namespace-pid.txt").write_text(str(child) + "\n")
        print("WINE_NAMESPACE_PID", child, flush=True)
        signal.signal(signal.SIGTERM, lambda *_: request_close(state, args.presentation_token))
        signal.signal(signal.SIGINT, lambda *_: request_close(state, args.presentation_token))
        _, status = os.waitpid(child, 0)
        return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    raise SystemExit(main())
