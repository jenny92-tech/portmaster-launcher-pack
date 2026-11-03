# INPUT:  Godot 4 executable, startup preloader and synthetic scenes
# OUTPUT: completion, failure, timeout, duplicate and cleanup regression
# POS:    isolated headless fixture; no game resources are instantiated
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GODOT = ROOT / '.cache/sts2-vulkan-trial/build-tools/godot-4.5.1-macos/Godot.app/Contents/MacOS/Godot'


class StartupPreloadTest(unittest.TestCase):
    def test_startup_preloader(self):
        godot = Path(os.environ.get('STS2_TEST_GODOT', str(DEFAULT_GODOT)))
        if not godot.is_file():
            self.skipTest('Set STS2_TEST_GODOT to a Godot 4 executable')
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / 'project.godot').write_text('[application]\nconfig/name="Startup preloader fixture"\n')
            (project / 'port_compat').mkdir()
            shutil.copy(ROOT / 'ports/sts2/src/rendering/startup_effect_preload.gd', project / 'port_compat')
            shutil.copy(ROOT / 'tests/sts2_startup_preload_fixture.gd', project / 'driver.gd')
            scenes = project / 'scenes/vfx'
            scenes.mkdir(parents=True)
            (project / 'root_script.gd').write_text('extends Node\nfunc _ready():\n    push_error("ROOT SCRIPT RAN")\n')
            for name in ('test', 'test2'):
                (scenes / (name + '.tscn')).write_text('[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://root_script.gd" id="1"]\n\n[node name="Root" type="Node"]\nscript = ExtResource("1")\n')
            for mode in ('success', 'duplicate', 'missing', 'timeout', 'cleanup'):
                with self.subTest(mode=mode):
                    env = {**os.environ, 'PRELOAD_TEST_MODE': mode}
                    run = subprocess.run([str(godot), '--headless', '--path', str(project), '--script', 'res://driver.gd'], env=env, capture_output=True, text=True, timeout=15)
                    output = run.stdout + run.stderr
                    self.assertEqual(run.returncode, 0, output)
                    self.assertIn('STARTUP_PRELOAD_OK', output)
                    self.assertNotIn('ROOT SCRIPT RAN', output)
                    self.assertNotIn('SCRIPT ERROR', output)


if __name__ == '__main__':
    unittest.main()
