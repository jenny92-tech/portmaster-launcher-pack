# INPUT:  Synthetic native map scene, PCK helpers and map canvas trial builder
# OUTPUT: Identity-rejection, coordinate-property and unrelated-resource regression checks
# POS:    Offline tests using temporary fixtures, without a game or device
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1] / "ports/sts2/src/tools/godot_pck"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("map_canvas_trial", TOOLS / "map_canvas_trial.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

SCENE = b'[gd_scene format=3]\n[node name="Map" type="Control"]\n[node name="DrawViewport" type="SubViewport" parent="."]\nsize = Vector2i(960, 1620)\ntransparent_bg = true\n'


class MapCanvasTrialTest(unittest.TestCase):
    def test_only_raster_resolution_changes(self):
        with patch.object(m, "SCENE", hashlib.sha256(SCENE).hexdigest()):
            result = m.patch_scene(SCENE)
        self.assertIn(b"size = Vector2i(480, 810)", result)
        self.assertIn(b"size_2d_override = Vector2i(960, 1620)", result)
        self.assertIn(b"size_2d_override_stretch = true", result)
        self.assertEqual(result.replace(m.REPLACEMENT, m.ANCHOR), SCENE)

    def test_unknown_or_already_patched_input_rejected(self):
        with self.assertRaises(ValueError):
            m.patch_scene(SCENE)
        with patch.object(m, "SCENE", hashlib.sha256(SCENE).hexdigest()):
            with self.assertRaises(ValueError):
                m.patch_scene(SCENE.replace(m.ANCHOR, m.REPLACEMENT))

    def test_merge_keeps_other_resources_and_input(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            scene, other = root / "scene.tscn", root / "other.bin"
            scene.write_bytes(SCENE)
            other.write_bytes(b"unrelated original resource")
            parent = root / "parent.pck"
            m.low.write_pack([(m.TARGET, scene), ("other.bin", other)], parent)
            before = parent.read_bytes()
            parent_sha = hashlib.sha256(before).hexdigest()
            with patch.object(m, "PARENT", parent_sha), patch.object(m, "SCENE", hashlib.sha256(SCENE).hexdigest()):
                m.build(parent, root / "result")
            report = json.loads((root / "result/report.json").read_text())
            main = root / "result/packs" / (report["merged_sha256"] + ".pck")
            entries = m.low.read_pack(main)
            self.assertEqual(set(entries), {m.TARGET, "other.bin"})
            with main.open("rb") as stream:
                self.assertEqual(m.low.entry_bytes(stream, entries["other.bin"]), other.read_bytes())
                self.assertIn(m.REPLACEMENT, m.low.entry_bytes(stream, entries[m.TARGET]))
            self.assertEqual(parent.read_bytes(), before)
            self.assertEqual(json.loads(main.with_suffix(".json").read_text())["source_sha256"], parent_sha)
            with patch.object(m, "PARENT", parent_sha):
                with self.assertRaises(ValueError):
                    m.build(parent, root / "result")


if __name__ == "__main__":
    unittest.main()
