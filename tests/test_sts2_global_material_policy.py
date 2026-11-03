# INPUT:  type/feature-based material and shader policy, synthetic Godot resources
# OUTPUT: narrow transformations, invariants, unknown-input refusal and native parse checks
# POS:    local fixtures without device or player game execution
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from sts2_test_inputs import external_file

ROOT = Path(__file__).resolve().parents[1]
FILE = ROOT/'ports/sts2/src/scripts/global_material_policy.py'
spec=importlib.util.spec_from_file_location('global_policy_test',FILE); policy=importlib.util.module_from_spec(spec); spec.loader.exec_module(policy)
NOISE = b'''shader_type canvas_item;\nfloat fbm(vec2 p) {\n float value = 0.0; float amplitude = 0.5;\n for (int i = 0; i < 4; i++) { value += amplitude * value_noise(p); p *= 2.1; amplitude *= 0.5; }\n return value;\n}\nfloat value_noise(vec2 p) { return p.x; }\nvoid fragment() { COLOR.rgb = vec3(fbm(UV)); }\n'''


def gaussian(screen=False):
    sampler = b'sample(SCREEN_UV ' if screen else b'texture(TEXTURE, UV '
    terms=[]
    for i in range(-16,17):
        sign=b'+' if i>=0 else b'-'
        terms.append(b'0.030303030 * '+sampler+sign+b' '+str(abs(i)).encode()+b'.0 * s).rgb')
    prefix = b'shader_type canvas_item;\nuniform vec2 step;\n' + (b'vec4 sample(vec2 uv) { return texture(TEXTURE,uv); }\n' if screen else b'')
    return prefix+b'void fragment() { vec2 s=step; COLOR.rgb = '+b' +\n'.join(terms)+b';\n COLOR.a = 0.7; }\n'


class GlobalPolicyTests(unittest.TestCase):
    def test_materials_shared_nested_and_unrelated_are_preserved(self):
        base=b'''[gd_resource type="ParticleProcessMaterial" format=3]\n[sub_resource type="ParticleProcessMaterial" id="nested"]\nturbulence_enabled = true  \n[node name="other" type="Node"]\nturbulence_enabled = true\n[resource]\nturbulence_enabled = true\n'''
        out,changes=policy.transform_resource('shared.tres',base)
        self.assertEqual(len(changes),2)
        self.assertEqual(out.replace(b'turbulence_enabled = false',b'turbulence_enabled = true'),base)
        self.assertIn(b'[node name="other" type="Node"]\nturbulence_enabled = true',out)
        self.assertEqual(policy.transform_resource('shared.tres',out),(out,[]))
    def test_duplicate_and_unknown_values_refused(self):
        for fields in (b'turbulence_enabled = true\nturbulence_enabled = false\n',b'turbulence_enabled = expression()\n'):
            with self.assertRaises(ValueError): policy.transform_resource('any.tscn',b'[gd_scene format=3]\n[sub_resource type="ParticleProcessMaterial" id="a"]\n'+fields)
    def test_multiline_shader_does_not_create_fake_materials(self):
        code=b'''[gd_scene format=3]\n[sub_resource type="Shader" id="s"]\ncode = "shader_type canvas_item;\n[sub_resource type=\\"ParticleProcessMaterial\\" id=\\"fake\\"]\nturbulence_enabled = true\n"\n[node name="n" type="Node"]\n'''
        out,changes=policy.transform_resource('x.tscn',code)
        self.assertEqual(out,code); self.assertEqual(changes,[])
    def test_multiline_string_inside_material_is_not_a_property(self):
        raw = b'[gd_resource type="ParticleProcessMaterial" format=3]\n[resource]\nnote = "example\nturbulence_enabled = true\nend"\nturbulence_enabled = true\n'
        out, changes = policy.transform_resource('m.tres', raw)
        self.assertEqual(len(changes),1)
        self.assertIn(b'note = "example\nturbulence_enabled = true\nend"',out)
        self.assertTrue(out.endswith(b'turbulence_enabled = false\n'))
    def test_embedded_noise_rule_independent_of_path(self):
        embedded=b'[gd_resource type="Shader" format=3]\n[resource]\ncode = "'+NOISE+b'"\n'
        out,changes=policy.transform_resource('other/path.tres',embedded)
        self.assertEqual(len(changes),1); self.assertEqual(changes[0]['rule'],'canvas_fractal_noise_octaves')
        self.assertEqual(out.replace(b'i < 2',b'i < 4'),embedded)
        self.assertEqual(policy.transform_resource('other/path.tres',out),(out,[]))
    def test_comments_and_non_canvas_shader_never_changed(self):
        original=b'shader_type particles;\n/* '+NOISE+b' */\nvoid process() {}\n'
        out,changes=policy.transform_resource('x.gdshader',original); self.assertEqual(out,original);self.assertEqual(changes,[])
    def test_blur_reduces_only_recognized_sum_and_keeps_alpha(self):
        for screen in (False,True):
            data=gaussian(screen); out,changes=policy.transform_resource('x.gdshader',data)
            self.assertEqual(changes[0]['before'],33); self.assertEqual(changes[0]['after'],7)
            self.assertIn(b'COLOR.a = 0.7;',out); self.assertEqual(policy.transform_resource('x.gdshader',out),(out,[]))
        unsupported=gaussian().replace(b'0.030303030',b'-0.030303030',1)
        self.assertEqual(policy.transform_resource('x.gdshader',unsupported),(unsupported,[]))
    def test_screen_warp_keeps_interface_and_single_screen_sample(self):
        raw=b'''shader_type canvas_item;\nuniform sampler2D screen : hint_screen_texture;\nuniform sampler2D noise_tex;\nuniform float strength;\nvoid fragment() {\n vec2 uv = SCREEN_UV;\n vec4 sample_color = texture(screen, uv);\n vec2 motion = UV * TIME;\n float noise_val = texture(noise_tex, uv + motion).r - 0.5;\n uv += noise_val * SCREEN_PIXEL_SIZE * strength;\n COLOR = texture(screen, uv);\n}\n'''
        out,changes=policy.transform_resource('x.gdshader',raw)
        self.assertEqual(changes[0]['rule'],'canvas_noise_screen_warp_disabled')
        self.assertIn(b'uniform sampler2D noise_tex;',out); self.assertIn(b'COLOR = texture(screen, SCREEN_UV);',out)
        self.assertNotIn(b'texture(noise_tex',out); self.assertEqual(policy.transform_resource('x.gdshader',out),(out,[]))
    def test_godot_loads_generated_shader_resources(self):
        GODOT=external_file(self,'STS2_TEST_GODOT')
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);(path/'project.godot').write_text('[application]\nconfig/name="material fixture"\n')
            for n,source in [('noise',NOISE),('blur',gaussian()),('mask',gaussian(True))]:
                (path/(n+'.gdshader')).write_bytes(policy.transform_resource(n+'.gdshader',source)[0])
            (path/'test.gd').write_text('''extends SceneTree\nfunc _initialize():\n for p in ["noise", "blur", "mask"]:\n  var s = load("res://" + p + ".gdshader")\n  if not s is Shader or s.code.is_empty():\n   quit(1)\n   return\n print("shader resources OK")\n quit(0)\n''')
            run=subprocess.run([str(GODOT),'--headless','--path',str(path),'--script',str(path/'test.gd')],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr); self.assertIn('shader resources OK',run.stdout)
            self.assertNotIn('SHADER ERROR',run.stderr)

if __name__ == '__main__': unittest.main()
