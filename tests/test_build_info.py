#!/usr/bin/env python3
# INPUT:  build_info.py、端口模板与隔离临时发行目录
# OUTPUT: 构建身份稳定性、日志与封装回归结果
# POS:    验证跨端口内部构建标识不依赖真机或外部游戏资源
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_info", ROOT / "_kit/build_info.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildInfoTests(unittest.TestCase):
    def fixture(self, root, portable=True):
        manifest = root / "manifest.json"
        manifest.write_text(json.dumps({"name": "test ' $()", "script": "Game.sh",
                                       "portable_dir": "game" if portable else ""}))
        dist = root / "dist"
        dist.mkdir()
        data = dist / "game" if portable else dist
        data.mkdir(exist_ok=True)
        (data / "runtime").write_bytes(b"binary")
        launcher = dist / "Game.sh"
        launcher.write_text("#!/bin/sh\n    #@BUILD-LOG\n")
        launcher.chmod(0o755)
        return manifest, dist, data

    def test_stable_and_content_sensitive(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, dist, data = self.fixture(Path(directory))
            first = module.stamp(manifest, dist, "2026.09.23")
            self.assertEqual(first, module.stamp(manifest, dist, "2026.09.23"))
            self.assertEqual(first["payload_revision"], module.stamp(manifest, dist, "2026.09.24")["payload_revision"])
            self.assertNotEqual(first["build_version"], module.stamp(manifest, dist, "2026.09.24")["build_version"])
            output = subprocess.check_output(["sh", str(dist / "Game.sh")], text=True)
            self.assertIn("[BUILD] package=test ' $() build.version=2026.09.24-", output)
            (data / "runtime").write_bytes(b"changed")
            self.assertNotEqual(first["payload_revision"], module.stamp(manifest, dist)["payload_revision"])

    def test_flat_layout_and_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, dist, data = self.fixture(Path(directory), False)
            info = module.stamp(manifest, dist)
            for kind in ("portmaster", "trimui-app"):
                encoded = module.packaging_info((data / "build-info.json").read_bytes(), kind)
                decoded = json.loads(encoded)
                self.assertEqual(decoded["build_version"], info["build_version"])
                self.assertEqual(decoded["packaging"], kind)

    def test_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, dist, data = self.fixture(Path(directory))
            (data / "link").symlink_to(data / "runtime")
            with self.assertRaisesRegex(ValueError, "symlinks"):
                module.stamp(manifest, dist)
        with tempfile.TemporaryDirectory() as directory:
            manifest, dist, data = self.fixture(Path(directory))
            (dist / "Game.sh").write_text("#!/bin/sh\nexit 0\n")
            with self.assertRaisesRegex(ValueError, "exactly one"):
                module.stamp(manifest, dist)

    def test_real_zip_packagers_share_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, dist, data = self.fixture(root)
            config = json.loads(manifest.read_text())
            config.update(name="game", portmaster={"items": ["Game.sh", "game"]},
                          trimui_app={"include": ["Game.sh", "game"], "icon": "icon.png"})
            manifest.write_text(json.dumps(config))
            (root / "icon.png").write_bytes(b"image fixture")
            (dist / "port.json").write_text(json.dumps({"name": "game.zip", "items": ["Game.sh", "game"]}))
            info = module.stamp(manifest, dist)
            output = root / "output"
            for tool, args in (("port_zip.py", [manifest, dist, output]),
                               ("trimui_app.py", [manifest, dist, root, output])):
                subprocess.run(["python3", str(ROOT / "_kit" / tool), *map(str, args)],
                               check=True, capture_output=True)
            self.assertEqual(len(list(output.glob("*.zip"))), 2)
            for archive in output.glob("*.zip"):
                with zipfile.ZipFile(archive) as z:
                    self.assertIsNone(z.testzip())
                    name = next(n for n in z.namelist() if n.endswith("/build-info.json"))
                    metadata = json.loads(z.read(name))
                    self.assertEqual(metadata["build_version"], info["build_version"])
                    self.assertEqual(metadata["packaging"], "portmaster" if archive.name == "game.zip" else "trimui-app")
            self.assertNotIn("packaging", json.loads((data / "build-info.json").read_text()))

    def test_all_port_launchers_assemble_and_stamp(self):
        for manifest in sorted((ROOT / "ports").glob("*/manifest.json")):
            with self.subTest(port=manifest.parent.name), tempfile.TemporaryDirectory() as directory:
                config = json.loads(manifest.read_text())
                source = manifest.parent / "love/launcher.sh.template"
                if not source.exists():
                    source = manifest.parent / "src/launcher.sh"
                dist = Path(directory)
                script = config.get("script", manifest.parent.name + ".sh")
                (dist / (config.get("portable_dir") or "")).mkdir(exist_ok=True)
                subprocess.run(["bash", str(ROOT / "_kit/assemble.sh"), str(source), str(dist / script)],
                               check=True, capture_output=True)
                first = module.stamp(manifest, dist)
                self.assertEqual(first, module.stamp(manifest, dist))
                subprocess.run(["bash", "-n", str(dist / script)], check=True)
                self.assertIn("build.version=", (dist / script).read_text())


if __name__ == "__main__":
    unittest.main()
