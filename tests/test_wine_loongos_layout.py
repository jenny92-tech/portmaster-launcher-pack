#!/usr/bin/env python3
# INPUT:  临时 SD 卡目录、ROCKNIX bottle 夹具与实际发行/入口脚本
# OUTPUT: Windows/.winecellar 布局、描述转换、独立包和首页桥接的回归结果
# POS:    不连接设备、不执行游戏，验证空白安装的统一落盘契约
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ports/wine-loongos/src"
sys.path.insert(0, str(SOURCE))
from wine_catalog import load_definition
from wine_layout import APP_REL, WINDOWS_REL, PACKAGES_REL, state_directory, offline_directory
from wine_game import load_adapter
import wine_session


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


launcher = module("wine_rocknix_launcher", SOURCE / "launcher.py")
runner_pack = module("wine_rocknix_runner_pack", SOURCE / "scripts/dist-zip.py")
game_pack = module("wine_rocknix_game_pack", SOURCE / "scripts/dist-game.py")
starter_pack = module("wine_rocknix_starter_pack", SOURCE / "scripts/dist-starter.py")


class BottleLayoutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.library = self.root / WINDOWS_REL
        self.library.mkdir(parents=True)
        self.base = state_directory(self.library)
        self.profile = load_definition(SOURCE / "devices/miniloong-pocket-one.json", SOURCE / "devices")
        self.profile.update(library_directory=str(self.library), runtime_mount=str(self.root / "mount"))
        patcher = mock.patch.dict(os.environ, {}, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def bottle(self, name="fixture", **extra):
        directory = self.library / name
        (directory / "data").mkdir(parents=True)
        (directory / "data/Game.exe").write_bytes(b"fixture only; never execute")
        definition = {"runner": "default", "deps": ["dxvk"], "env": {"WINEARCH": "win64", "WINEDEBUG": "-all"},
                      "configdir": ["drive_c/users/root/AppData/Local/Fixture"],
                      "wine_runner": {"executable": "Game.exe", "graphics_api": "d3d11", "arguments": ["a b", "$(literal)"]},
                      "attr": {"title": "Fixture title"}}
        definition.update(extra)
        (directory / "bottle.json").write_text(json.dumps(definition))
        return directory

    def test_device_uses_windows_library_and_state_inside_winecellar(self):
        device = load_definition(SOURCE / "devices/miniloong-pocket-one.json", SOURCE / "devices")
        self.assertEqual(device["library_directory"], "/mnt/sdcard/roms/windows")
        self.assertNotIn("data_directory", device)
        self.assertNotIn("game_directories", device)
        self.assertEqual(state_directory(self.library), self.library / ".winecellar/state")
        self.assertEqual(offline_directory(self.library), self.library / ".winecellar/packages")

    def test_bottle_maps_entry_api_dependencies_environment_and_input_without_running_shell(self):
        directory = self.bottle(env={"WINEARCH": "win64", "SteamAppId": "42"})
        (directory / "input.gptk").write_text("a=return\n")
        definition = json.loads((directory / "bottle.json").read_text())
        definition["wine_runner"]["input_mapping"] = "input.gptk"
        (directory / "bottle.json").write_text(json.dumps(definition))
        (self.library / "Fixture.sh").write_text("exit 99\n")
        with mock.patch.object(launcher.subprocess, "run") as run, mock.patch.object(launcher.subprocess, "Popen") as spawn:
            games = launcher.discover_games(self.base, self.profile, SOURCE)
        self.assertEqual(len(games), 1)
        game = games[0]
        self.assertFalse(game.error)
        self.assertEqual(game.directory, directory / "data")
        self.assertEqual(game.executable, directory / "data/Game.exe")
        self.assertEqual(game.title, "Fixture title")
        self.assertEqual(game.graphics_api, "d3d11")
        self.assertEqual(game.arguments, ["a b", "$(literal)"])
        self.assertEqual(game.environment, {"SteamAppId": "42"})
        self.assertEqual(game.input_mapping, directory / "input.gptk")
        self.assertEqual(game.config_directories, ["drive_c/users/root/AppData/Local/Fixture"])
        run.assert_not_called()
        spawn.assert_not_called()
        self.assertFalse(self.base.exists())

    def test_unknown_dependencies_runner_or_environment_fail_before_any_wine_setup(self):
        cases = [{"deps": ["vcrun2022"]}, {"runner": "proton"}, {"runner": "../../bin/sh"},
                 {"env": {"WINEPREFIX": "/outside"}}, {"env": {"LD_PRELOAD": "/outside.so"}},
                 {"env": {"WINEARCH": "win32"}}, {"deps": "dxvk"}, {"configdir": ["../outside"]},
                 {"wine_runner": {"executable": "../Game.exe", "graphics_api": "d3d11"}}]
        for index, definition in enumerate(cases):
            with self.subTest(definition=definition):
                directory = self.bottle("invalid-" + str(index), **definition)
                game = launcher.read_bottle(directory)
                self.assertTrue(game.error)
                with mock.patch.object(launcher.subprocess, "run") as run, mock.patch.object(launcher.subprocess, "Popen") as spawn:
                    with self.assertRaises(RuntimeError):
                        launcher.run_selection(self.base, self.profile, game, SOURCE)
                run.assert_not_called()
                spawn.assert_not_called()

    def test_bare_community_bottle_requires_explicit_api_for_dxvk(self):
        game = launcher.read_bottle(self.bottle(wine_runner={}))
        self.assertIn("明确", game.error)
        self.assertIsNone(game.executable)

    def test_shared_tools_and_external_bottles_are_not_discovered(self):
        expected = self.bottle()
        for name in [".winecellar", "_tests"]:
            directory = self.library / name
            directory.mkdir()
            (directory / "bottle.json").write_text("{}")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "bottle.json").write_text("{}")
        (self.library / "outside-link").symlink_to(outside)
        (self.library / "winecfg.exe").write_bytes(b"not an entry")
        games = launcher.discover_games(self.base, self.profile)
        self.assertEqual([game.directory for game in games], [expected / "data"])

    def test_bottle_data_mapping_and_manifest_symlinks_cannot_escape_its_directory(self):
        directory = self.bottle()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "Game.exe").write_bytes(b"outside")
        shutil.rmtree(directory / "data")
        (directory / "data").symlink_to(outside)
        self.assertTrue(launcher.read_bottle(directory).error)
        (directory / "data").unlink()
        (directory / "data").mkdir()
        (directory / "bottle.json").unlink()
        (outside / "bottle.json").write_text("{}")
        (directory / "bottle.json").symlink_to(outside / "bottle.json")
        self.assertTrue(launcher.read_bottle(directory).error)

    def test_registered_adapter_checks_resource_version_under_data(self):
        directory = self.library / "sunken-dragon"
        directory.mkdir()
        for name in ["adapter.json", "bottle.json", "input.gptk"]:
            shutil.copyfile(SOURCE / "adapters/sunken-dragon" / name, directory / name)
        game = launcher.read_bottle(directory)
        self.assertEqual(game.adapter_id, "sunken-dragon")
        self.assertEqual(game.directory, directory / "data")
        self.assertIn("待补游戏文件", game.error)
        self.assertEqual(game.graphics_api, "d3d11")
        self.assertEqual(load_adapter("sunken-dragon", directory=directory)["id"], "sunken-dragon")

    def test_d3d12_is_not_enabled_just_because_bottle_requests_it(self):
        directory = self.bottle(deps=["vkd3d-proton"], wine_runner={"executable": "Game.exe", "graphics_api": "d3d12"})
        game = launcher.read_bottle(directory)
        self.assertFalse(game.error)
        with mock.patch.object(launcher.subprocess, "run") as run, mock.patch.object(launcher.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(RuntimeError, "D3D12"):
                launcher.run_selection(self.base, self.profile, game, SOURCE)
        run.assert_not_called()
        spawn.assert_not_called()

    def test_two_windows_bottles_keep_different_persistent_session_directories(self):
        one = self.bottle("one")
        two = self.bottle("two")
        games = launcher.discover_games(self.base, self.profile)
        states = [wine_session.session_directory(Path(self.profile["runtime_mount"]), game.directory) for game in games]
        self.assertEqual(len(states), 2)
        self.assertNotEqual(states[0], states[1])
        self.assertEqual({game.directory for game in games}, {one / "data", two / "data"})

    def test_print_base_returns_new_private_state_without_creating_old_paths(self):
        profile = self.root / "profile.json"
        profile.write_text(json.dumps(self.profile))
        with mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(launcher.main(["--profile", str(profile), "--print-base"]), 0)
        self.assertEqual(output.getvalue().strip(), str(self.library / ".winecellar/state"))
        self.assertFalse((self.root / "wine-loongos/games").exists())
        self.assertFalse(self.base.exists())


class SdcardPackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["bash", str(ROOT / "_kit/dist_port.sh"), "wine-loongos"], cwd=ROOT,
                       check=True, capture_output=True, text=True)

    def test_new_machine_extract_and_real_ports_bridge_find_windows_game_without_portmaster(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core = runner_pack.build(ROOT / "ports/wine-loongos/dist", root / "runner.zip")
            game = game_pack.build("sunken-dragon", root)
            sd = root / "sd"
            for package in [core, game]:
                with zipfile.ZipFile(package) as archive:
                    archive.extractall(sd)
            fixture = sd / WINDOWS_REL / "fixture"
            (fixture / "data").mkdir(parents=True)
            (fixture / "data/Game.exe").write_bytes(b"not executable")
            (fixture / "bottle.json").write_text(json.dumps({"attr": {"title": "Custom fixture"}}))
            app = sd / APP_REL
            profile = app / "devices/miniloong-pocket-one.json"
            env = {"PATH": os.environ["PATH"], "HOME": str(root / "empty-home"), "WINE_RUNNER_PYTHON": sys.executable}
            result = subprocess.run(["sh", str(sd / "roms/ports/Je-Wine.sh"), "--list", "--profile", str(profile)],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            state = sd / WINDOWS_REL / ".winecellar/state"
            output = (state / "launcher.log").read_text()
            self.assertIn("[BUILD] package=wine-loongos", output)
            games = json.loads(output.split("\n", 1)[1])
            self.assertIn("Custom fixture", [item["title"] for item in games])
            dragon = next(item for item in games if item["title"] == "Je-龙沉异世录")
            self.assertIn("待补游戏文件", dragon["error"])
            self.assertFalse((sd / "wine-loongos").exists())
            self.assertFalse((state / "games").exists())
            self.assertFalse((sd / "roms/ports/wine-loongos").exists())
            self.assertFalse((state / "runtime.ext4").exists())

    def test_starter_preserves_canonical_layout_and_contains_only_intended_frontend_scripts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = runner_pack.build(ROOT / "ports/wine-loongos/dist", root / "runner.zip")
            game = game_pack.build("sunken-dragon", root)
            runtime = root / "runtime.zip"
            with zipfile.ZipFile(runtime, "w") as archive:
                archive.writestr((APP_REL / "components/catalog.json").as_posix(), (SOURCE / "components/catalog.json").read_bytes())
                archive.writestr((PACKAGES_REL / "fixture.tar.gz").as_posix(), b"fixture package")
            starter = root / "starter.zip"
            starter_pack.build([runner, runtime, game], starter)
            with zipfile.ZipFile(starter) as archive:
                scripts = {name for name in archive.namelist() if name.endswith(".sh") and ".winecellar/" not in name}
                self.assertEqual(scripts, {"roms/windows/Je-Wine.sh", "roms/windows/Je-龙沉异世录.sh",
                                           "roms/ports/Je-Wine.sh", "roms/ports/Je-龙沉异世录.sh"})
                self.assertIn((PACKAGES_REL / "fixture.tar.gz").as_posix(), archive.namelist())
                self.assertIn("SD 卡根目录", archive.read("先看这里.txt").decode())
                self.assertFalse(any(name.endswith((".exe", ".dll", ".ext4", ".log")) for name in archive.namelist()))
                self.assertFalse(any("wine-game-sunken-dragon/" in name for name in archive.namelist()))


if __name__ == "__main__":
    unittest.main()
