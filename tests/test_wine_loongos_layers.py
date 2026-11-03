#!/usr/bin/env python3
# INPUT:  临时机型/组件/游戏夹具与共享 Wine 安装、适配及准备接口
# OUTPUT: 分层依赖、共享安装、升级保留存档、补丁和发行边界的离线回归
# POS:    在不连接掌机、不执行游戏的条件下验证多游戏和多机型组合
import copy
import fcntl
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ports/wine-loongos/src"
sys.path.insert(0, str(SOURCE))
import wine_catalog as catalog
import runtime_install as installer
import wine_game
import wine_session


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))


def sha(data):
    return hashlib.sha256(data).hexdigest()


class DefinitionTests(unittest.TestCase):
    def test_host_prerequisites_do_not_require_portmaster_or_python(self):
        device = catalog.load_definition(SOURCE / "devices/miniloong-pocket-one.json", SOURCE / "devices")
        environment = catalog.load_environment(device)
        self.assertIn("/mnt/sdcard/roms/ports/PortMaster", device["portmaster_directories"])
        self.assertFalse(any("PortMaster" in path for path in environment["required_host_files"]))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in environment["required_host_files"] + [device["controller_device"]]:
                path = root / name.lstrip("/")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertEqual(catalog.host_requirements(device, environment, root), [])
            self.assertFalse((root / "usr/bin/python3").exists())
            with mock.patch.dict("os.environ", {"WINE_RUNNER_BOOTSTRAP": "/fixture/private"}):
                self.assertEqual(catalog.launcher_asset(device["input_helper"]), Path("/fixture/private/bin/gptokeyb2"))

    def test_family_base_and_device_override_are_composed_without_games(self):
        device = catalog.load_definition(SOURCE / "devices/miniloong-pocket-one.json", SOURCE / "devices")
        self.assertEqual(device["machine"], "aarch64")
        self.assertEqual(device["display_size"], [960, 720])
        self.assertEqual(device["environment"], "loongos-rk3566")
        environment = catalog.load_environment(device)
        self.assertEqual(environment["wine_root"], "wine-10.0-amd64-wow64")
        self.assertNotIn("Sunken", json.dumps(device) + json.dumps(environment))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_json(root / "base.json", {"input": {"grab": True, "axis": "left"}, "size": [960, 720]})
            write_json(root / "other.json", {"extends": "base.json", "input": {"axis": "right"}, "size": [1280, 720]})
            other = catalog.load_definition(root / "other.json")
            self.assertEqual(other["input"], {"grab": True, "axis": "right"})
            self.assertEqual(other["size"], [1280, 720])

    def test_inheritance_rejects_cycles_and_external_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_json(root / "a.json", {"extends": "b.json"})
            write_json(root / "b.json", {"extends": "a.json"})
            with self.assertRaises(ValueError):
                catalog.load_definition(root / "a.json")
            write_json(root / "a.json", {"extends": "../outside.json"})
            with self.assertRaises(ValueError):
                catalog.load_definition(root / "a.json")

    def test_detection_requires_firmware_hardware_and_device_identifiers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "etc").mkdir()
            (root / "etc/os-release").write_text('ID=loong\nVERSION_ID="1.4.0.36"\n')
            (root / "proc/device-tree").mkdir(parents=True)
            (root / "proc/device-tree/compatible").write_bytes(b"board\0rockchip,rk3566\0")
            for name in ["usr/lib/libloong_sdk.so", "dev/input/by-path/platform-loong1_joypad-event-joystick"]:
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.touch()
            self.assertEqual(catalog.detect_device(system_root=root, machine="aarch64")["id"], "miniloong-pocket-one")
            (root / "etc/os-release").write_text('ID=loong\nVERSION_ID=1.4.0.99\n')
            with self.assertRaisesRegex(RuntimeError, "尚无匹配"):
                catalog.detect_device(system_root=root, machine="aarch64")

    def test_game_api_selects_shared_provider_and_never_silently_downgrades(self):
        device = catalog.load_definition(SOURCE / "devices/miniloong-pocket-one.json", SOURCE / "devices")
        environment = catalog.load_environment(device)
        one, graphics = catalog.resolve_components(environment, "d3d11")
        two, _ = catalog.resolve_components(environment, "d3d11")
        self.assertEqual(one, two)
        self.assertEqual(graphics["provider"], "dxvk-sarek")
        self.assertEqual([x["id"] for x in one].count("dxvk-sarek"), 1)
        native, graphics = catalog.resolve_components(environment, "vulkan")
        self.assertEqual(graphics["dlls"], [])
        self.assertNotIn("dxvk-sarek", [x["id"] for x in native])
        for api in ["d3d9", "d3d12"]:
            with self.assertRaisesRegex(RuntimeError, api.upper()):
                catalog.resolve_components(environment, api)
        # A different family can enable D3D9 using the same component archive.
        other = copy.deepcopy(environment)
        other["graphics"]["d3d9"] = dict(other["graphics"]["d3d11"], dlls=["d3d9.dll"])
        selected, graphics = catalog.resolve_components(other, "d3d9")
        self.assertEqual(graphics["provider"], "dxvk-sarek")
        self.assertEqual(next(x for x in one if x["id"] == "dxvk-sarek")["sha256"],
                         next(x for x in selected if x["id"] == "dxvk-sarek")["sha256"])


class ComponentInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.offline = self.root / "packages"
        self.offline.mkdir()
        self.runtime = self.root / "mounted"
        self.cache = self.root / "downloads"
        self.catalog = {}
        patcher = mock.patch.object(installer, "ROOT", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def component(self, name, files):
        archive = self.offline / (name + ".tar.gz")
        with tarfile.open(archive, "w:gz") as output:
            for filename, data in files.items():
                entry = tarfile.TarInfo(filename)
                entry.size = len(data)
                output.addfile(entry, io.BytesIO(data))
        item = {"id": name, "archive": archive.name, "sha256": catalog.digest(archive),
                "unpacked_bytes": sum(map(len, files.values())), "bytes": archive.stat().st_size, "files": list(files)}
        self.catalog[name] = item
        write_json(self.root / "components/catalog.json", {"components": self.catalog})
        return item

    def install(self, components):
        return installer.install_components(self.runtime, components, self.cache, self.offline, progress=lambda _: None)

    def test_two_games_reuse_one_install_and_keep_separate_prefixes(self):
        core = self.component("core", {"bin/wine": b"fixture core"})
        graphics = self.component("d3d11", {"graphics/d3d11.dll": b"fixture graphics"})
        self.install([core, graphics])
        release = (self.runtime / "runtime").readlink()
        game_a, game_b = self.root / "game-a", self.root / "game-b"
        for game in [game_a, game_b]:
            game.mkdir()
            (game / "game.exe").write_bytes(b"user supplied")
        a = wine_session.prepare(self.runtime, game_a, "game.exe", None)
        b = wine_session.prepare(self.runtime, game_b, "game.exe", None)
        self.assertNotEqual(a, b)
        (a / "work/prefix").mkdir(exist_ok=True)
        (a / "work/prefix/user.reg").write_text("player save")
        self.install([core, graphics])
        self.assertEqual((self.runtime / "runtime").readlink(), release)
        self.assertEqual((a / "work/prefix/user.reg").read_text(), "player save")
        self.assertEqual(len(list((self.runtime / "releases").iterdir())), 1)

    def test_adding_a_provider_keeps_previous_provider_and_player_data(self):
        core = self.component("core", {"bin/wine": b"core"})
        d11 = self.component("d11", {"graphics/d11.dll": b"d11"})
        d9 = self.component("d9", {"graphics/d9.dll": b"d9"})
        self.install([core, d11])
        original_inode = (self.runtime / "runtime/bin/wine").stat().st_ino
        (self.runtime / "sessions/save.txt").write_text("save")
        self.install([core, d9])
        self.assertTrue(installer.installed(self.runtime, [core, d11, d9]))
        self.assertEqual((self.runtime / "runtime/bin/wine").stat().st_ino, original_inode)
        self.assertEqual((self.runtime / "sessions/save.txt").read_text(), "save")

    def test_corrupt_download_does_not_replace_a_working_environment(self):
        core = self.component("core", {"bin/wine": b"core"})
        self.install([core])
        before = (self.runtime / "runtime").readlink()
        broken = self.component("new", {"graphics/new.dll": b"valid"})
        (self.offline / broken["archive"]).write_bytes(b"corrupt")
        with self.assertRaisesRegex(RuntimeError, "校验失败"):
            self.install([core, broken])
        self.assertEqual((self.runtime / "runtime").readlink(), before)

    def test_active_session_blocks_component_replacement(self):
        core = self.component("core", {"bin/wine": b"core"})
        self.install([core])
        extra = self.component("extra", {"extra.dll": b"extra"})
        with (self.runtime / "environment.lock").open("r") as lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
            with self.assertRaises(BlockingIOError):
                self.install([core, extra])
        self.assertFalse((self.runtime / "runtime/extra.dll").exists())

    def test_missing_runtime_file_can_be_repaired_without_losing_player_data(self):
        core = self.component("core", {"bin/wine": b"core"})
        self.install([core])
        (self.runtime / "runtime/bin/wine").unlink()
        (self.runtime / "sessions/player.txt").write_text("keep")
        self.assertFalse(installer.installed(self.runtime, [core]))
        self.install([core])
        self.assertTrue(installer.installed(self.runtime, [core]))
        self.assertEqual((self.runtime / "sessions/player.txt").read_text(), "keep")

    def test_archive_escape_links_and_missing_files_are_rejected(self):
        for name in ["../outside", "/outside"]:
            with self.subTest(name=name):
                item = self.component("bad", {name: b"bad"})
                with self.assertRaises(ValueError):
                    self.install([item])
        path = self.offline / "link.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            entry = tarfile.TarInfo("escape")
            entry.type, entry.linkname = tarfile.SYMTYPE, "../../outside"
            archive.addfile(entry)
        with self.assertRaises(ValueError):
            installer.extract_component(path, self.root / "target", {"files": ["escape"]})
        self.assertFalse((self.root / "outside").exists())

    def test_absent_publication_url_is_explicit_and_not_a_fake_download(self):
        with self.assertRaisesRegex(RuntimeError, "尚未配置 HTTPS"):
            installer.acquire({"id": "absent", "archive": "absent.tar.gz", "sha256": "0" * 64}, self.cache)


class GamePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.game = self.root / "game"
        self.game.mkdir()
        self.adapter = {"id": "fixture", "title": "Fixture", "executable": "Game.exe", "architecture": "x86_64",
                        "graphics_api": "d3d11", "required_files": ["Game.exe"], "arguments": [], "environment": {},
                        "input_mapping": "input.gptk", "input_help": "A", "borderless_fullscreen": True, "status": "fixture only"}

    def test_game_adapter_rejects_machine_and_runtime_configuration(self):
        for field in ["base_components", "process_environment", "runtime_mount", "graphics"]:
            with self.subTest(field=field):
                data = dict(self.adapter, **{field: {}})
                write_json(self.root / "adapters/fixture/adapter.json", data)
                with self.assertRaisesRegex(ValueError, "混入"):
                    wine_game.load_adapter("fixture", self.root)

    def test_user_files_are_required_and_unsupported_versions_are_clear(self):
        state = wine_game.inspect_game(self.game, self.adapter)
        self.assertEqual(state["state"], "missing-files")
        self.assertEqual(state["missing"], ["Game.exe"])
        (self.game / "Game.exe").write_bytes(b"original")
        self.adapter["preparation"] = {"kind": "verified-executable", "source_sha256": sha(b"original"),
                                       "output_sha256": sha(b"prepared"), "output": ".wine/Game.exe", "tool": "fixture"}
        self.assertEqual(wine_game.inspect_game(self.game, self.adapter)["state"], "needs-preparation")
        (self.game / ".wine").mkdir()
        (self.game / ".wine/Game.exe").write_bytes(b"prepared")
        self.assertEqual(wine_game.inspect_game(self.game, self.adapter)["state"], "ready")
        (self.game / "Game.exe").write_bytes(b"unknown version")
        self.assertEqual(wine_game.inspect_game(self.game, self.adapter)["state"], "unsupported-version")

    def test_optional_resource_patch_creates_verified_copy_and_preserves_original(self):
        (self.game / "Game.exe").write_bytes(b"user exe")
        original, modified = b"hp=10", b"hp=99"
        (self.game / "data.cfg").write_bytes(original)
        self.adapter["patches"] = [{"id": "optional-hp", "optional": True, "file": "data.cfg", "input_sha256": sha(original),
                                     "output_sha256": sha(modified), "writes": [{"offset": 3, "hex": b"99".hex()}]}]
        wine_game.prepare_resources(self.game, self.adapter)
        self.assertFalse((self.game / ".wine/patched/data.cfg").exists())
        wine_game.prepare_resources(self.game, self.adapter, ["optional-hp"])
        self.assertEqual((self.game / "data.cfg").read_bytes(), original)
        self.assertEqual((self.game / ".wine/patched/data.cfg").read_bytes(), modified)
        state = wine_game.inspect_game(self.game, self.adapter)
        self.assertEqual(state["resource_overrides"], {"data.cfg": ".wine/patched/data.cfg"})
        (self.game / "data.cfg").write_bytes(b"wrong version")
        with self.assertRaisesRegex(ValueError, "版本不匹配"):
            wine_game.prepare_resources(self.game, self.adapter, ["optional-hp"])

    def test_resource_version_is_checked_even_when_executable_matches(self):
        (self.game / "Game.exe").write_bytes(b"user exe")
        (self.game / "data.cfg").write_bytes(b"other release")
        self.adapter["file_hashes"] = {"data.cfg": sha(b"supported release")}
        self.assertEqual(wine_game.inspect_game(self.game, self.adapter)["state"], "unsupported-version")

    def test_graphics_provider_change_updates_only_shared_links(self):
        (self.game / "Game.exe").write_bytes(b"user exe")
        runtime = self.root / "runtime"
        (runtime / "prefixes/default").mkdir(parents=True)
        first = {"dlls": ["d3d11.dll", "dxgi.dll"], "directory": "graphics/provider-a"}
        state = wine_session.prepare(runtime, self.game, "Game.exe", None, first)
        self.assertEqual((state / "game/d3d11.dll").readlink(), Path("/runtime/graphics/provider-a/d3d11.dll"))
        second = dict(first, directory="graphics/provider-b")
        wine_session.prepare(runtime, self.game, "Game.exe", None, second)
        self.assertEqual((state / "game/d3d11.dll").readlink(), Path("/runtime/graphics/provider-b/d3d11.dll"))
        wine_session.prepare(runtime, self.game, "Game.exe", None)
        self.assertFalse((state / "game/d3d11.dll").is_symlink())
        self.assertEqual((self.game / "Game.exe").read_bytes(), b"user exe")

    def test_links_cannot_redirect_game_preparation_outside_user_folder(self):
        outside = self.root / "outside.exe"
        outside.write_bytes(b"outside")
        (self.game / "Game.exe").symlink_to(outside)
        with self.assertRaises(ValueError):
            wine_game.inspect_game(self.game, self.adapter)

    def test_independent_game_zip_owns_no_shared_application_directory(self):
        spec = importlib.util.spec_from_file_location("wine_game_distribution", SOURCE / "scripts/dist-game.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        path = module.build("sunken-dragon", self.root)
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            self.assertTrue(any(name.endswith("adapter.json") for name in names))
            self.assertFalse(any(name.startswith("wine-loongos/") for name in names))
            self.assertFalse(any(name.endswith((".exe", ".dll", ".ext4")) for name in names))
            bottle = json.loads(archive.read("roms/windows/sunken-dragon/bottle.json"))
            self.assertEqual(bottle["items"], ["Je-龙沉异世录.sh", "sunken-dragon"])
            self.assertNotIn(".winecellar", bottle["items"])
            self.assertIn("roms/windows/sunken-dragon/data/README.txt", names)


if __name__ == "__main__":
    unittest.main()
