#!/usr/bin/env python3
# INPUT:  合成 Godot PCK 与只读着色器特征扫描器
# OUTPUT: 材质类型、着色器语法与静态依赖闭包回归
# POS:    不使用玩家内容或设备验证全包扫描边界
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'ports/sts2/src/tools/godot_pck'
spec = importlib.util.spec_from_file_location('pack', TOOLS / 'low_texture_overlay.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


class ShaderFeaturesTest(unittest.TestCase):
    def test_shared_material_inline_shader_remap_and_closure(self):
        fixtures = {
            'main.tscn': '''[gd_scene format=3]

[ext_resource type="Material" path="res://shared.tres" id="1"]
[ext_resource type="Script" path="res://logic.gd" id="2"]

[node name="Spark" type="GPUParticles2D"]
process_material = ExtResource("1")
''',
            'shared.tres': '''[gd_resource type="ParticleProcessMaterial" format=3]

[resource]
turbulence_enabled = true
''',
            'second.tscn': '''[gd_scene format=3]

[ext_resource type="Material" path="res://shared.tres" id="1"]

[sub_resource type="Shader" id="shader"]
code = "shader_type particles;
[inside_multiline_code]
void process() { float turbulence = 1.0; }
"

[node name="Spark" type="GPUParticles2D"]
process_material = ExtResource("1")
''',
            'logic.gd.remap': '[remap]\npath="res://logic.gdc"\n',
            'logic.gdc': 'GDSC opaque',
            'shader.gdshader': '''shader_type canvas_item;
uniform sampler2D screen : hint_screen_texture;
void fragment() { for (int i=0;i<2;i++) COLOR += texture(screen, SCREEN_UV); }
''',
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            items = []
            for i, (name, content) in enumerate(fixtures.items()):
                path = root / str(i)
                path.write_text(content)
                items.append((name, path))
            source = root / 'input.pck'
            pack.write_pack(items, source)
            original = source.read_bytes()
            output = root / 'report'
            command = ['python3', str(TOOLS / 'scan_shader_features.py'), '--base', str(source), '--output-dir', str(output)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads((output / 'shader-features.json').read_text())
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(data['features']['turbulence_enabled']['records'], 1)
            self.assertEqual(data['features']['shader_type_particles']['records'], 1)
            self.assertEqual(data['features']['shader_turbulence']['records'], 1)
            self.assertEqual(data['features']['screen_sampling_loop']['records'], 1)
            self.assertEqual(data['potential_scene_closures']['res://shared.tres'], ['res://main.tscn', 'res://second.tscn'])
            self.assertEqual(data['dependencies']['res://logic.gd'], ['res://logic.gdc'])
            self.assertEqual(data['inventory']['missing_static_references'], [])
            self.assertEqual(len(data['inventory']['binary_unparsed']), 1)
            node = next(r for r in data['records'] if r['path'] == 'res://main.tscn')
            self.assertEqual(node['references'][0]['target'], 'res://shared.tres')
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
