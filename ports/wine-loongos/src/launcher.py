#!/usr/bin/env python3
# INPUT:  SDL2/SDL2_ttf、机型环境、ROCKNIX Windows 库与 bottle.json
# OUTPUT: --print-base 路径、--list JSON、手柄游戏列表及独立启动日志
# POS:    把当前掌机的 Box64/Wine 原型组织为可从 Ports 使用的运行器
from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys

from wine_catalog import ROOT, detect_device, load_environment, load_json, load_definition, resolve_components, launcher_asset
from wine_layout import resolve_library, state_directory, offline_directory


def read_profile(path: Path) -> dict:
    profile = load_definition(path, path.parent)
    resolve_library(profile, profile.get("library_directory"))
    if "display_size" in profile:
        size = profile["display_size"]
        if not isinstance(size, list) or len(size) != 2 or not all(type(x) is int for x in size) or not (
            320 <= size[0] <= 4096 and 200 <= size[1] <= 4096
        ):
            raise ValueError("display_size 应为机型实际横屏宽高")
    return profile


def _startup_configuration(argv=None):
    parser = argparse.ArgumentParser(description="Handheld Wine launcher prototype")
    parser.add_argument("--base", type=Path)
    parser.add_argument("--library", type=Path, help="ROCKNIX 布局的 Windows 游戏库目录")
    parser.add_argument("--print-base", action="store_true")
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--game", help="直接打开已安装的游戏适配入口")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--smoke-seconds", type=float, default=0)
    parser.add_argument("--no-lifecycle", action="store_true")
    args = parser.parse_args(argv)
    profile = read_profile(args.profile) if args.profile else detect_device()
    profile["library_directory"] = str(resolve_library(profile, args.library))
    base = Path(args.base or os.environ.get("WINE_RUNNER_HOME") or state_directory(profile["library_directory"])).resolve()
    return args, profile, base


# The shell needs the state directory before opening its log. Exit this probe
# before loading the UI, game session, installer and their standard libraries.
if __name__ == "__main__" and "--print-base" in sys.argv[1:]:
    print(_startup_configuration()[2])
    raise SystemExit(0)

import ctypes as c
import fcntl
import json
import signal
import stat
import subprocess
import time
import queue
import threading
import uuid
import tempfile
from dataclasses import dataclass, field

from wine_input import InputSession, EVIOCGRAB, grab_sdl_controller, resolve_input
from wine_session import GRAPHICS_ENV, session_directory, request_close
from wine_game import adapter_directory, load_adapter, inspect_game
from wine_bottle import load_bottle, check_graphics_dependencies
from wine_ui import LibraryView, Color, Rect
from runtime_install import install, installed


DEFAULT_INPUT_HELP = "摇杆移动鼠标；A 左键，B 右键，X 回车，Y Esc；Select+Start 退出"


@dataclass
class Game:
    title: str
    directory: Path
    executable: Path | None = None
    arguments: list[str] = field(default_factory=list)
    environment: dict[str, str] = field(default_factory=dict)
    status: str = "尚未验证兼容性"
    error: str = ""
    input_mapping: Path | None = None
    graphics_api: str = ""
    adapter_id: str = ""
    screen_arguments: dict = field(default_factory=dict)
    resource_overrides: dict = field(default_factory=dict)
    executable_override: Path | None = None
    input_help: str = DEFAULT_INPUT_HELP
    borderless_fullscreen: bool = False
    config_directories: list[str] = field(default_factory=list)


def read_game(directory: Path, app_root: Path = ROOT, adapter_id: str = "", data=None) -> Game:
    game = Game(directory.name, directory)
    config = directory / "wine-game.json"
    try:
        if adapter_id:
            return read_adapted_game(directory, adapter_id, app_root)
        if data is not None or config.exists():
            data = data if data is not None else json.loads(config.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ValueError("wine-game.json 应为对象")
            if data.get("adapter"):
                return read_adapted_game(directory, data["adapter"], app_root)
            executable = data.get("executable")
            if not isinstance(executable, str) or not executable:
                raise ValueError("wine-game.json 需要 executable")
            candidate = directory / executable
            candidate.resolve().relative_to(directory.resolve())
            if Path(executable).is_absolute() or not candidate.is_file() or candidate.suffix.lower() != ".exe":
                raise ValueError("executable 必须指向本游戏目录内的 EXE")
            arguments = data.get("arguments", [])
            environment = data.get("environment", {})
            if not isinstance(arguments, list) or not all(isinstance(x, str) and "\0" not in x for x in arguments):
                raise ValueError("arguments 应为字符串列表")
            if not isinstance(environment, dict) or not all(
                isinstance(k, str) and isinstance(v, str) and k and "=" not in k and "\0" not in k + v
                for k, v in environment.items()
            ):
                raise ValueError("environment 应为字符串键值对象")
            reserved = {"WINE_RUNNER_HOME", "WINE_RUNNER_MOUNT", "WINEPREFIX", "WINELOADER", "WINESERVER"}
            if reserved.intersection(environment):
                raise ValueError("游戏配置不能改写运行器或 prefix 路径")
            for name in ["title", "status", "input_help"]:
                if name in data and not isinstance(data[name], str):
                    raise ValueError(f"{name} 应为字符串")
            game.title = data.get("title", game.title)
            game.status = data.get("status", game.status)
            game.input_help = data.get("input_help", game.input_help)
            if data.get("input_mode", "desktop") != "desktop":
                raise ValueError("当前仅支持 desktop 键鼠输入；原生手柄尚未适配")
            if data.get("input_mapping"):
                mapping = data["input_mapping"]
                if not isinstance(mapping, str) or Path(mapping).is_absolute():
                    raise ValueError("input_mapping 必须位于游戏目录内")
                game.input_mapping = directory / mapping
                game.input_mapping.resolve().relative_to(directory.resolve())
                if not game.input_mapping.is_file():
                    raise ValueError("自定义输入方案文件不存在")
            game.graphics_api = data.get("graphics_api", "")
            if game.graphics_api not in ("", "d3d9", "d3d10", "d3d11", "d3d12", "vulkan"):
                raise ValueError("未知图形接口")
            if candidate.parent != directory:
                raise ValueError("当前会话需要游戏目录顶层的 EXE")
            if not set(environment).issubset(GRAPHICS_ENV):
                raise ValueError("游戏包含不支持的环境选项")
            game.borderless_fullscreen = data.get("borderless_fullscreen", False)
            if type(game.borderless_fullscreen) is not bool:
                raise ValueError("borderless_fullscreen 需要布尔值")
            if data.get("executable_override"):
                override = data["executable_override"]
                if not isinstance(override, str) or Path(override).is_absolute():
                    raise ValueError("EXE 副本需要游戏目录内的相对路径")
                game.executable_override = directory / override
                game.executable_override.resolve().relative_to(directory.resolve())
                if not game.executable_override.is_file() or game.executable_override.suffix.lower() != ".exe":
                    raise ValueError("EXE 副本不存在或不是 EXE")
            game.executable, game.arguments, game.environment = candidate, arguments, environment
        else:
            ignored = ("unitycrashhandler", "crashreportclient", "unins", "uninstall", "vc_redist", "dxsetup")
            candidates = sorted(p for p in directory.iterdir() if p.is_file() and p.suffix.lower() == ".exe"
                                and not p.name.lower().startswith(ignored))
            # Do not guess between a game, editor and setup executable.
            if len(candidates) != 1:
                raise ValueError("请用 wine-game.json 指定启动 EXE" if candidates else "目录内没有启动 EXE")
            candidates[0].resolve().relative_to(directory.resolve())
            game.executable = candidates[0]
    except (OSError, ValueError, TypeError, KeyError) as exc:
        game.error = str(exc)
        game.status = "需要配置"
        game.executable = None
    return game


def read_adapted_game(directory: Path, adapter_id: str, app_root: Path, adapter_root=None) -> Game:
    adapter = load_adapter(adapter_id, app_root, adapter_root)
    state = inspect_game(directory, adapter)
    return Game(adapter["title"], directory,
                directory / adapter["executable"] if state["state"] == "ready" else None,
                arguments=adapter["arguments"], environment=adapter["environment"],
                status=state["message"], error="" if state["state"] == "ready" else state["message"],
                input_mapping=(adapter_root or adapter_directory(adapter_id, app_root)) / adapter["input_mapping"],
                graphics_api=adapter["graphics_api"], adapter_id=adapter_id,
                executable_override=state["override"], input_help=adapter["input_help"],
                borderless_fullscreen=adapter["borderless_fullscreen"], screen_arguments=adapter.get("screen_arguments", {}),
                resource_overrides=state.get("resource_overrides", {}))


def read_bottle(directory: Path, app_root: Path = ROOT) -> Game:
    game = Game(directory.name, directory / "data", adapter_id=directory.name)
    try:
        bottle = load_bottle(directory)
        settings = dict(bottle["settings"])
        if settings.get("adapter"):
            if settings["adapter"] != directory.name:
                raise ValueError("bottle 目录名与游戏适配标识不一致")
            game = read_adapted_game(bottle["directory"], settings["adapter"], app_root, directory)
        else:
            settings.pop("input_mapping", None)
            game = read_game(bottle["directory"], app_root, data=settings or None)
            game.adapter_id = directory.name
        game.title = bottle["title"]
        if not game.graphics_api and "dxvk" in bottle["dependencies"]:
            raise ValueError("请在 bottle.json 的 wine_runner 中明确 executable 和 graphics_api")
        check_graphics_dependencies(bottle["dependencies"], game.graphics_api)
        game.environment.update(bottle["environment"])
        game.config_directories = bottle["config_directories"]
        if bottle["input_mapping"] is not None:
            game.input_mapping = bottle["input_mapping"]
    except (OSError, ValueError, TypeError, KeyError) as exc:
        game.error, game.status, game.executable = str(exc), "需要配置", None
    return game


def discover_games(base: Path, profile: dict, app_root: Path = ROOT) -> list[Game]:
    library = resolve_library(profile)
    games = []
    if library.is_dir():
        for directory in sorted(library.iterdir()):
            if directory.is_dir() and not directory.name.startswith((".", "_")) and (directory / "bottle.json").is_file():
                try:
                    directory.resolve().relative_to(library)
                except ValueError:
                    continue
                games.append(read_bottle(directory, app_root))
    return sorted(games, key=lambda x: x.title.casefold())


class Menu:
    """Native SDL menu hosted by the launcher's bundled interpreter."""

    def __init__(self, profile: dict, fullscreen=True):
        self.sdl = c.CDLL("libSDL2-2.0.so.0")
        self.ttf = c.CDLL("libSDL2_ttf-2.0.so.0")
        pointer, integer, string = c.c_void_p, c.c_int, c.c_char_p

        def bind(lib, name, result, *args):
            fn = getattr(lib, name)
            fn.restype, fn.argtypes = result, list(args)
            return fn

        specs = [
            ("SDL_Init", integer, c.c_uint32), ("SDL_Quit", None),
            ("SDL_InitSubSystem", integer, c.c_uint32), ("SDL_QuitSubSystem", None, c.c_uint32),
            ("SDL_GetError", string),
            ("SDL_CreateWindow", pointer, string, integer, integer, integer, integer, c.c_uint32),
            ("SDL_DestroyWindow", None, pointer),
            ("SDL_CreateRenderer", pointer, pointer, integer, c.c_uint32),
            ("SDL_DestroyRenderer", None, pointer),
            ("SDL_GetRendererOutputSize", integer, pointer, c.POINTER(integer), c.POINTER(integer)),
            ("SDL_SetRenderDrawColor", integer, pointer, c.c_uint8, c.c_uint8, c.c_uint8, c.c_uint8),
            ("SDL_SetRenderDrawBlendMode", integer, pointer, integer),
            ("SDL_RenderClear", integer, pointer),
            ("SDL_RenderFillRect", integer, pointer, c.POINTER(Rect)),
            ("SDL_RenderDrawLine", integer, pointer, integer, integer, integer, integer),
            ("SDL_RenderPresent", None, pointer),
            ("SDL_RenderReadPixels", integer, pointer, pointer, c.c_uint32, pointer, integer),
            ("SDL_CreateTextureFromSurface", pointer, pointer, pointer),
            ("SDL_CreateRGBSurfaceFrom", pointer, pointer, integer, integer, integer, integer,
             c.c_uint32, c.c_uint32, c.c_uint32, c.c_uint32),
            ("SDL_QueryTexture", integer, pointer, pointer, pointer, c.POINTER(integer), c.POINTER(integer)),
            ("SDL_RenderCopy", integer, pointer, pointer, pointer, c.POINTER(Rect)),
            ("SDL_DestroyTexture", None, pointer), ("SDL_FreeSurface", None, pointer),
            ("SDL_WaitEventTimeout", integer, pointer, integer),
            ("SDL_PollEvent", integer, pointer),
            ("SDL_PumpEvents", None), ("SDL_FlushEvents", None, c.c_uint32, c.c_uint32),
            ("SDL_GetKeyboardState", c.POINTER(c.c_uint8), c.POINTER(integer)),
            ("SDL_NumJoysticks", integer), ("SDL_IsGameController", integer, integer),
            ("SDL_GameControllerOpen", pointer, integer), ("SDL_GameControllerClose", None, pointer),
            ("SDL_GameControllerGetButton", c.c_uint8, pointer, integer),
            ("SDL_JoystickOpen", pointer, integer), ("SDL_JoystickClose", None, pointer),
            ("SDL_JoystickGetButton", c.c_uint8, pointer, integer),
            ("SDL_RWFromFile", pointer, string, string),
            ("SDL_GameControllerAddMappingsFromRW", integer, pointer, integer),
        ]
        for name, result, *args in specs:
            bind(self.sdl, name, result, *args)
        bind(self.ttf, "TTF_Init", integer)
        bind(self.ttf, "TTF_Quit", None)
        bind(self.ttf, "TTF_OpenFont", pointer, string, integer)
        bind(self.ttf, "TTF_CloseFont", None, pointer)
        bind(self.ttf, "TTF_SetFontStyle", None, pointer, integer)
        bind(self.ttf, "TTF_SizeUTF8", integer, pointer, string, c.POINTER(integer), c.POINTER(integer))
        bind(self.ttf, "TTF_RenderUTF8_Blended", pointer, pointer, string, Color)
        self.window = self.renderer = None
        self.view = None
        self.selected = 0
        self.progress_scene = None
        self.controller_grab_fd = None
        self.controllers, self.joysticks = [], []
        if self.sdl.SDL_Init(0x20) != 0 or self.ttf.TTF_Init() != 0:
            raise RuntimeError(self.sdl.SDL_GetError().decode(errors="replace"))
        try:
            database = launcher_asset(profile.get("controller_database", ""))
            if database.is_file():
                rw = self.sdl.SDL_RWFromFile(os.fsencode(database), b"rb")
                if rw:
                    self.sdl.SDL_GameControllerAddMappingsFromRW(rw, 1)
            self.resume_input(profile)
            self.window = self.sdl.SDL_CreateWindow("Je-Wine".encode(), 0x2FFF0000, 0x2FFF0000,
                                                   *profile["display_size"], 0x1001 if fullscreen else 0x8)
            if not self.window:
                raise RuntimeError(self.sdl.SDL_GetError().decode(errors="replace"))
            self.renderer = self.sdl.SDL_CreateRenderer(self.window, -1, 1)
            if not self.renderer:
                raise RuntimeError(self.sdl.SDL_GetError().decode(errors="replace"))
            width, height = integer(), integer()
            self.sdl.SDL_GetRendererOutputSize(self.renderer, c.byref(width), c.byref(height))
            self.width, self.height = width.value, height.value
            self.view = LibraryView(self.sdl, self.ttf, self.renderer, self.width, self.height, launcher_asset(profile["font"]))
            self.view.font(18 * self.view.scale)
        except BaseException:
            self.close()
            raise

    def release_input(self):
        """Release physical input while keeping the fullscreen surface mapped."""
        if self.controller_grab_fd is not None:
            try:
                fcntl.ioctl(self.controller_grab_fd, EVIOCGRAB, 0)
            except OSError:
                pass
            self.controller_grab_fd = None
        for handle in self.controllers:
            self.sdl.SDL_GameControllerClose(handle)
        for handle in self.joysticks:
            self.sdl.SDL_JoystickClose(handle)
        self.controllers.clear()
        self.joysticks.clear()
        self.sdl.SDL_QuitSubSystem(0x2200)

    def resume_input(self, profile):
        if self.sdl.SDL_InitSubSystem(0x2200) != 0:
            raise RuntimeError("无法初始化掌机手柄")
        for i in range(self.sdl.SDL_NumJoysticks()):
            if self.sdl.SDL_IsGameController(i):
                handle = self.sdl.SDL_GameControllerOpen(i)
                if handle:
                    self.controllers.append(handle)
            else:
                handle = self.sdl.SDL_JoystickOpen(i)
                if handle:
                    self.joysticks.append(handle)
        if profile.get("controller_device") and (self.controllers or self.joysticks):
            self.controller_grab_fd = grab_sdl_controller(profile["controller_device"])
        self.flush_input()

    def close(self):
        self.release_input()
        if self.view:
            self.view.close()
        if self.renderer:
            self.sdl.SDL_DestroyRenderer(self.renderer)
        if self.window:
            self.sdl.SDL_DestroyWindow(self.window)
        self.ttf.TTF_Quit()
        self.sdl.SDL_Quit()

    def draw(self, profile: dict, base: Path, items: list[tuple[str, str]], selected: int, message: str,
             footer="A：启动   B：退出   X：按键说明   Y：刷新"):
        title, detail = items[selected]
        if self.progress_scene != title:
            self.progress_scene, self.progress_started = title, time.monotonic()
        self.view.progress(title, detail, time.monotonic() - self.progress_started, footer=message + ' · ' + footer)

    def loading(self, game, message, elapsed, presented=False, capture=False, can_cancel=False):
        event = c.create_string_buffer(56)
        closing = False
        while self.sdl.SDL_PollEvent(event):
            kind = c.c_uint32.from_buffer(event).value
            closing |= kind == 0x100 or (kind == 0x200 and event.raw[12] == 14)
            if can_cancel:
                closing |= kind == 0x300 and c.c_int32.from_buffer(event, 20).value == 27
                closing |= (kind == 0x651 or (kind == 0x603 and not self.controllers)) and event.raw[12] == 1
        if not presented:
            footer = "B：取消启动，等待当前准备步骤完成" if can_cancel else "Select＋Start：请求正常退出；退出时请稍候"
            pixels = self.view.progress(game.title, message, elapsed, footer, game, capture)
            if pixels is not None:
                self.loading_pixels = pixels
        return closing

    def confirm_released(self):
        count = c.c_int()
        keys = self.sdl.SDL_GetKeyboardState(c.byref(count))
        if any(keys[i] for i in [40, 44, 88] if i < count.value):
            return False
        return not (any(self.sdl.SDL_GameControllerGetButton(h, 0) for h in self.controllers)
                    or any(self.sdl.SDL_JoystickGetButton(h, 0) for h in self.joysticks))

    def flush_input(self):
        self.sdl.SDL_PumpEvents()
        self.sdl.SDL_FlushEvents(0x300, 0x304)
        self.sdl.SDL_FlushEvents(0x600, 0x609)
        self.sdl.SDL_FlushEvents(0x650, 0x65F)

    def choose(self, profile, base, games, message, smoke_seconds=0):
        items = [(game.title, "键鼠 · " + game.status) for game in games]
        items.append(("安装 / 补齐运行环境", "公共组件由所有游戏共享；支持离线环境包"))
        items.append(("重新扫描游戏目录", "每个游戏放入一个独立文件夹"))
        selected, axis_active = min(getattr(self, 'selected', 0), len(items) - 1), set()
        event = c.create_string_buffer(56)
        started = time.monotonic()
        dirty, armed = True, False
        pending_game = None
        overlay = None
        self.flush_input()
        while True:
            if dirty:
                self.view.library(profile, base, games, selected, message, overlay)
                dirty = False
            if smoke_seconds and time.monotonic() - started >= smoke_seconds:
                return "exit", None
            received = self.sdl.SDL_WaitEventTimeout(event, 100)
            if pending_game is not None and self.confirm_released():
                self.flush_input()
                return "game", pending_game
            if not armed and time.monotonic() - started >= 0.25 and self.confirm_released():
                armed = True
                # Events queued during launch or while holding confirm are not new choices.
                self.flush_input()
                continue
            if not received:
                continue
            kind = c.c_uint32.from_buffer(event).value
            action = None
            if kind == 0x100:
                return "exit", None
            if kind == 0x200:
                if event.raw[12] == 14:
                    return "exit", None
                dirty = True
            if not armed:
                continue
            if kind == 0x300:
                key = c.c_int32.from_buffer(event, 20).value
                action = {1073741906: "up", 1073741905: "down", 119: "up", 115: "down",
                          1073741904: "up", 1073741903: "down", 97: "up", 100: "down",
                          13: "select", 32: "select", 27: "exit", 8: "exit", 114: "refresh", 109: "input_help"}.get(key)
                if event.raw[13] and action in ("select", "input_help"):
                    action = None
            if kind == 0x651 or (kind == 0x603 and not self.controllers):
                action = {0: "select", 1: "exit", 2: "input_help", 3: "refresh", 11: "up", 12: "down", 13: "up", 14: "down"}.get(event.raw[12])
            if kind == 0x602 and not self.controllers:
                action = {1: "up", 4: "down", 8: "up", 2: "down"}.get(event.raw[13])
            if kind == 0x650 or (kind == 0x600 and not self.controllers):
                axis = event.raw[12]
                if axis in (0, 1):
                    value = c.c_int16.from_buffer(event, 16).value
                    if abs(value) < 8000:
                        axis_active.discard(axis)
                    elif abs(value) > 18000 and axis not in axis_active:
                        action = "down" if value > 0 else "up"
                        axis_active.add(axis)
            if action:
                print(json.dumps({"event": "menu_action", "page": "games",
                                  "action": action, "input_type": hex(kind), "selected": items[selected][0]},
                                 ensure_ascii=False), flush=True)
            if action in ["up", "down"]:
                if not overlay:
                    selected = (selected + (1 if action == "down" else -1)) % len(items)
                    self.selected = selected
                    dirty = True
            elif action == "exit" and overlay:
                overlay, dirty = None, True
            elif action in ["exit", "refresh"]:
                return action, None
            elif action == "input_help":
                overlay, dirty = None if overlay == 'input' else 'input', True
            elif action == "select":
                if overlay:
                    overlay, dirty = None, True
                elif selected < len(games):
                    if games[selected].error:
                        overlay, dirty = 'resources', True
                    else:
                        pending_game = games[selected]
                        message, dirty = "松开确定键后启动游戏", True
                elif selected == len(games):
                    return "install", None
                else:
                    return "refresh", None


def install_from_menu(menu, base, profile, games):
    messages = queue.Queue()
    result = []
    environment = load_environment(profile)
    graphics = sorted({game.graphics_api for game in games if game.graphics_api in environment.get("graphics", {})})

    def worker():
        try:
            offline = offline_directory(resolve_library(profile))
            install(base, profile, graphics, offline=offline, progress=messages.put)
            result.append("运行环境安装完成")
        except Exception as exc:
            result.append(str(exc))

    thread = threading.Thread(target=worker)
    thread.start()
    message = "正在准备安装环境，请稍候"
    event = c.create_string_buffer(56)
    while thread.is_alive():
        try:
            while True:
                message = messages.get_nowait()
        except queue.Empty:
            pass
        menu.draw(profile, base, [("正在安装运行环境", message)], 0, "玩家游戏与存档独立保存", footer="安装中，请稍候")
        menu.sdl.SDL_WaitEventTimeout(event, 100)
    thread.join()
    menu.flush_input()
    return result[0]


def lifecycle(opening: bool, profile: dict) -> bool:
    definition = profile.get("lifecycle")
    if not definition:
        return False
    library = Path(definition["library"])
    if not library.exists():
        return False
    sdk = c.CDLL(str(library))
    if opening:
        method = getattr(sdk, definition["open"])
        method.argtypes, method.restype = [c.c_char_p], c.c_int
        return method(definition["category"].encode()) == 0
    method = getattr(sdk, definition["close"])
    method.argtypes, method.restype = [c.c_char_p, c.c_char_p], c.c_int
    method(definition["category"].encode(), b"")
    return True


def presentation_ready(state: Path, token: str) -> bool:
    try:
        fd = os.open(state / "work/presentation-ready", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        return stat.S_ISREG(os.fstat(fd).st_mode) and os.read(fd, 80) == ("frame " + token + "\n").encode()
    except OSError:
        return False
    finally:
        os.close(fd)


def run_selection(base: Path, profile: dict, game: Game, app_root: Path, progress=lambda _: None, cancel=None, startup_card=None, before_input=lambda: None) -> int:
    if game is None or game.executable is None or game.error:
        raise RuntimeError("请选择有效的游戏入口；不会自动打开 Wine 设置")
    env = dict(os.environ, WINE_RUNNER_HOME=str(base), WINE_RUNNER_MOUNT=profile["runtime_mount"])
    env.update(XDG_RUNTIME_DIR=profile["xdg_runtime_dir"], WAYLAND_DISPLAY=profile["wayland_display"])
    machine_environment = load_environment(profile, app_root)
    components, _ = resolve_components(machine_environment, game.graphics_api, app_root)
    progress("正在检查共享运行环境")
    result = subprocess.run(["sh", str(app_root / "run.sh"), "--prepare"], env=env, capture_output=True, text=True)
    if result.returncode or not installed(Path(profile["runtime_mount"]), components):
        progress("首次启动，正在安装所需公共运行环境")
        offline = offline_directory(resolve_library(profile))
        install(base, profile, [game.graphics_api] if game.graphics_api else [], root=app_root, offline=offline, progress=progress)
        result = subprocess.run(["sh", str(app_root / "run.sh"), "--prepare"], env=env, capture_output=True, text=True)
        if result.returncode or not installed(Path(profile["runtime_mount"]), components):
            raise RuntimeError(result.stderr.strip() or "公共运行环境安装不完整")
    if cancel is not None and cancel.is_set():
        return 0
    token = uuid.uuid4().hex
    command = [os.environ.get("WINE_RUNNER_PYTHON", sys.executable), str(app_root / "wine_session.py"),
               "--runtime", profile["runtime_mount"], "--game", str(game.directory),
               "--executable", game.executable.name, "--environment", json.dumps(game.environment),
               "--machine-environment", str(app_root / "environments" / (profile["environment"] + ".json")),
               "--graphics-api", game.graphics_api, "--presentation-token", token]
    if game.executable_override:
        command += ["--override", str(game.executable_override)]
    if startup_card is not None and game.borderless_fullscreen:
        command += ["--startup-card", str(startup_card)]
    if game.resource_overrides:
        command += ["--resource-overrides", json.dumps(game.resource_overrides)]
    if game.borderless_fullscreen:
        if "display_size" not in profile:
            raise RuntimeError("当前机型未设置全屏宽高")
        command += ["--borderless-size", *map(str, profile["display_size"])]
    arguments = list(game.arguments)
    if game.screen_arguments:
        width, height = profile["display_size"]
        arguments += [game.screen_arguments["width"], str(width), game.screen_arguments["height"], str(height)]
    command += ["--", *arguments]
    logs = Path(profile["runtime_mount"]) / "logs"
    env["SDL_GAMECONTROLLERCONFIG_FILE"] = str(launcher_asset(profile["controller_database"], app_root))
    progress("正在连接游戏按键")
    before_input()
    if cancel is not None and cancel.is_set():
        return 0
    with InputSession(profile, app_root, game) as inputs, (logs / "launcher-last-game.log").open("w", encoding="utf-8") as log:
        if cancel is not None and cancel.is_set():
            return 0
        print(json.dumps({"command": command, "title": game.title, "configdir": game.config_directories}, ensure_ascii=False), file=log, flush=True)
        child = subprocess.Popen(command, cwd=game.directory, env=env, stdout=log,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        state = session_directory(Path(profile["runtime_mount"]), game.directory)
        requested, presented = False, False
        progress("正在启动游戏，等待画面")
        try:
            while child.poll() is None:
                if not presented and presentation_ready(state, token):
                    presented = True
                    progress("presented")
                if not requested and (inputs.force_exit_requested() or (cancel is not None and cancel.is_set())):
                    try:
                        request_close(state, token)
                    except FileNotFoundError:
                        # The namespace may still be creating its private work directory.
                        time.sleep(.05)
                        continue
                    requested = True
                    progress("正在正常关闭游戏，请稍候")
                time.sleep(.05)
            return child.wait()
        except BaseException:
            try:
                request_close(state, token)
            except OSError as exc:
                print("NORMAL_CLOSE_REQUEST_FAILED", str(exc), file=log, flush=True)
            child.wait()
            raise


def play_from_menu(menu, base, profile, game, app_root):
    """Keep SDL on its owning thread through preparation, play and cleanup."""
    messages, result, errors = queue.Queue(), [], []
    cancel = threading.Event()
    with tempfile.TemporaryDirectory(prefix=".wine-loading-", dir=base) as temporary:
        return _play_from_menu(menu, base, profile, game, app_root, messages, result, errors, cancel, Path(temporary))


def _play_from_menu(menu, base, profile, game, app_root, messages, result, errors, cancel, temporary):
    menu.loading(game, "正在准备启动", 0, capture=True)
    startup_card = temporary / "loading.bgra"
    startup_card.write_bytes(menu.loading_pixels)
    input_acknowledged = threading.Event()

    def handoff_input():
        messages.put("handoff-input")
        input_acknowledged.wait()

    def worker():
        try:
            result.append(run_selection(base, profile, game, app_root, messages.put, cancel, startup_card, handoff_input))
        except BaseException as exc:
            errors.append(exc)

    thread = threading.Thread(target=worker)
    thread.start()
    started, message, presented = time.monotonic(), "正在准备启动", False
    released = False
    try:
        while thread.is_alive():
            try:
                while True:
                    update = messages.get_nowait()
                    if update == "presented":
                        presented = True
                    elif update == "handoff-input":
                        released = True
                        menu.release_input()
                        input_acknowledged.set()
                    else:
                        message = update
            except queue.Empty:
                pass
            if menu.loading(game, message, time.monotonic() - started, presented, can_cancel=not released):
                cancel.set()
            time.sleep(.05)
    finally:
        cancel.set()
        input_acknowledged.set()
        thread.join()
        if released:
            menu.resume_input(profile)
    if errors:
        raise errors[0]
    return result[0]


def main(argv=None):
    args, profile, base = _startup_configuration(argv)
    if args.print_base:
        print(base)
        return 0
    os.environ.update(XDG_RUNTIME_DIR=profile["xdg_runtime_dir"], WAYLAND_DISPLAY=profile["wayland_display"], SDL_VIDEODRIVER="wayland")
    if args.list:
        print(json.dumps([{"title": g.title, "executable": str(g.executable) if g.executable else None,
                           "status": g.status, "error": g.error} for g in discover_games(base, profile)], ensure_ascii=False, indent=2))
        return 0
    profile = resolve_input(profile, ROOT, base)
    print(json.dumps({"input_source": profile["input_source"], "input_helper": profile["input_helper"],
                      "controller_database_sources": profile["controller_database_sources"]}, ensure_ascii=False), flush=True)
    opened = lifecycle(True, profile) if not args.no_lifecycle else False
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    message = "X 查看按键；Select+Start 退出，退出时请稍候"
    menu = None
    try:
        menu = Menu(profile)
        menu.draw(profile, base, [("Je-Wine", "正在读取本地游戏库并检查资源")], 0,
                  "首次启动可能需要一点时间", footer="正在打开游戏库")
        while True:
            games = discover_games(base, profile)
            for item in games:
                if item.adapter_id:
                    item.directory.mkdir(parents=True, exist_ok=True)
            if args.game:
                game = next((item for item in games if item.adapter_id == args.game), None)
                args.game = None
                if game is None:
                    message = "游戏适配包未安装"
                    continue
                if game.error:
                    message = game.error + "；目录：" + str(game.directory)
                    game.directory.mkdir(parents=True, exist_ok=True)
                    continue
                menu.draw(profile, base, [(game.title, game.status)], 0, "松开确定键后启动游戏")
                while True:
                    menu.sdl.SDL_PumpEvents()
                    if menu.confirm_released():
                        break
                    time.sleep(.05)
                menu.flush_input()
                action = "game"
            else:
                action, game = menu.choose(profile, base, games, message, args.smoke_seconds)
            if action == "exit":
                return 0
            if action == "install":
                message = install_from_menu(menu, base, profile, games)
                continue
            if action == "refresh":
                message = f"发现 {len(discover_games(base, profile))} 个游戏目录"
                continue
            if action != "game":
                message = "请选择游戏或重新扫描目录"
                continue
            try:
                code = play_from_menu(menu, base, profile, game, Path(__file__).resolve().parent)
                message = f"上次程序退出码：{code}；详细日志在运行包 logs 中"
                if code == 53 and "Steam" in game.status:
                    message = "启动失败：原版游戏需要 Steam 客户端，尚未进入游戏画面"
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
                message = str(exc)
    finally:
        if menu is not None:
            menu.close()
        if opened:
            lifecycle(False, profile)


if __name__ == "__main__":
    raise SystemExit(main())
