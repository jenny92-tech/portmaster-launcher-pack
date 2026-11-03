#!/usr/bin/env python3
# INPUT:  临时 SD 卡、标准 ZIP 与可信组件目录夹具
# OUTPUT: 离线包内容识别、固定目录发现、校验隔离和真实安装入口的回归结果
# POS:    不连接设备，验证可改名运行包不会覆盖运行器、游戏或玩家存档
import copy
import importlib.util
import io
import json
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ports/wine-loongos/src"
sys.path.insert(0, str(SOURCE))
import runtime_install as installer
from wine_catalog import digest
from wine_layout import APP_REL, PACKAGES_REL, WINDOWS_REL, offline_directory, state_directory
import wine_package as packages

spec = importlib.util.spec_from_file_location("wine_offline_pack_builder", SOURCE / "scripts/build-runtime.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class OfflinePackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.sd = self.root / "sd"
        self.library = self.sd / WINDOWS_REL
        self.library.mkdir(parents=True)
        self.config = self.root / "source"
        self.raw = self.root / "raw"
        self.raw.mkdir()
        self.base = state_directory(self.library)
        self.cache = self.base / "downloads"
        self.runtime = self.root / "mounted"
        self.environment = {"id": "fixture", "machine": "aarch64", "base_components": ["core"]}
        (self.config / "environments").mkdir(parents=True)
        (self.config / "environments/fixture.json").write_text(json.dumps(self.environment))
        self.catalog = {}
        for name in ["core", "graphics"]:
            path = self.raw / (name + ".tar.gz")
            payload = (name + " fixture").encode()
            filename = "bin/" + name
            with tarfile.open(path, "w:gz") as archive:
                item = tarfile.TarInfo(filename)
                item.size = len(payload)
                archive.addfile(item, io.BytesIO(payload))
            self.catalog[name] = {"archive": path.name, "bytes": path.stat().st_size, "sha256": digest(path),
                                  "files": [filename], "unpacked_bytes": len(payload)}
        (self.config / "components").mkdir()
        self.catalog_path = self.config / "components/catalog.json"
        self.catalog_path.write_text(json.dumps({"components": self.catalog}))
        self.items = [dict(item, id=name) for name, item in self.catalog.items()]
        self.manifest = packages.runtime_package_manifest(self.catalog, self.config)
        self.messages = []

    def package(self, path=None, manifest=None, payloads=None, extras=(), compression=zipfile.ZIP_STORED):
        path = path or self.sd / "renamed.data"
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w", compression=compression) as archive:
            if manifest is not False:
                archive.writestr(packages.PACKAGE_MANIFEST, json.dumps(self.manifest if manifest is None else manifest))
            for name, item in self.catalog.items():
                data = (self.raw / item["archive"]).read_bytes() if payloads is None else payloads[name]
                archive.writestr((PACKAGES_REL / item["archive"]).as_posix(), data)
            for name, payload in extras:
                archive.writestr(name, payload)
        return path

    def import_packages(self, offline=None, items=None):
        packages.import_runtime_packages(self.library, self.items if items is None else items, self.cache,
                                         self.environment, offline=offline, root=self.config, progress=self.messages.append)

    def assert_imported(self):
        for item in self.items:
            self.assertEqual(digest(self.cache / item["archive"]), item["sha256"])

    def test_standard_zip_in_sd_root_is_found_after_filename_and_extension_change(self):
        path = self.package()
        self.assertEqual(path.suffix, ".data")
        self.import_packages()
        self.assert_imported()
        self.assertTrue(path.exists(), "import must preserve the user's original ZIP")
        self.assertIn("发现离线运行包：renamed.data", self.messages)

    def test_windows_library_and_component_directory_are_scanned_without_recursion(self):
        for directory in [self.library, offline_directory(self.library)]:
            with self.subTest(directory=directory):
                path = self.package(directory / "anything.ZIP", compression=zipfile.ZIP_DEFLATED)
                self.import_packages()
                self.assert_imported()
                path.unlink()
                for item in self.items:
                    (self.cache / item["archive"]).unlink()
        self.package(self.sd / "unrelated/subdirectory/package.zip")
        self.import_packages()
        self.assertFalse(any(self.cache.iterdir()))

    def test_custom_library_does_not_scan_arbitrary_parent_directories(self):
        library = self.root / "custom-library"
        library.mkdir()
        path = self.package(self.root / "outside.zip")
        self.assertNotIn(path, packages.package_candidates(library))

    def test_explicit_zip_and_explicit_inbox_directory_are_supported(self):
        path = self.package(self.root / "inbox/anything.bin")
        self.import_packages(offline=path)
        self.assert_imported()
        for item in self.items:
            (self.cache / item["archive"]).unlink()
        self.import_packages(offline=path.parent)
        self.assert_imported()

    def test_unrelated_zip_and_non_zip_files_are_ignored(self):
        self.package(self.sd / "ordinary.zip", manifest=False)
        (self.sd / "notes.txt").write_text("not a package")
        self.import_packages()
        self.assertFalse(self.cache.exists())
        self.assertFalse(self.messages)

    def test_wrong_product_or_package_kind_is_not_imported(self):
        for field, value in [("product", "another-app"), ("kind", "game")]:
            manifest = dict(self.manifest, **{field: value})
            path = self.package(manifest=manifest)
            with self.assertRaisesRegex(RuntimeError, "不是适用"):
                self.import_packages(offline=path)
            self.assertFalse(self.cache.exists())

    def test_wrong_architecture_or_environment_is_rejected(self):
        for extra in [{"machine": "x86_64"}, {"environments": ["another-firmware"]}, {"environments": "fixture"}]:
            with self.subTest(extra=extra):
                path = self.package(manifest=dict(self.manifest, **extra))
                with self.assertRaisesRegex(RuntimeError, "机型环境"):
                    self.import_packages(offline=path)
                self.assertFalse(self.cache.exists())

    def test_package_cannot_supply_its_own_trusted_catalog(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["components"]["core"]["sha256"] = "0" * 64
        path = self.package(manifest=manifest, extras=[((APP_REL / "components/catalog.json").as_posix(), json.dumps(manifest))])
        before = self.catalog_path.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "目录不匹配"):
            self.import_packages(offline=path)
        self.assertEqual(self.catalog_path.read_bytes(), before)
        self.assertFalse(self.cache.exists())

    def test_unknown_components_are_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["components"]["unknown"] = manifest["components"]["core"]
        path = self.package(manifest=manifest)
        with self.assertRaisesRegex(RuntimeError, "目录不匹配"):
            self.import_packages(offline=path)

    def test_corrupt_component_does_not_publish_earlier_staged_components(self):
        payloads = {name: (self.raw / item["archive"]).read_bytes() for name, item in self.catalog.items()}
        payloads["graphics"] = b"x" * len(payloads["graphics"])
        path = self.package(payloads=payloads)
        with self.assertRaisesRegex(RuntimeError, "校验失败"):
            self.import_packages(offline=path)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_missing_and_truncated_members_are_rejected(self):
        payloads = {name: b"short" for name in self.catalog}
        path = self.package(payloads=payloads)
        with self.assertRaisesRegex(RuntimeError, "大小不符"):
            self.import_packages(offline=path)
        path = self.sd / "missing.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(packages.PACKAGE_MANIFEST, json.dumps(self.manifest))
        with self.assertRaisesRegex(RuntimeError, "缺失"):
            self.import_packages(offline=path)

    def test_duplicate_traversal_and_symlink_members_are_rejected(self):
        link = zipfile.ZipInfo("link")
        link.create_system, link.external_attr = 3, (stat.S_IFLNK | 0o777) << 16
        for member in ["../outside", "/outside", "directory/../outside", "a\\b", link,
                       packages.PACKAGE_MANIFEST]:
            with self.subTest(member=member), warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                path = self.package(extras=[(member, "../../outside")])
                with self.assertRaises(RuntimeError):
                    self.import_packages(offline=path)
                self.assertFalse(self.cache.exists())
                self.assertFalse((self.sd / "outside").exists())

    def test_oversized_identity_manifest_is_rejected(self):
        manifest = dict(self.manifest, padding="x" * (64 * 1024))
        path = self.package(manifest=manifest)
        with self.assertRaisesRegex(RuntimeError, "清单过大"):
            self.import_packages(offline=path)

    def test_extra_scripts_and_catalog_are_never_extracted(self):
        path = self.package(extras=[("roms/ports/evil.sh", "exit 99"),
                                   ((APP_REL / "components/catalog.json").as_posix(), "not trusted")])
        self.import_packages(offline=path)
        self.assert_imported()
        self.assertFalse((self.sd / "roms/ports/evil.sh").exists())
        self.assertFalse((self.sd / APP_REL).exists())

    def test_invalid_candidate_does_not_hide_a_later_valid_bundle(self):
        self.package(self.sd / "a-bad.zip", manifest=dict(self.manifest, machine="x86_64"))
        self.package(self.sd / "z-good.zip")
        self.import_packages()
        self.assert_imported()
        self.assertTrue(any("跳过" in message for message in self.messages))

    def test_components_can_be_collected_from_multiple_matching_bundles(self):
        for name in self.catalog:
            manifest = dict(self.manifest, components={name: self.manifest["components"][name]})
            self.package(self.sd / (name + ".zip"), manifest=manifest)
        self.import_packages()
        self.assert_imported()

    def test_crc_failure_does_not_leave_imported_or_temporary_components(self):
        path = self.package()
        raw = bytearray(path.read_bytes())
        payload = (self.raw / self.catalog["graphics"]["archive"]).read_bytes()
        raw[raw.index(payload)] ^= 1
        path.write_bytes(raw)
        with self.assertRaisesRegex(RuntimeError, "CRC"):
            self.import_packages(offline=path)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_valid_cached_and_expanded_components_avoid_scanning(self):
        self.cache.mkdir(parents=True)
        for item in self.items:
            (self.cache / item["archive"]).write_bytes((self.raw / item["archive"]).read_bytes())
        with mock.patch.object(packages, "package_candidates", side_effect=AssertionError("unneeded scan")):
            self.import_packages()
            self.import_packages(offline=self.raw)
        for item in self.items:
            (self.cache / item["archive"]).unlink()
        with mock.patch.object(packages, "package_candidates", side_effect=AssertionError("unneeded scan")):
            self.import_packages(offline=self.raw)

    def test_symlinked_bundle_and_real_7z_are_not_imported(self):
        target = self.package(self.root / "outside.zip")
        link = self.sd / "link.zip"
        link.symlink_to(target)
        self.import_packages()
        self.assertFalse(self.cache.exists())
        with self.assertRaisesRegex(RuntimeError, "符号链接"):
            self.import_packages(offline=link)
        path = self.sd / "not-zip.7z"
        path.write_bytes(b"7z\xbc\xaf\x27\x1c")
        with self.assertRaisesRegex(RuntimeError, "不是适用"):
            self.import_packages(offline=path)

    def test_builder_emits_a_standard_zip_accepted_by_the_importer(self):
        path = self.sd / "builder-output.zip"
        with mock.patch("builtins.print"):
            builder.offline_pack(self.raw, self.catalog_path, path, root=self.config)
        self.assertEqual(path.read_bytes()[:4], b"PK\x03\x04")
        with zipfile.ZipFile(path) as archive:
            self.assertEqual(json.loads(archive.read(packages.PACKAGE_MANIFEST)), self.manifest)
        self.import_packages()
        self.assert_imported()

    def test_starter_keeps_runtime_identity_and_can_supply_only_its_components(self):
        starter_spec = importlib.util.spec_from_file_location("wine_offline_starter", SOURCE / "scripts/dist-starter.py")
        starter = importlib.util.module_from_spec(starter_spec)
        starter_spec.loader.exec_module(starter)
        runtime = self.package(self.root / "runtime.zip")
        runner = self.root / "runner.zip"
        with zipfile.ZipFile(runner, "w") as archive:
            archive.writestr((WINDOWS_REL / "Je-Wine.sh").as_posix(), "exit 99")
        combined = self.sd / "starter.zip"
        with mock.patch("builtins.print"):
            starter.build([runner, runtime], combined)
        self.import_packages(offline=combined)
        self.assert_imported()
        self.assertFalse((self.library / "Je-Wine.sh").exists())

    def test_install_entry_imports_before_mount_and_preserves_existing_player_data(self):
        self.package()
        self.runtime.mkdir()
        (self.runtime / "player-save").write_text("keep")
        device = {"environment": "fixture", "machine": "aarch64", "library_directory": str(self.library),
                  "runtime_mount": str(self.runtime)}
        def mount(*args, **kwargs):
            self.assertEqual(digest(self.cache / self.catalog["core"]["archive"]), self.catalog["core"]["sha256"])
            return self.runtime
        with mock.patch.object(installer, "host_requirements", return_value=[]), \
             mock.patch.object(installer, "mounted_runtime", side_effect=mount) as mounted:
            installer.install(self.base, device, root=self.config, progress=self.messages.append)
        mounted.assert_called_once()
        self.assertTrue(installer.installed(self.runtime, [self.items[0]]))
        self.assertEqual((self.runtime / "player-save").read_text(), "keep")

    def test_invalid_bundle_fails_before_mount_or_runtime_replacement(self):
        self.package(manifest=dict(self.manifest, machine="x86_64"))
        self.runtime.mkdir()
        (self.runtime / "player-save").write_text("keep")
        device = {"environment": "fixture", "machine": "aarch64", "library_directory": str(self.library),
                  "runtime_mount": str(self.runtime)}
        with mock.patch.object(installer, "host_requirements", return_value=[]), \
             mock.patch.object(installer, "mounted_runtime") as mounted:
            with self.assertRaisesRegex(RuntimeError, "机型环境"):
                installer.install(self.base, device, root=self.config, progress=self.messages.append)
        mounted.assert_not_called()
        self.assertEqual((self.runtime / "player-save").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
