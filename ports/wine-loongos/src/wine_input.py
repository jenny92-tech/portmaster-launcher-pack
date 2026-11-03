#!/usr/bin/env python3
# INPUT:  可选 PortMaster/随包输入工具、SDL 映射、游戏方案及私有运行目录
# OUTPUT: 公用输入来源选择、键鼠转换进程、退出组合键检测与清理接口
# POS:    优先复用 PortMaster 输入并管理菜单与 Wine 的手柄独占交接
from __future__ import annotations

import os
import fcntl
import hashlib
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
from wine_catalog import launcher_asset


EVENT = struct.Struct("llHHi")
EVIOCGRAB = 0x40044590


def _aarch64_elf(path):
    try:
        with path.open("rb") as source:
            header = source.read(20)
        return (header[:7] == b"\x7fELF\x02\x01\x01" and len(header) == 20
                and int.from_bytes(header[16:18], "little") in (2, 3)
                and int.from_bytes(header[18:20], "little") == 183)
    except OSError:
        return False


def resolve_input(profile, app_root, base):
    """Select once for both menu and game; installed control scripts stay unexecuted."""
    selected = dict(profile)
    bundled = {key: str(launcher_asset(profile.get(key, default), app_root).resolve()) for key, default in (
        ("input_helper", "bin/gptokeyb2"), ("input_library", "lib/libinterpose.aarch64.so"))}
    selected.update(bundled)
    selected["input_source"] = "bundled"
    xdg = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    roots = [Path(path.replace("{xdg_data_home}", xdg)) for path in profile.get("portmaster_directories", [])]
    database = launcher_asset(profile.get("controller_database", "share/gamecontrollerdb.txt"), app_root)
    databases = [database]
    for root in roots:
        candidate = root / "gamecontrollerdb.txt"
        if candidate.is_file():
            databases.append(candidate)
            break
    if profile.get("machine") == "aarch64":
        for root in roots:
            helper, library = root / "gptokeyb2", root / "libinterpose.aarch64.so"
            if _aarch64_elf(helper) and _aarch64_elf(library):
                selected.update(input_helper=str(helper.resolve()), input_library=str(library.resolve()),
                                input_source="PortMaster", input_fallback=bundled)
                break

    # Later SDL mappings override earlier GUIDs, including PortMaster get_controls
    # output exported by a parent entry. Snapshot it before using a private HOME.
    databases.append(Path.home() / ".config/SDL-GameControllerDB/gamecontrollerdb.txt")
    if os.environ.get("SDL_GAMECONTROLLERCONFIG_FILE"):
        databases.append(Path(os.environ["SDL_GAMECONTROLLERCONFIG_FILE"]))
    chunks, sources = [], []
    for path in databases:
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if data.strip() and str(path) not in sources:
            chunks.append(data.rstrip(b"\n") + b"\n")
            sources.append(str(path))
    for name in ("sdl_controllerconfig", "SDL_GAMECONTROLLERCONFIG"):
        if os.environ.get(name, "").strip():
            chunks.append(os.environ[name].encode() + b"\n")
            sources.append(name)
    if not chunks:
        raise RuntimeError("缺少控制器数据库：" + str(database))
    data = b"".join(chunks)
    directory = Path(base) / ".input"
    directory.mkdir(parents=True, exist_ok=True)
    snapshot = directory / (hashlib.sha256(data).hexdigest() + ".txt")
    if not snapshot.is_file() or snapshot.read_bytes() != data:
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
            temporary = Path(output.name)
            try:
                output.write(data)
                output.close()
                temporary.replace(snapshot)
            finally:
                temporary.unlink(missing_ok=True)
    selected.update(controller_database=str(snapshot.resolve()), controller_database_sources=sources)
    return selected


def grab_sdl_controller(device):
    """Grab SDL's existing evdev client so the firmware cannot also act on it."""
    expected = os.path.realpath(device)
    for descriptor in os.listdir("/proc/self/fd"):
        try:
            if os.path.realpath(os.readlink("/proc/self/fd/" + descriptor)) == expected:
                fd = int(descriptor)
                fcntl.ioctl(fd, EVIOCGRAB, 1)
                return fd
        except FileNotFoundError:
            continue
    raise RuntimeError("未找到 SDL 打开的掌机手柄；无法隔离系统首页按键")


class ExitChord:
    def __init__(self):
        self.keys = set()
        self.started = None

    def update(self, kind, code, value, now):
        if kind == 1 and code in (56, 62):  # left Alt and F4 emitted by Select+Start
            if value:
                self.keys.add(code)
            else:
                self.keys.discard(code)
            if self.keys == {56, 62}:
                if self.started is None:
                    self.started = now
            else:
                self.started = None

    def held(self, now):
        return self.started is not None and now - self.started >= 1.5


class InputSession:
    def __init__(self, profile, app_root, game):
        self.profile, self.app_root, self.game = profile, Path(app_root), game
        self.process = self.keyboard_fd = self.log = None
        self.exit_chord = ExitChord()

    def __enter__(self):
        choices = [self.profile]
        if self.profile.get("input_fallback"):
            choices.append(self.profile["input_fallback"])
        for index, choice in enumerate(choices):
            try:
                return self._start(choice)
            except (OSError, RuntimeError) as error:
                self.close()
                if index == len(choices) - 1:
                    raise
                print("PortMaster 输入工具不可用，改用随包工具：", str(error), flush=True)
            except BaseException:
                self.close()
                raise

    def _start(self, tools):
        root = Path(self.profile["runtime_mount"]) / "input"
        root.mkdir(parents=True, exist_ok=True)
        helper = launcher_asset(tools["input_helper"], self.app_root)
        library = launcher_asset(tools["input_library"], self.app_root)
        for source in (helper, library):
            if not source.is_file():
                raise RuntimeError("启动器缺少配套输入工具：" + str(source))
            target = root / source.name
            if not target.is_file() or target.read_bytes() != source.read_bytes():
                shutil.copyfile(source, target)
        (root / helper.name).chmod(0o755)
        mapping = self.game.input_mapping or self.app_root / "desktop.gptk"
        env = dict(os.environ, SDL_GAMECONTROLLERCONFIG_FILE=str(launcher_asset(self.profile["controller_database"], self.app_root)),
                   LD_LIBRARY_PATH=str(root), LD_PRELOAD=str(root / library.name))
        for name in ("PCKILLMODE", "NO_PKILL", "HOTKEY"):
            env.pop(name, None)
        private_home = root / "home"
        private_home.mkdir(exist_ok=True)
        env["HOME"] = str(private_home)
        before = set(Path("/sys/class/input").glob("event*"))
        self.log = (Path(self.profile["runtime_mount"]) / "logs/launcher-input.log").open("w" if tools is self.profile else "a")
        print("INPUT_HELPER", str(helper), "INPUT_LIBRARY", str(library),
              "CONTROLLER_DB", env["SDL_GAMECONTROLLERCONFIG_FILE"], file=self.log, flush=True)
        # No program name: gptokeyb2 must never kill processes by name.
        self.process = subprocess.Popen([str(root / helper.name), "-c", str(mapping), "-H", "guide"],
                                        env=env, stdout=self.log, stderr=subprocess.STDOUT,
                                        start_new_session=True)
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("输入转换器启动失败；请查看 logs/launcher-input.log")
            for event in set(Path("/sys/class/input").glob("event*")) - before:
                name = event / "device/name"
                if name.is_file() and name.read_text().strip() == "Fake Keyboard Mouse":
                    try:
                        self.keyboard_fd = os.open("/dev/input/" + event.name, os.O_RDONLY | os.O_NONBLOCK)
                    except FileNotFoundError:
                        continue
                    return self
            time.sleep(0.05)
        raise RuntimeError("输入转换器未创建虚拟键鼠设备")

    def force_exit_requested(self):
        if self.process.poll() is not None:
            raise RuntimeError("输入转换器意外退出；已停止本次游戏")
        while True:
            try:
                data = os.read(self.keyboard_fd, EVENT.size * 32)
            except BlockingIOError:
                break
            if not data:
                break
            for _seconds, _micros, kind, code, value in EVENT.iter_unpack(data):
                self.exit_chord.update(kind, code, value, time.monotonic())
        return self.exit_chord.held(time.monotonic())

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        if self.keyboard_fd is not None:
            os.close(self.keyboard_fd)
            self.keyboard_fd = None
        if self.log is not None:
            self.log.close()
            self.log = None

    def __exit__(self, *_exc):
        self.close()
