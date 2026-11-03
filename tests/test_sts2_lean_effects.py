# INPUT:  overlay builder and a synthetic Godot fixture
# OUTPUT: generated-scene identity checks and headless lifecycle validation
# POS:    tests lightweight effects without loading player game data
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'ports/sts2/src/rendering'
SPEC = importlib.util.spec_from_file_location('overlay', ROOT / 'ports/sts2/src/scripts/make-official-runtime-overlay.py')
OVERLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OVERLAY)
GODOT = ROOT / '.cache/sts2-vulkan-trial/build-tools/godot-4.5.1-macos/Godot.app/Contents/MacOS/Godot'


class LeanEffectsTest(unittest.TestCase):
    def test_generated_scenes_are_identity_checked_and_dependency_free(self):
        self.assertTrue({
            'scenes/vfx/hit_spark_vfx.tscn', 'scenes/vfx/ui/vfx_debuff_applied.tscn',
            'scenes/vfx/ui/vfx_buff_applied.tscn', 'scenes/vfx/vfx_cross_heal.tscn'} <= set(OVERLAY.SMOOTH_PARTICLE_SCENES))
        for path, original in OVERLAY.SMOOTH_PARTICLE_SCENES.items():
            source = b'synthetic audited scene'
            spec = {**original, 'sha256': hashlib.sha256(source).hexdigest()}
            scene, report = OVERLAY.rewrite_smooth_particle_scene(source, path, spec)
            text = scene.decode()
            self.assertIn(original['script'], text)
            self.assertIn(f'[node name="{original["root"]}" type="Node2D"]', text)
            if not original.get('child_frees_root', original.get('root_lifetime') is None):
                self.assertIn('free_root_on_finish = false', text)
            if original.get('root_lifetime') is not None:
                self.assertIn('_lifetime = ' + str(original['root_lifetime']), text)
            self.assertIn('name="PortSimpleEffect" type="Polygon2D"', text)
            self.assertNotIn('Particles', text)
            self.assertNotIn('Texture', text)
            self.assertNotIn('Material', text)
            self.assertEqual(report['source_sha256'], spec['sha256'])
            self.assertEqual(report['output_sha256'], hashlib.sha256(scene).hexdigest())
            self.assertTrue(report['generated_simple_effect'])
            with self.assertRaisesRegex(ValueError, 'Unrecognized'):
                OVERLAY.rewrite_smooth_particle_scene(source + b'!', path, spec)

    def test_simple_flashes_and_timed_healing_root(self):
        godot = Path(os.environ.get('STS2_TEST_GODOT', str(GODOT)))
        if not godot.is_file():
            self.skipTest('Set STS2_TEST_GODOT to a Godot 4 executable')
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / 'project.godot').write_text('[application]\nconfig/name="Lean effects fixture"\n')
            (project / 'port_compat').mkdir()
            shutil.copy(SCRIPTS / 'simple_effect.gd', project / 'port_compat')
            shutil.copy(ROOT / 'tests/sts2_lean_effects_fixture.gd', project / 'driver.gd')
            run = subprocess.run([str(godot), '--headless', '--path', str(project), '--script', 'res://driver.gd'], capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('STS2_LEAN_EFFECT_OK', run.stdout)
            self.assertNotIn('SCRIPT ERROR', run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
