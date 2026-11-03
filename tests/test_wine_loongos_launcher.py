#!/usr/bin/env python3
# INPUT:  unittest、临时游戏目录、运行器接口与发行组装脚本
# OUTPUT: 游戏发现、PortMaster 输入复用/回退、按键门禁和发行包边界的回归结果
# POS:    验证 Wine 运行器的启动选择、输入复用交接与代码数据边界
import json
import os
from pathlib import Path
import subprocess
import tempfile
import shutil
import unittest
from unittest import mock
import zipfile
import ctypes
import io
import struct
import zlib

import importlib.util
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ports/wine-loongos/src"
sys.path.insert(0, str(SOURCE))
from wine_input import ExitChord, InputSession, EVIOCGRAB, grab_sdl_controller, resolve_input
from wine_ui import read_png
import wine_session
spec = importlib.util.spec_from_file_location("wine_loongos_launcher", SOURCE / "launcher.py")
launcher = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = launcher
spec.loader.exec_module(launcher)
mount_spec = importlib.util.spec_from_file_location("wine_loongos_runtime_mount", SOURCE / "runtime_mount.py")
runtime_mount = importlib.util.module_from_spec(mount_spec)
mount_spec.loader.exec_module(runtime_mount)
discover_games, read_game, read_profile, run_selection = (
    launcher.discover_games, launcher.read_game, launcher.read_profile, launcher.run_selection
)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.app = self.base / "code dir"
        self.app.mkdir()
        for category in ["environments", "components"]:
            shutil.copytree(SOURCE / category, self.app / category)
        patcher = mock.patch.object(launcher, "installed", return_value=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.folder = self.base / "games" / "My Game"
        self.folder.mkdir(parents=True)
        (self.folder / "data").mkdir()
        (self.folder / "bottle.json").write_text(json.dumps({"attr": {"title": "My Game"}}))

    def manifest(self, data):
        (self.folder / "wine-game.json").write_text(json.dumps(data), encoding="utf-8")

    def test_single_game_ignores_crash_handler(self):
        for name in ["Game.EXE", "UnityCrashHandler64.exe", "unins000.exe"]:
            (self.folder / name).touch()
        game = read_game(self.folder)
        self.assertEqual(game.executable, self.folder / "Game.EXE")
        self.assertEqual(game.status, "尚未验证兼容性")

    def test_ambiguous_executables_require_a_manifest(self):
        for name in ["game.exe", "editor.exe"]:
            (self.folder / name).touch()
        self.assertIsNone(read_game(self.folder).executable)

    def test_manifest_preserves_arguments_without_shell_parsing(self):
        (self.folder / "game.exe").touch()
        self.manifest({"title": "中文游戏", "executable": "game.exe", "arguments": ["a b", "$(literal)"],
                       "environment": {"DXVK_HUD": "fps"}, "status": "需要 Steam"})
        game = read_game(self.folder)
        self.assertEqual(game.title, "中文游戏")
        self.assertEqual(game.arguments, ["a b", "$(literal)"])
        self.assertEqual(game.status, "需要 Steam")

    def test_manifest_cannot_escape_game_directory(self):
        (self.folder.parent / "outside.exe").touch()
        self.manifest({"executable": "../outside.exe"})
        self.assertIsNone(read_game(self.folder).executable)
        (self.folder / "linked.exe").symlink_to(self.folder.parent / "outside.exe")
        self.manifest({"executable": "linked.exe"})
        self.assertIsNone(read_game(self.folder).executable)

    def test_game_cannot_redirect_the_shared_runtime_or_prefix(self):
        (self.folder / "game.exe").touch()
        self.manifest({"executable": "game.exe", "environment": {"WINE_RUNNER_HOME": "/tmp/other"}})
        self.assertIsNone(read_game(self.folder).executable)

    def test_launch_handoff_preserves_working_directory_environment_and_literal_arguments(self):
        (self.folder / "game.exe").touch()
        self.manifest({"executable": "game.exe", "arguments": ["a b", "$(literal)"],
                       "environment": {"DXVK_HUD": "fps"}})
        (self.app / "run.sh").write_text('#!/bin/sh\nmkdir -p "$WINE_RUNNER_MOUNT/logs"\nexit 0\n')
        (self.app / "wine_session.py").write_text("import json, os, sys\nargs=sys.argv[1:]\nfor item in args[args.index('--')+1:]: print('<'+item+'>')\nprint('cwd='+os.getcwd())\nprint('hud='+json.loads(args[args.index('--environment')+1])['DXVK_HUD'])\nprint('controller_db='+os.environ['SDL_GAMECONTROLLERCONFIG_FILE'])\nraise SystemExit(7)\n")
        runtime = self.base / "runtime"
        profile = {"runtime_mount": str(runtime), "xdg_runtime_dir": "/run", "wayland_display": "wayland-0",
                   "controller_database": "/fixture/gamecontrollerdb.txt", "environment": "loongos-rk3566", "machine": "aarch64"}
        with mock.patch.object(launcher, "InputSession") as inputs:
            inputs.return_value.__enter__.return_value.force_exit_requested.return_value = False
            self.assertEqual(run_selection(self.base, profile, read_game(self.folder), self.app), 7)
        log = (runtime / "logs/launcher-last-game.log").read_text()
        self.assertIn('<a b>\n<$(literal)>', log)
        self.assertIn('cwd=' + str(self.folder.resolve()), log)
        self.assertIn('hud=fps', log)
        self.assertIn('controller_db=/fixture/gamecontrollerdb.txt', log)

    def test_game_can_select_a_custom_keyboard_mapping_within_its_directory(self):
        (self.folder / "game.exe").touch()
        (self.folder / "custom.gptk").write_text("[controls]\na=space\n")
        self.manifest({"executable": "game.exe", "arguments": ["a b"], "input_mode": "desktop",
                       "input_mapping": "custom.gptk", "input_help": "A 确认，B 返回", "custom_note": "keep"})
        game = read_game(self.folder)
        self.assertEqual(game.input_mapping, self.folder / "custom.gptk")
        self.assertFalse(game.error)
        self.assertEqual(game.arguments, ["a b"])
        self.assertEqual(game.input_help, "A 确认，B 返回")

    def test_invalid_mode_or_external_mapping_cannot_start_a_game(self):
        (self.folder / "game.exe").touch()
        for extra in [{"input_mode": "native"}, {"input_mode": "unknown"}, {"input_mapping": "../outside.gptk"},
                      {"input_mapping": "/tmp/external.gptk"}]:
            with self.subTest(extra=extra):
                self.manifest(dict(executable="game.exe", **extra))
                self.assertTrue(read_game(self.folder).error)

    def test_graphics_profile_accepts_a_private_exe_copy_and_rejects_escaping_paths(self):
        (self.folder / "game.exe").write_bytes(b"original")
        (self.folder / ".wine").mkdir()
        (self.folder / ".wine/game.exe").write_bytes(b"copy")
        self.manifest({"executable": "game.exe", "graphics_api": "d3d11",
                       "executable_override": ".wine/game.exe", "environment": {"SteamAppId": "1"}})
        game = read_game(self.folder)
        self.assertFalse(game.error)
        self.assertEqual(game.executable_override, self.folder / ".wine/game.exe")
        for extra in [{"graphics_api": "unknown"},
                      {"graphics_api": "d3d11", "executable_override": "../outside.exe"},
                      {"graphics_api": "d3d11", "environment": {"LD_PRELOAD": "/outside.so"}}]:
            with self.subTest(extra=extra):
                self.manifest(dict(executable="game.exe", **extra))
                self.assertTrue(read_game(self.folder).error)

    def test_malformed_configuration_remains_visible_as_needing_setup(self):
        (self.folder / "data/wine-game.json").write_text("{broken", encoding="utf-8")
        games = discover_games(self.base, {"library_directory": str(self.folder.parent)}, self.app)
        self.assertEqual(len(games), 1)
        self.assertEqual(games[0].status, "需要配置")
        self.assertTrue(games[0].error)

    def test_borderless_fullscreen_is_opt_in_and_requires_a_boolean(self):
        (self.folder / "game.exe").touch()
        self.manifest({"executable": "game.exe"})
        self.assertFalse(read_game(self.folder).borderless_fullscreen)
        self.manifest({"executable": "game.exe", "graphics_api": "d3d11", "borderless_fullscreen": True})
        game = read_game(self.folder)
        self.assertFalse(game.error)
        self.assertTrue(game.borderless_fullscreen)
        for extra in [{"borderless_fullscreen": "true"},
                      {"graphics_api": "d3d11", "borderless_fullscreen": "true"}]:
            with self.subTest(extra=extra):
                self.manifest(dict(executable="game.exe", **extra))
                self.assertTrue(read_game(self.folder).error)

    def test_profile_validates_actual_landscape_dimensions(self):
        path = self.base / "profile.json"
        path.write_text(json.dumps({"library_directory": str(self.base / "windows"), "display_size": [960, 720]}))
        self.assertEqual(read_profile(path)["display_size"], [960, 720])
        for size in [[True, 720], [960, 0], [960], "960x720", [960, 4097]]:
            with self.subTest(size=size):
                path.write_text(json.dumps({"library_directory": str(self.base / "windows"), "display_size": size}))
                with self.assertRaises(ValueError):
                    read_profile(path)

    def test_scan_hides_internal_tests_and_external_directory_symlinks(self):
        (self.folder / "data/game.exe").touch()
        (self.folder.parent / "_runtime-smoke").mkdir()
        with tempfile.TemporaryDirectory() as outside:
            (self.folder.parent / "linked").symlink_to(outside)
            games = discover_games(self.base, {"library_directory": str(self.folder.parent)}, self.app)
        self.assertEqual([g.title for g in games], ["My Game"])

    def test_profile_requires_an_explicit_absolute_windows_library(self):
        for entry in ["games", "../games", "", "/"]:
            (self.base / "profile.json").write_text(json.dumps({"library_directory": entry}))
            with self.assertRaises(ValueError):
                read_profile(self.base / "profile.json")


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["bash", str(ROOT / "_kit/dist_port.sh"), "wine-loongos"],
                       cwd=ROOT, check=True, capture_output=True, text=True)
        cls.port = ROOT / "ports/wine-loongos"
        cls.dist = cls.port / "dist"
        cls.entry = cls.dist / "Je-Wine.sh"

    def test_sdcard_zip_contains_private_launcher_and_no_game_or_wine_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([sys.executable, str(SOURCE / "scripts/dist-zip.py"),
                            "--dist", str(self.dist), "--output", str(Path(directory) / "wine-loongos.zip")],
                           check=True, capture_output=True, text=True)
            with zipfile.ZipFile(Path(directory) / "wine-loongos.zip") as archive:
                self.assertIsNone(archive.testzip())
                names = archive.namelist()
                prefix = "roms/windows/.winecellar/wine-loongos/"
                for name in ["launcher.py", "run.sh", "bootstrap.sh", "bootstrap-aarch64.squashfs", "bootstrap.sha256",
                             "runtime_mount.py", "devices/miniloong-pocket-one.json", "wine_input.py", "desktop.gptk",
                             "wine_session.py", "runtime_install.py", "components/catalog.json", "games-README.txt",
                             "wine_layout.py", "wine_bottle.py", "wine_package.py", "bottle.example.json"]:
                    self.assertIn(prefix + name, names)
                self.assertIn("roms/windows/Je-Wine.sh", names)
                self.assertIn("roms/ports/Je-Wine.sh", names)
                self.assertNotIn("port.json", names)
                for name in names:
                    self.assertNotIn("__pycache__", name)
                    self.assertFalse(name.endswith((".pyc", ".ext4", ".exe", ".dll", ".log", "AGENTS.md")), name)
                info = json.loads(archive.read(prefix + "build-info.json"))
                self.assertEqual(info["packaging"], "rocknix-sdcard")

    def test_packaged_entry_uses_new_code_with_separate_existing_game_data(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            library = data / "windows"
            game = library / "my-game/data"
            game.mkdir(parents=True)
            (game / "Game.exe").touch()
            (game.parent / "bottle.json").write_text(json.dumps({"attr": {"title": "中文 Game"}}))
            image = data / "runtime.ext4"
            image.write_bytes(b"existing private runtime image")
            env = dict(os.environ, WINE_RUNNER_HOME=str(data), WINE_RUNNER_PYTHON=sys.executable,
                       WINE_RUNNER_APP_DIR=str(self.dist / "wine-loongos"), WINE_RUNNER_LIBRARY=str(library))
            subprocess.run(["sh", str(self.entry), "--list", "--profile", str(self.dist / "wine-loongos/devices/miniloong-pocket-one.json")], env=env, check=True, capture_output=True)
            output = (data / "launcher.log").read_text()
            self.assertIn("[BUILD] package=wine-loongos", output)
            games = json.loads(output.split("\n", 1)[1])
            self.assertEqual(games[0]["title"], "中文 Game")
            self.assertEqual(games[0]["executable"], str((game / "Game.exe").resolve()))
            self.assertEqual(image.read_bytes(), b"existing private runtime image")

    def test_missing_application_payload_fails_before_game_start(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, WINE_RUNNER_APP_DIR=str(Path(directory) / "missing"))
            result = subprocess.run(["sh", str(self.entry)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 78)
            self.assertIn("payload is missing", result.stderr)


class LaunchFlowTests(unittest.TestCase):
    def device_profile(self, root):
        database = root / "gamecontrollerdb.txt"
        database.write_text("# fixture controller database\n")
        profile = root / "device.json"
        profile.write_text(json.dumps({"library_directory": str(root / "windows"), "xdg_runtime_dir": "/run",
                                       "wayland_display": "wayland-0", "controller_database": str(database)}))
        return profile

    def test_print_base_does_not_load_ui_installer_or_game_modules(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["launcher.py", "wine_catalog.py", "wine_layout.py"]:
                shutil.copyfile(SOURCE / name, root / name)
            for name in ["wine_input", "wine_session", "wine_game", "wine_bottle", "wine_ui", "runtime_install"]:
                (root / (name + ".py")).write_text("raise RuntimeError('unneeded startup import')\n")
            profile = self.device_profile(root)
            env = dict(os.environ)
            for name in ["WINE_RUNNER_HOME", "WINE_RUNNER_LIBRARY"]:
                env.pop(name, None)
            for arguments, expected in [
                ([], root / "windows/.winecellar/state"),
                (["--library", str(root / "other")], root / "other/.winecellar/state"),
                (["--base", str(root / "explicit")], root / "explicit"),
            ]:
                with self.subTest(arguments=arguments):
                    result = subprocess.run([sys.executable, str(root / "launcher.py"), "--print-base",
                                             "--profile", str(profile), *arguments],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), str(expected.resolve()))
                    self.assertFalse(expected.exists())

    def test_startup_shows_loading_before_game_resource_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            profile = self.device_profile(base)
            menu = mock.Mock()
            stages = []
            menu.draw.side_effect = lambda *args, **kwargs: stages.append("loading")
            menu.choose.side_effect = lambda *args: (stages.append("library") or ("exit", None))

            def inspect(*args):
                stages.append("verify_resources")
                return []

            with mock.patch.object(launcher, "Menu", return_value=menu), \
                 mock.patch.object(launcher, "discover_games", side_effect=inspect), \
                 mock.patch.object(launcher.signal, "signal"):
                self.assertEqual(launcher.main(["--base", str(base), "--profile", str(profile), "--no-lifecycle"]), 0)
            self.assertEqual(stages, ["loading", "verify_resources", "library"])
            menu.close.assert_called_once()

    def test_failed_resource_scan_closes_the_startup_window(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            profile = self.device_profile(base)
            menu = mock.Mock()
            with mock.patch.object(launcher, "Menu", return_value=menu), \
                 mock.patch.object(launcher, "discover_games", side_effect=OSError("scan failed")), \
                 mock.patch.object(launcher, "lifecycle", return_value=True) as lifecycle, \
                 mock.patch.object(launcher.signal, "signal"):
                with self.assertRaisesRegex(OSError, "scan failed"):
                    launcher.main(["--base", str(base), "--profile", str(profile)])
            menu.close.assert_called_once()
            self.assertEqual([call.args[0] for call in lifecycle.call_args_list], [True, False])

    def test_missing_or_empty_program_is_rejected_before_runtime_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            env = dict(os.environ, WINE_RUNNER_HOME=str(base / "missing data"),
                       WINE_RUNNER_MOUNT=str(base / "missing mount"))
            for arguments in [[], [""]]:
                with self.subTest(arguments=arguments):
                    result = subprocess.run(["sh", str(SOURCE / "run.sh"), *arguments],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 64)
                    self.assertIn("No Windows program selected", result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(list(base.iterdir()), [])

    def test_standalone_game_entry_waits_for_confirm_release_before_handoff(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = self.device_profile(root)
            game = launcher.Game("fixture", root / "games/fixture", root / "games/fixture/game.exe", adapter_id="fixture")
            menu = mock.Mock()
            menu.loading_pixels = b"fixture startup card"
            menu.confirm_released.side_effect = [False, True]
            menu.choose.return_value = ("exit", None)
            with mock.patch.object(launcher, "Menu", return_value=menu), \
                 mock.patch.object(launcher, "discover_games", return_value=[game]), \
                 mock.patch.object(launcher, "run_selection", return_value=0) as run, \
                 mock.patch.object(launcher.time, "sleep") as wait, \
                 mock.patch.object(launcher.signal, "signal"), mock.patch.dict(os.environ):
                self.assertEqual(launcher.main(["--base", str(root), "--profile", str(profile), "--no-lifecycle", "--game", "fixture"]), 0)
            self.assertEqual(menu.confirm_released.call_count, 2)
            wait.assert_called_once_with(.05)
            run.assert_called_once()

    def test_missing_game_never_prepares_runtime_or_opens_settings(self):
        with mock.patch.object(launcher.subprocess, "run") as prepare, \
             mock.patch.object(launcher.subprocess, "Popen") as spawn:
            for game in [None, launcher.Game("未配置游戏", Path("/fixture"))]:
                with self.subTest(game=game):
                    with self.assertRaisesRegex(RuntimeError, "请选择有效的游戏入口"):
                        run_selection(Path("/fixture"), {}, game, SOURCE)
            prepare.assert_not_called()
            spawn.assert_not_called()

    def test_refresh_and_unknown_actions_never_start_windows_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            profile = self.device_profile(base)
            menu = mock.Mock()
            menu.choose.side_effect = [("refresh", None), ("settings", None), ("exit", None)]
            with mock.patch.object(launcher, "Menu", return_value=menu) as factory, \
                 mock.patch.object(launcher, "run_selection") as run, \
                 mock.patch.object(launcher.signal, "signal"):
                self.assertEqual(launcher.main(["--base", str(base), "--profile", str(profile), "--no-lifecycle"]), 0)
            run.assert_not_called()
            factory.assert_called_once()
            menu.close.assert_called_once()

    def test_game_handoff_retains_fullscreen_menu_and_releases_only_input(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            profile = self.device_profile(base)
            game = launcher.Game("游戏", base, base / "game.exe")
            menu = mock.Mock()
            menu.loading_pixels = b"fixture startup card"
            menu.choose.side_effect = [("game", game), ("exit", None)]

            def run_game(_base, _profile, selected, _app, progress, cancel, startup_card, before_input):
                self.assertIs(_profile, factory.call_args.args[0])
                self.assertTrue(Path(_profile["controller_database"]).is_file())
                menu.release_input.assert_not_called()
                before_input()
                menu.close.assert_not_called()
                menu.release_input.assert_called_once()
                menu.resume_input.assert_not_called()
                self.assertEqual(startup_card.read_bytes(), b"fixture startup card")
                self.assertIs(selected, game)
                progress("presented")
                return 7

            with mock.patch.object(launcher, "Menu", return_value=menu) as factory, \
                 mock.patch.object(launcher, "resolve_input", wraps=resolve_input) as resolve, \
                 mock.patch.object(launcher, "run_selection", side_effect=run_game) as run, \
                 mock.patch.object(launcher.signal, "signal"):
                self.assertEqual(launcher.main(["--base", str(base), "--profile", str(profile), "--no-lifecycle"]), 0)
            run.assert_called_once()
            resolve.assert_called_once()
            factory.assert_called_once()
            menu.resume_input.assert_called_once()
            menu.close.assert_called_once()
            self.assertIn("上次程序退出码：7", menu.choose.call_args.args[3])
            self.assertFalse(list(base.glob(".wine-loading-*")))

    def test_failed_preparation_keeps_input_and_loading_window(self):
        with tempfile.TemporaryDirectory() as temporary:
            menu = mock.Mock(loading_pixels=b"card")
            with mock.patch.object(launcher, "run_selection", side_effect=RuntimeError("fixture missing runtime")):
                with self.assertRaisesRegex(RuntimeError, "fixture missing runtime"):
                    launcher.play_from_menu(menu, Path(temporary), {}, launcher.Game("game", Path(temporary)), SOURCE)
            menu.release_input.assert_not_called()
            menu.resume_input.assert_not_called()
            menu.close.assert_not_called()
            self.assertFalse(list(Path(temporary).iterdir()))

    def test_failed_input_handoff_restores_menu_controller(self):
        with tempfile.TemporaryDirectory() as temporary:
            menu = mock.Mock(loading_pixels=b"card")
            def fail(_base, _profile, _game, _root, _progress, _cancel, _card, before_input):
                before_input()
                raise RuntimeError("fixture input failure")
            with mock.patch.object(launcher, "run_selection", side_effect=fail):
                with self.assertRaisesRegex(RuntimeError, "fixture input failure"):
                    launcher.play_from_menu(menu, Path(temporary), {}, launcher.Game("game", Path(temporary)), SOURCE)
            menu.release_input.assert_called_once()
            menu.resume_input.assert_called_once()
            menu.close.assert_not_called()

    def test_frame_readiness_requires_this_launch_token_and_a_regular_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            (state / "work").mkdir()
            marker = state / "work/presentation-ready"
            token = "a" * 32
            self.assertFalse(launcher.presentation_ready(state, token))
            marker.write_text("frame " + "b" * 32 + "\n")
            self.assertFalse(launcher.presentation_ready(state, token))
            marker.write_text("frame " + token + "\n")
            self.assertTrue(launcher.presentation_ready(state, token))
            marker.unlink()
            marker.symlink_to(state / "outside")
            (state / "outside").write_text("frame " + token + "\n")
            self.assertFalse(launcher.presentation_ready(state, token))

    def test_held_confirm_and_key_repeat_are_ignored_until_release_and_new_press(self):
        class FakeSDL:
            now = 0.0
            pressed = False
            index = 0
            # Held return, repeated return, release, stale repeat, fresh press.
            events = [(0x300, 13, 0, True), (0x300, 13, 1, True), (0x301, 13, 0, False),
                      (0x300, 13, 1, True), (0x300, 13, 0, True)]

            def SDL_WaitEventTimeout(self, event, _timeout):
                self.now += 0.1
                kind, key, repeat, self.pressed = self.events[self.index]
                self.index += 1
                ctypes.memset(event, 0, 56)
                ctypes.c_uint32.from_buffer(event).value = kind
                ctypes.c_int32.from_buffer(event, 20).value = key
                event[13] = bytes([repeat])
                return 1

        menu = launcher.Menu.__new__(launcher.Menu)
        menu.sdl = FakeSDL()
        menu.controllers, menu.joysticks = [], []
        menu.view, menu.flush_input = mock.Mock(), mock.Mock()
        menu.confirm_released = lambda: not menu.sdl.pressed
        with mock.patch.object(launcher.time, "monotonic", side_effect=lambda: menu.sdl.now), \
             mock.patch("builtins.print"):
            self.assertEqual(menu.choose({}, Path("/fixture"), [], ""), ("install", None))
        self.assertEqual(menu.view.library.call_args.args[2:4], ([], 0))
        self.assertEqual(menu.sdl.index, 5)
        menu.sdl = FakeSDL()
        menu.sdl.events = FakeSDL.events + [(0x301, 13, 0, False)]
        game = launcher.Game("game", Path("/fixture"), Path("/fixture/game.exe"))
        with mock.patch.object(launcher.time, "monotonic", side_effect=lambda: menu.sdl.now), \
             mock.patch("builtins.print"):
            self.assertEqual(menu.choose({}, Path("/fixture"), [game], ""), ("game", game))
        self.assertEqual(menu.sdl.index, 6, "game handoff must wait for confirm release")


class LibraryUiTests(unittest.TestCase):
    def png(self, width, height, color, raw):
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, color, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

    def test_rgb_and_rgba_covers_decode_without_extra_device_libraries(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'cover.png'
            path.write_bytes(self.png(2, 1, 2, b'\x01\xff\0\0\x01\xff\0'))
            self.assertEqual(read_png(path), (2, 1, b'\xff\0\0\xff\0\xff\0\xff'))
            path.write_bytes(self.png(1, 2, 6, b'\x00\x0a\x14\x1e\xff\x04\x01\x02\x03\x00'))
            self.assertEqual(read_png(path), (1, 2, b'\x0a\x14\x1e\xff\x0b\x16\x21\xff'))

    def test_damaged_or_oversized_covers_are_rejected_for_generated_art_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'cover.png'
            for data in [b'not png', self.png(1025, 1, 6, b''),
                         self.png(1, 1, 6, b'\0' + b'\xff' * 100),
                         self.png(1, 1, 6, b'\0\0\0\0\xff')[:-5]]:
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    read_png(path)

    def menu(self, actions):
        class FakeSDL:
            now = 0.0
            def __init__(self):
                self.events = iter([None, None, None, *actions])
            def SDL_WaitEventTimeout(self, event, _timeout):
                self.now += .1
                ctypes.memset(event, 0, 56)
                action = next(self.events)
                if action is not None:
                    ctypes.c_uint32.from_buffer(event).value = 0x300
                    ctypes.c_int32.from_buffer(event, 20).value = action
                return 1
        menu = launcher.Menu.__new__(launcher.Menu)
        menu.sdl, menu.view, menu.flush_input = FakeSDL(), mock.Mock(), mock.Mock()
        menu.controllers, menu.joysticks = [], []
        menu.confirm_released = lambda: True
        return menu

    def test_back_closes_controls_then_horizontal_navigation_selects_environment(self):
        menu = self.menu([109, 27, 1073741903, 13])
        game = launcher.Game('Game', Path('/fixture/data'))
        with mock.patch.object(launcher.time, 'monotonic', side_effect=lambda: menu.sdl.now), mock.patch('builtins.print'):
            self.assertEqual(menu.choose({}, Path('/fixture'), [game], ''), ('install', None))
        overlays = [call.args[-1] for call in menu.view.library.call_args_list]
        self.assertIn('input', overlays)
        self.assertIsNone(overlays[-1])
        self.assertEqual(menu.selected, 1)

    def test_missing_resources_open_a_dialog_and_confirm_returns_without_starting_wine(self):
        menu = self.menu([13, 13, 27])
        game = launcher.Game('Missing', Path('/fixture/data'), error='待补游戏文件：Game.exe')
        with mock.patch.object(launcher.time, 'monotonic', side_effect=lambda: menu.sdl.now), mock.patch('builtins.print'), \
             mock.patch.object(launcher, 'run_selection') as start:
            self.assertEqual(menu.choose({}, Path('/fixture'), [game], ''), ('exit', None))
        self.assertIn('resources', [call.args[-1] for call in menu.view.library.call_args_list])
        start.assert_not_called()


class InputProviderTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.bootstrap = self.root / "bootstrap"
        self.pm = self.root / "PortMaster"
        self.pm.mkdir()
        self.home = self.root / "home"
        self.profile = {"machine": "aarch64", "runtime_mount": str(self.root / "runtime"),
                        "input_helper": "bin/gptokeyb2", "input_library": "lib/libinterpose.aarch64.so",
                        "controller_database": "share/gamecontrollerdb.txt", "portmaster_directories": [str(self.pm)]}
        for name, data in {"bin/gptokeyb2": b"bundled helper", "lib/libinterpose.aarch64.so": b"bundled library",
                           "share/gamecontrollerdb.txt": b"0011,Fixture,a:b0,\n"}.items():
            path = self.bootstrap / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        patcher = mock.patch.dict(os.environ, {"HOME": str(self.home), "WINE_RUNNER_BOOTSTRAP": str(self.bootstrap)}, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def install_portmaster_input(self, machine=183):
        header = b"\x7fELF\x02\x01\x01".ljust(16, b"\0") + (3).to_bytes(2, "little") + machine.to_bytes(2, "little")
        (self.pm / "gptokeyb2").write_bytes(header + b"PM helper")
        (self.pm / "libinterpose.aarch64.so").write_bytes(header + b"PM library")
        (self.pm / "gamecontrollerdb.txt").write_text("0011,Fixture,a:b1,\n")
        # An input-only integration must not execute PortMaster's system setup.
        (self.pm / "control.txt").write_text("touch '" + str(self.root / "unexpected-control-execution") + "'\n")

    def test_portmaster_pair_and_mapping_are_preferred_without_modifying_the_installation(self):
        self.install_portmaster_input()
        before = {p.name: (p.read_bytes(), p.stat().st_mode) for p in self.pm.iterdir()}
        selected = resolve_input(self.profile, SOURCE, self.root / "data")
        self.assertEqual(selected["input_source"], "PortMaster")
        self.assertEqual(Path(selected["input_helper"]), self.pm / "gptokeyb2")
        self.assertEqual(Path(selected["input_library"]), self.pm / "libinterpose.aarch64.so")
        self.assertEqual(selected["input_fallback"]["input_helper"], str(self.bootstrap / "bin/gptokeyb2"))
        self.assertEqual(Path(selected["controller_database"]).read_text().splitlines(),
                         ["0011,Fixture,a:b0,", "0011,Fixture,a:b1,"])
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mode) for p in self.pm.iterdir()})
        self.assertFalse((self.root / "unexpected-control-execution").exists())
        self.assertEqual(self.profile["input_helper"], "bin/gptokeyb2")

    def test_missing_portmaster_uses_the_private_bundle(self):
        selected = resolve_input(self.profile, SOURCE, self.root / "data")
        self.assertEqual(selected["input_source"], "bundled")
        self.assertEqual(Path(selected["input_helper"]), self.bootstrap / "bin/gptokeyb2")
        self.assertNotIn("input_fallback", selected)
        self.assertEqual(Path(selected["controller_database"]).read_text(), "0011,Fixture,a:b0,\n")

    def test_incomplete_or_wrong_architecture_pair_falls_back_together_but_keeps_pm_mapping(self):
        for problem in ("missing_library", "wrong_helper_arch", "wrong_library_arch"):
            with self.subTest(problem=problem):
                self.install_portmaster_input()
                library = self.pm / "libinterpose.aarch64.so"
                if problem == "missing_library":
                    library.unlink()
                else:
                    path = library if problem == "wrong_library_arch" else self.pm / "gptokeyb2"
                    data = bytearray(path.read_bytes())
                    data[18:20] = (62).to_bytes(2, "little")
                    path.write_bytes(data)
                selected = resolve_input(self.profile, SOURCE, self.root / "data")
                self.assertEqual(selected["input_source"], "bundled")
                self.assertEqual(Path(selected["input_helper"]), self.bootstrap / "bin/gptokeyb2")
                self.assertEqual(Path(selected["input_library"]), self.bootstrap / "lib/libinterpose.aarch64.so")
                self.assertIn("0011,Fixture,a:b1,", Path(selected["controller_database"]).read_text())

    def test_user_and_exported_overrides_are_snapshotted_in_sdl_priority_order(self):
        self.install_portmaster_input()
        user = self.home / ".config/SDL-GameControllerDB/gamecontrollerdb.txt"
        user.parent.mkdir(parents=True)
        user.write_text("0011,Fixture,a:b2,\n")
        exported = self.root / "pm-get-controls.txt"
        exported.write_text("0011,Fixture,a:b3,\n")
        os.environ.update(SDL_GAMECONTROLLERCONFIG_FILE=str(exported),
                          sdl_controllerconfig="0011,Fixture,a:b4,", SDL_GAMECONTROLLERCONFIG="0011,Fixture,a:b5,")
        selected = resolve_input(self.profile, SOURCE, self.root / "data")
        snapshot = Path(selected["controller_database"])
        self.assertEqual(snapshot.read_text().splitlines(), [f"0011,Fixture,a:b{i}," for i in range(6)])
        exported.write_text("0011,Fixture,a:b9,\n")
        self.assertNotIn("a:b9", snapshot.read_text())
        self.assertEqual(user.read_text(), "0011,Fixture,a:b2,\n")

    def test_xdg_portmaster_location_uses_the_machine_search_order(self):
        self.install_portmaster_input()
        os.environ["XDG_DATA_HOME"] = str(self.root)
        self.profile["portmaster_directories"] = [str(self.root / "not-installed"), "{xdg_data_home}/PortMaster"]
        selected = resolve_input(self.profile, SOURCE, self.root / "data")
        self.assertEqual(Path(selected["input_helper"]), self.pm / "gptokeyb2")

    def test_unstartable_pm_helper_retries_bundled_pair_with_the_same_mapping(self):
        self.install_portmaster_input()
        selected = resolve_input(self.profile, SOURCE, self.root / "data")
        runtime = Path(selected["runtime_mount"])
        (runtime / "logs").mkdir(parents=True)
        event = self.root / "sys/event42"
        (event / "device").mkdir(parents=True)
        (event / "device/name").write_text("Fake Keyboard Mouse\n")
        process = mock.Mock()
        process.poll.return_value = None
        calls = []

        def spawn(command, **kwargs):
            tools = runtime / "input"
            calls.append(((tools / "gptokeyb2").read_bytes(), (tools / "libinterpose.aarch64.so").read_bytes(), kwargs["env"]))
            self.assertEqual(command[1:], ["-c", str(SOURCE / "desktop.gptk"), "-H", "guide"])
            if len(calls) == 1:
                raise OSError("fixture: installed helper requires another libc")
            return process

        with tempfile.TemporaryFile() as monitor:
            fd = os.dup(monitor.fileno())
            with mock.patch("wine_input.subprocess.Popen", side_effect=spawn), \
                 mock.patch("wine_input.Path.glob", side_effect=[[], [], [event]]), \
                 mock.patch("wine_input.os.open", return_value=fd), mock.patch("builtins.print"), \
                 InputSession(selected, SOURCE, launcher.Game("fixture", self.root)) as session:
                self.assertIs(session.process, process)
        self.assertEqual(calls[0][:2], ((self.pm / "gptokeyb2").read_bytes(), (self.pm / "libinterpose.aarch64.so").read_bytes()))
        self.assertEqual(calls[1][:2], (b"bundled helper", b"bundled library"))
        for _, _, env in calls:
            self.assertEqual(env["SDL_GAMECONTROLLERCONFIG_FILE"], selected["controller_database"])
            self.assertEqual(env["HOME"], str(runtime / "input/home"))
        process.terminate.assert_called_once()
        process.kill.assert_not_called()
        self.assertFalse((self.root / "unexpected-control-execution").exists())


class InputSessionTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(launcher, "installed", return_value=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_menu_grabs_sdl_existing_descriptor_without_opening_another_client(self):
        with mock.patch("wine_input.os.listdir", return_value=["4", "8"]), \
             mock.patch("wine_input.os.readlink", side_effect=["/tmp/other", "/dev/input/event4"]), \
             mock.patch("wine_input.os.path.realpath", side_effect=lambda path: path), \
             mock.patch("wine_input.fcntl.ioctl") as ioctl:
            self.assertEqual(grab_sdl_controller("/dev/input/event4"), 8)
            ioctl.assert_called_once_with(8, EVIOCGRAB, 1)

    def test_input_session_selects_the_game_mapping_or_default_and_has_no_kill_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "logs").mkdir()
            helper, library = root / "gptokeyb2", root / "libinterpose.so"
            helper.touch()
            library.touch()
            profile = {"runtime_mount": directory, "input_helper": str(helper),
                       "input_library": str(library), "controller_database": "/fixture/db.txt"}
            game = launcher.Game("game", root, input_mapping=root / "custom.gptk")
            for mapping in [root / "custom.gptk", None]:
                with self.subTest(mapping=mapping), mock.patch("wine_input.subprocess.Popen") as spawn:
                    game.input_mapping = mapping
                    spawn.side_effect = RuntimeError("stop before spawning")
                    with self.assertRaisesRegex(RuntimeError, "stop before spawning"):
                        InputSession(profile, SOURCE, game).__enter__()
                    self.assertEqual(spawn.call_args.args[0][1:],
                                     ["-c", str(mapping or SOURCE / "desktop.gptk"), "-H", "guide"])

    def test_session_cleanup_stops_only_its_helper_and_closes_its_descriptor(self):
        game = launcher.Game("game", SOURCE)
        session = InputSession({}, SOURCE, game)
        session.process = mock.Mock()
        session.process.poll.return_value = None
        session.log = io.StringIO()
        with tempfile.TemporaryFile() as event:
            descriptor = os.dup(event.fileno())
            session.keyboard_fd = descriptor
            session.close()
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        session.process.terminate.assert_called_once()
        session.process.kill.assert_not_called()
        self.assertIsNone(session.log)

    def test_failed_input_session_does_not_spawn_a_windows_program(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = launcher.Game("game", root, root / "game.exe")
            profile = {"runtime_mount": directory, "xdg_runtime_dir": "/run", "wayland_display": "wayland-0",
                       "controller_database": "/fixture/gamecontrollerdb.txt", "environment": "loongos-rk3566", "machine": "aarch64"}
            with mock.patch.object(launcher.subprocess, "run", return_value=mock.Mock(returncode=0)), \
                 mock.patch.object(launcher.subprocess, "Popen") as spawn, \
                 mock.patch.object(launcher, "InputSession") as session:
                session.return_value.__enter__.side_effect = RuntimeError("输入转换器启动失败")
                with self.assertRaisesRegex(RuntimeError, "输入转换器启动失败"):
                    run_selection(root, profile, game, SOURCE)
                spawn.assert_not_called()

    def test_plain_windows_exit_uses_its_own_normal_close_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "logs").mkdir()
            game = launcher.Game("game", root, root / "game.exe")
            profile = {"runtime_mount": directory, "xdg_runtime_dir": "/run", "wayland_display": "wayland-0",
                       "controller_database": "/fixture/gamecontrollerdb.txt", "environment": "loongos-rk3566", "machine": "aarch64"}
            with mock.patch.object(launcher.subprocess, "run", return_value=mock.Mock(returncode=0)) as command, \
                 mock.patch.object(launcher.subprocess, "Popen") as spawn, \
                 mock.patch.object(launcher, "InputSession") as session, \
                 mock.patch.object(launcher, "request_close") as close:
                spawn.return_value.poll.side_effect = [None, 0]
                spawn.return_value.wait.return_value = 0
                session.return_value.__enter__.return_value.force_exit_requested.return_value = True
                self.assertEqual(run_selection(root, profile, game, SOURCE), 0)
                close.assert_called_once_with(wine_session.session_directory(root, root),
                                              spawn.call_args.args[0][spawn.call_args.args[0].index("--presentation-token") + 1])
                self.assertEqual(len(command.call_args_list), 1)

    def test_graphics_exit_requests_normal_close_without_killing_wine_or_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "logs").mkdir()
            game = launcher.Game("game", root, root / "game.exe", graphics_api="d3d11")
            profile = {"runtime_mount": directory, "xdg_runtime_dir": "/run", "wayland_display": "wayland-0",
                       "controller_database": "/fixture/gamecontrollerdb.txt", "environment": "loongos-rk3566", "machine": "aarch64"}
            with mock.patch.object(launcher.subprocess, "run", return_value=mock.Mock(returncode=0)) as command, \
                 mock.patch.object(launcher.subprocess, "Popen") as spawn, \
                 mock.patch.object(launcher, "InputSession") as session, \
                 mock.patch.object(launcher, "request_close") as close, \
                 mock.patch.object(launcher.os, "killpg") as kill:
                spawn.return_value.poll.side_effect = [None, 0]
                spawn.return_value.wait.return_value = 0
                session.return_value.__enter__.return_value.force_exit_requested.return_value = True
                self.assertEqual(run_selection(root, profile, game, SOURCE), 0)
                close.assert_called_once_with(wine_session.session_directory(root, root),
                                              spawn.call_args.args[0][spawn.call_args.args[0].index("--presentation-token") + 1])
                self.assertEqual(len(command.call_args_list), 1)  # --prepare only
                kill.assert_not_called()
                spawn.return_value.kill.assert_not_called()

    def test_borderless_handoff_uses_machine_dimensions_and_preserves_game_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "logs").mkdir()
            game = launcher.Game("game", root, root / "My Game.exe", arguments=["a b", "$(literal)"],
                                 graphics_api="d3d11", borderless_fullscreen=True)
            profile = {"runtime_mount": directory, "xdg_runtime_dir": "/run", "wayland_display": "wayland-0",
                       "controller_database": "/fixture/gamecontrollerdb.txt", "environment": "loongos-rk3566", "machine": "aarch64", "display_size": [960, 720]}
            with mock.patch.object(launcher.subprocess, "run", return_value=mock.Mock(returncode=0)), \
                 mock.patch.object(launcher.subprocess, "Popen") as spawn, \
                 mock.patch.object(launcher, "InputSession") as inputs:
                spawn.return_value.poll.return_value = 0
                spawn.return_value.wait.return_value = 0
                self.assertEqual(run_selection(root, profile, game, SOURCE), 0)
                command = spawn.call_args.args[0]
                self.assertEqual(command[command.index("--borderless-size"):],
                                 ["--borderless-size", "960", "720", "--", "a b", "$(literal)"])
                self.assertIn("My Game.exe", command)
                profile.pop("display_size")
                inputs.reset_mock()
                spawn.reset_mock()
                with self.assertRaisesRegex(RuntimeError, "未设置全屏宽高"):
                    run_selection(root, profile, game, SOURCE)
                inputs.assert_not_called()
                spawn.assert_not_called()

    def test_force_exit_requires_a_held_chord_and_release_resets_it(self):
        chord = ExitChord()
        chord.update(1, 56, 1, 10)
        self.assertFalse(chord.held(20))
        chord.update(1, 62, 1, 20)
        self.assertFalse(chord.held(21.4))
        self.assertTrue(chord.held(21.5))
        chord.update(1, 62, 0, 21.6)
        self.assertFalse(chord.held(30))

    def test_keyboard_monitor_ignores_unrelated_events(self):
        chord = ExitChord()
        for event in [(2, 0, 15000), (1, 28, 1), (1, 1, 1)]:
            chord.update(*event, 10)
        self.assertFalse(chord.held(30))

    def test_missing_input_tools_fail_before_spawning_a_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = {"runtime_mount": directory, "input_helper": directory + "/missing",
                       "input_library": directory + "/also-missing"}
            game = launcher.Game("game", Path(directory), Path(directory) / "game.exe")
            session = InputSession(profile, SOURCE, game)
            with mock.patch("wine_input.subprocess.Popen") as spawn:
                with self.assertRaisesRegex(RuntimeError, "缺少配套输入工具"):
                    session.__enter__()
                spawn.assert_not_called()

    def test_first_game_installs_missing_environment_before_starting(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "logs").mkdir()
            profile = {"runtime_mount": str(root), "xdg_runtime_dir": "/run", "wayland_display": "wayland-0",
                       "controller_database": "/fixture/db", "environment": "loongos-rk3566", "machine": "aarch64",
                       "library_directory": str(root / "windows")}
            game = launcher.Game("game", root, root / "game.exe", graphics_api="d3d11")
            with mock.patch.object(launcher, "installed", side_effect=[False, True]), \
                 mock.patch.object(launcher, "install") as install, \
                 mock.patch.object(launcher.subprocess, "run", return_value=mock.Mock(returncode=0)), \
                 mock.patch.object(launcher.subprocess, "Popen") as child, \
                 mock.patch.object(launcher, "InputSession"):
                child.return_value.poll.return_value = 0
                child.return_value.wait.return_value = 0
                self.assertEqual(run_selection(root, profile, game, SOURCE), 0)
            self.assertEqual(install.call_args.args, (root, profile, ["d3d11"]))
            self.assertEqual(install.call_args.kwargs["offline"], (root / "windows/.winecellar/packages").resolve())

    def test_close_remains_responsive_while_wineserver_drains_child_processes(self):
        game, server, closer = mock.Mock(), mock.Mock(), mock.Mock()
        game.poll.return_value, game.returncode = 4, 4
        server.poll.side_effect = [None, 0]
        server.returncode = 0
        request = mock.Mock()
        request.open.side_effect = lambda *_: io.BytesIO(b"close " + b"a" * 32 + b"\n")
        environment = {"wine_root": "wine", "x86_library_path": "x86-libs", "process_environment": {}}
        with mock.patch.object(wine_session.subprocess, "Popen", side_effect=[game, server, closer]) as spawn, \
             mock.patch.object(wine_session.subprocess, "run") as blocking_wait, \
             mock.patch.object(wine_session, "Path", return_value=request), \
             mock.patch.object(wine_session.time, "sleep"), mock.patch.dict(os.environ), mock.patch("builtins.print"):
            self.assertEqual(wine_session.coordinate("game.exe", [], {}, environment, presentation_token="a" * 32), 4)
        blocking_wait.assert_not_called()
        self.assertEqual(spawn.call_count, 3)
        self.assertIn("Z:\\runtime\\graphics\\wine-close.exe", spawn.call_args.args[0])


class GraphicsStateTests(unittest.TestCase):
    def test_prepare_preserves_original_and_persistent_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime, game = root / "runtime", root / "game"
            (runtime / "prefixes/default/drive_c/users/root").mkdir(parents=True)
            (runtime / "prefixes/default/user.reg").write_text("template registry")
            game.mkdir()
            original = game / "game.exe"
            original.write_bytes(b"original")
            override = game / "copy.exe"
            override.write_bytes(b"test copy")
            (game / "game_Data").mkdir()
            state = wine_session.prepare(runtime, game, "game.exe", override)
            self.assertEqual(original.read_bytes(), b"original")
            self.assertEqual((state / "game/game.exe").read_bytes(), b"test copy")
            self.assertEqual((state / "game/game_Data").readlink(), Path("/game-original/game_Data"))
            registry = state / "work/prefix/user.reg"
            registry.write_text("saved game settings")
            wine_session.prepare(runtime, game, "game.exe", override)
            self.assertEqual(registry.read_text(), "saved game settings")

    def test_close_request_cannot_follow_a_guest_created_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "work").mkdir()
            outside = root / "outside"
            outside.write_text("unchanged")
            (root / "work/close-request").symlink_to(outside)
            with self.assertRaises(OSError):
                wine_session.request_close(root)
            self.assertEqual(outside.read_text(), "unchanged")



class RuntimeMountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "mounted runtime"
        self.image = self.base / "selected image.ext4"
        self.image.touch()
        self.info = self.base / "mountinfo"
        self.sysfs = self.base / "sysfs"
        self.backing = self.sysfs / "7:1/loop/backing_file"
        self.backing.parent.mkdir(parents=True)
        target = str(self.root).replace(" ", r"\040")
        self.info.write_text(f"55 1 7:1 / {target} rw,nosuid,nodev - ext4 /dev/loop1 rw\n")
        self.backing.write_text(str(self.image).replace(" ", r"\040") + "\n")

    def verify(self):
        runtime_mount.verify_mount(self.root, self.image, self.info, self.sysfs)

    def test_selected_loop_image_with_spaces_is_accepted(self):
        self.verify()

    def test_other_mounted_image_is_rejected_without_modifying_it(self):
        other = self.base / "another.ext4"
        other.write_bytes(b"other runtime")
        self.backing.write_text(str(other) + "\n")
        with self.assertRaisesRegex(ValueError, "Another Wine image"):
            self.verify()
        self.assertEqual(other.read_bytes(), b"other runtime")

    def test_missing_image_or_non_loop_mount_is_rejected(self):
        self.backing.unlink()
        with self.assertRaisesRegex(ValueError, "not mounted from a loop"):
            self.verify()
        self.image.unlink()
        with self.assertRaisesRegex(ValueError, "Missing Wine filesystem"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
