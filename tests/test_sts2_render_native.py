# INPUT:  Godot 4 executable and repository-native STS2 rendering scripts
# OUTPUT: Headless synthetic regression for policy, materials, cache and room cleanup
# POS:    Host-only native fixture; never loads or runs player game data
import os
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from sts2_test_inputs import external_file

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'ports/sts2/src/rendering'


class NativeRenderTest(unittest.TestCase):
    def test_native_scripts(self):
        godot = external_file(self, 'STS2_TEST_GODOT')
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / 'project.godot').write_text('[application]\nconfig/name="Native fixture"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
            compat = project / 'port_compat'
            compat.mkdir()
            for name in ('render_compat.gd', 'shader_compat.gd', 'combat_warmup.gd', 'simple_effect.gd', 'startup_effect_preload.gd'):
                shutil.copy(SCRIPTS / name, compat / name)
            shutil.copytree(ROOT / '_kit/godot/addons/portkit_performance', project / 'addons/portkit_performance')
            (compat / 'render-compat.json').write_text('{}')
            shaders = project / 'shaders/mobile_compat'
            shaders.mkdir(parents=True)
            for name in ('radial_blur_compat.gdshader', 'radial_blur_smooth.gdshader'):
                shutil.copy(ROOT / 'ports/sts2/src/shaders/mobile_compat' / name, shaders / name)
            (project / 'replacement.gdshader').write_text('shader_type canvas_item; uniform float amount = 1.0; void fragment() { COLOR *= amount; }')
            spec = importlib.util.spec_from_file_location('global_material_policy_native', ROOT / 'ports/sts2/src/scripts/global_material_policy.py')
            policy = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(policy)
            terms = [f'0.030303030 * texture(TEXTURE, UV {"+" if i >= 0 else "-"} {abs(i)}.0 * s).rgb' for i in range(-16, 17)]
            raw = ('shader_type canvas_item;\nuniform vec2 step;\nuniform bool mask;\nvoid fragment() { vec2 s=step; COLOR.rgb = ' + ' +\n'.join(terms) + '; COLOR.a = 0.7; }\n').encode()
            lowered, changes = policy.transform_resource('Blur.gdshader', raw)
            self.assertEqual((changes[0]['before'], changes[0]['after']), (33, 7))
            (project / 'simplified_blur.gdshader').write_bytes(lowered)
            vfx = project / 'scenes/vfx'
            vfx.mkdir(parents=True)
            for name in ('vfx_attack_slash', 'vfx_attack_blunt'):
                (vfx / f'{name}.tscn').write_text('[gd_scene format=3]\n\n[node name="Effect" type="Node2D"]\n')
            (project / 'asset.tres').write_text('[gd_resource type="Resource" format=3]\n\n[resource]\n')
            shutil.copy(ROOT / 'tests/sts2_render_native_fixture.gd', project / 'driver.gd')
            env = os.environ.copy()
            env['PORTKIT_PERF_OVERLAY'] = '1'
            env['SLL_QUALITY'] = 'smooth'
            env['SLL_SHADER_COMPAT'] = 'off'
            run = subprocess.run([str(godot), '--headless', '--path', str(project), '--script', 'res://driver.gd', '--quit-after', '240'], env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('STS2_NATIVE_OK', run.stdout, run.stdout + run.stderr)
            self.assertNotIn('SCRIPT ERROR', run.stdout + run.stderr)

if __name__ == '__main__':
    unittest.main()
