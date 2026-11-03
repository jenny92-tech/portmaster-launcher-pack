#!/usr/bin/env python3
# INPUT:  合成 Godot PCK 与只读 VFX 扫描工具
# OUTPUT: 递归依赖、粒子属性、输出保护和可重复性回归
# POS:    不依赖玩家游戏、设备或 Godot 运行时
import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'ports/sts2/src/tools/godot_pck'
SCANNER = TOOLS / 'scan_vfx_catalog.py'
spec = importlib.util.spec_from_file_location('low_texture_overlay', TOOLS / 'low_texture_overlay.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)

PARENT = '''[gd_scene load_steps=3 format=3 uid="uid://parent"]

[ext_resource type="Script" path="res://src/UnknownEffect.cs" id="1_script"]
[ext_resource type="PackedScene" path="res://scenes/vfx/common/child.tscn" id="2_child"]

[node name="Root" type="Node2D" node_paths=PackedStringArray("_particles")]
script = ExtResource("1_script")
_lifetime = 3.0
_particles = [NodePath("Spark")]

[node name="Spark" parent="." instance=ExtResource("2_child")]
amount = 3
fixed_fps = 30
'''
CHILD = '''[gd_scene load_steps=4 format=3 uid="uid://child"]

[ext_resource type="PackedScene" path="res://scenes/vfx/parent.tscn" id="1_cycle"]
[ext_resource type="Material" path="res://materials/vfx/glow.tres" id="2_material"]

[sub_resource type="ParticleProcessMaterial" id="ParticleProcessMaterial_1"]
turbulence_enabled = true
turbulence_noise_strength = 5.0

[node name="SharedSpark" type="GPUParticles2D"]
material = ExtResource("2_material")
amount = 10
preprocess = 1.5
fixed_fps = 60
process_material = SubResource("ParticleProcessMaterial_1")
'''
INHERITED = '''[gd_scene load_steps=2 format=3 uid="uid://derived"]

[ext_resource type="PackedScene" path="res://scenes/vfx/common/child.tscn" id="1_base"]
[ext_resource type="PackedScene" path="res://scenes/vfx/missing.tscn" id="2_missing"]

[node name="Derived" instance=ExtResource("1_base")]
amount = 4
'''
MATERIAL = '''[gd_resource type="ShaderMaterial" load_steps=3 format=3]

[ext_resource type="Shader" path="res://shaders/glow.gdshader" id="1_shader"]
[ext_resource type="Material" path="res://materials/vfx/glow.tres" id="2_self"]

[resource]
shader = ExtResource("1_shader")
'''
SHADER = '''shader_type canvas_item;
#include "res://shaders/hash.gdshaderinc"
uniform sampler2D screen_texture : hint_screen_texture;
void fragment() { COLOR = texture(screen_texture, SCREEN_UV); }
'''
FIXTURES = {
    'scenes/vfx/parent.tscn': PARENT,
    'scenes/vfx/common/child.tscn': CHILD,
    'scenes/vfx/derived.tscn': INHERITED,
    'materials/vfx/glow.tres': MATERIAL,
    'shaders/glow.gdshader': SHADER,
    'shaders/hash.gdshaderinc': 'float hash12(vec2 p) { return 0.0; }\n',
}


def create_pack(root, name='source.pck'):
    source = root / 'input-files'
    source.mkdir(exist_ok=True)
    items = []
    for index, (name_in_pack, content) in enumerate(FIXTURES.items()):
        path = source / str(index)
        path.write_text(content, encoding='utf-8')
        items.append((name_in_pack, path))
    pck = root / name
    pack.write_pack(items, pck)
    return pck


def run_scan(pck, out):
    return subprocess.run(['python3', str(SCANNER), '--base', str(pck), '--output-dir', str(out)],
                          capture_output=True, text=True)


class VfxCatalogTest(unittest.TestCase):
    def test_recursive_resources_instance_overrides_and_repeatability(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = create_pack(root)
            before = source.read_bytes()
            first, second = root / 'first', root / 'second'
            result = run_scan(source, first)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = run_scan(source, second)
            self.assertEqual(result.returncode, 0, result.stderr)
            catalog_file = first / 'vfx-catalog.json'
            self.assertEqual(catalog_file.read_bytes(), (second / catalog_file.name).read_bytes())
            self.assertEqual((first / 'vfx-catalog-report.md').read_bytes(),
                             (second / 'vfx-catalog-report.md').read_bytes())
            self.assertEqual(source.read_bytes(), before)
            data = json.loads(catalog_file.read_text())
            self.assertEqual(data['source_pck_sha256'], hashlib.sha256(before).hexdigest())
            scenes = {s['path']: s for s in data['scenes']}
            self.assertEqual(set(scenes), {'res://scenes/vfx/parent.tscn',
                                           'res://scenes/vfx/common/child.tscn',
                                           'res://scenes/vfx/derived.tscn'})
            parent = scenes['res://scenes/vfx/parent.tscn']
            self.assertEqual(parent['sha256'], hashlib.sha256(PARENT.encode()).hexdigest())
            self.assertEqual(parent['scene_header']['uid'], 'uid://parent')
            self.assertEqual(parent['root_type'], 'Node2D')
            self.assertEqual(parent['root_script'], 'res://src/UnknownEffect.cs')
            self.assertEqual(parent['root']['properties']['_lifetime'], '3.0')
            self.assertEqual(parent['root']['properties']['_particles'], '[NodePath("Spark")]')
            self.assertEqual(parent['candidate_class'], 'typed_cs_callback_contract_audit')
            self.assertEqual(parent['dependency_closure'], sorted([
                'res://scenes/vfx/common/child.tscn',
                'res://materials/vfx/glow.tres',
                'res://shaders/glow.gdshader',
                'res://shaders/hash.gdshaderinc',
            ]))
            overrides = [i for i in parent['dependency_instances_and_overrides']
                         if i['scene'] == parent['path'] and i['node'] == 'Spark']
            self.assertEqual(len(overrides), 1)
            self.assertEqual(overrides[0]['instance'], 'res://scenes/vfx/common/child.tscn')
            self.assertEqual(overrides[0]['properties']['amount'], '3')
            self.assertEqual(overrides[0]['properties']['fixed_fps'], '30')
            particles = [i for i in parent['particle_nodes_unique_source'] if i['node'] == 'SharedSpark']
            self.assertEqual(len(particles), 1)
            self.assertEqual(particles[0]['type'], 'GPUParticles2D')
            self.assertEqual(particles[0]['properties']['amount'], '10')
            self.assertEqual(particles[0]['properties']['preprocess'], '1.5')
            self.assertTrue(any(m['properties'].get('turbulence_enabled') == 'true'
                                for m in parent['particle_process_material_turbulence_unique_source']))
            self.assertTrue(any(s['path'] == 'res://shaders/glow.gdshader' and 'screen_sampling' in s['flags']
                                for s in parent['heavy_shader_flags_unique_source']))
            self.assertTrue(any(s['path'] == 'res://shaders/hash.gdshaderinc' and 'hash' in s['flags']
                                for s in parent['heavy_shader_flags_unique_source']))
            self.assertEqual(parent['unresolved_text_dependencies'], [])
            derived = scenes['res://scenes/vfx/derived.tscn']
            self.assertEqual(derived['root_instance'], 'res://scenes/vfx/common/child.tscn')
            self.assertEqual(derived['root']['properties']['amount'], '4')
            self.assertEqual(derived['unresolved_text_dependencies'], ['res://scenes/vfx/missing.tscn'])

    def test_output_cannot_overwrite_input_or_existing_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = create_pack(root, 'vfx-catalog.json')
            before = source.read_bytes()
            result = run_scan(source, root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(source.read_bytes(), before)
            self.assertFalse((root / 'vfx-catalog-report.md').exists())
            # Existing output linked to the source must not bypass identity checks.
            for kind in ('symlink', 'hardlink'):
                out = root / kind
                out.mkdir()
                target = out / 'vfx-catalog.json'
                if kind == 'symlink':
                    target.symlink_to(source)
                else:
                    os.link(source, target)
                result = run_scan(source, out)
                self.assertNotEqual(result.returncode, 0, kind)
                self.assertEqual(source.read_bytes(), before)
                self.assertFalse((out / 'vfx-catalog-report.md').exists())
            out = root / 'occupied'
            out.mkdir()
            target = out / 'vfx-catalog.json'
            sentinel = b'existing user data\n'
            target.write_bytes(sentinel)
            result = run_scan(source, out)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_bytes(), sentinel)
            self.assertEqual(source.read_bytes(), before)
            self.assertFalse((out / 'vfx-catalog-report.md').exists())

    def test_unknown_pack_format_fails_without_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = create_pack(root)
            corrupt = bytearray(source.read_bytes())
            corrupt[4:8] = (999).to_bytes(4, 'little')
            source.write_bytes(corrupt)
            out = root / 'out'
            result = run_scan(source, out)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(source.read_bytes(), corrupt)
            self.assertFalse((out / 'vfx-catalog.json').exists())
            self.assertFalse((out / 'vfx-catalog-report.md').exists())


if __name__ == '__main__':
    unittest.main()
