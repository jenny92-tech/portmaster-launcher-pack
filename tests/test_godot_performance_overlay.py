# INPUT:  Godot 4 executable and shared performance addon
# OUTPUT: Headless regression for overlay lifecycle, input, layout and metrics
# POS:    Isolated host-only fixture; does not load game data or access a device
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from sts2_test_inputs import external_file

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / '_kit/godot/addons/portkit_performance'


class PerformanceOverlayTest(unittest.TestCase):
    def test_headless_overlay(self):
        godot = external_file(self, 'STS2_TEST_GODOT')
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / 'project.godot').write_text('[application]\nconfig/name="Performance fixture"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
            shutil.copytree(ADDON, project / 'addons/portkit_performance')
            shutil.copy(ROOT / 'tests/godot_performance_overlay_fixture.gd', project / 'driver.gd')
            for enabled in (False, True):
                env = os.environ.copy()
                if enabled:
                    env['PORTKIT_PERF_OVERLAY'] = '1'
                else:
                    env.pop('PORTKIT_PERF_OVERLAY', None)
                with self.subTest(environment_enabled=enabled):
                    run = subprocess.run([str(godot), '--headless', '--path', str(project), '--script', 'res://driver.gd', '--quit-after', '5000'], env=env, capture_output=True, text=True, timeout=20)
                    output = run.stdout + run.stderr
                    self.assertEqual(run.returncode, 0, output)
                    self.assertIn('PERFORMANCE_OVERLAY_OK', output)
                    self.assertNotIn('SCRIPT ERROR', output)


if __name__ == '__main__':
    unittest.main()
