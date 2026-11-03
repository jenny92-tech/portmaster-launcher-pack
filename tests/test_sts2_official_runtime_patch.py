# INPUT:  官方运行时资源补丁构建器、合成场景与标准库 unittest
# OUTPUT: 粒子修改边界、PCK 资源身份及未知输入拒绝的无设备回归
# POS:    防止菜单减负破坏场景且原始 Shader 路径遭覆盖
import importlib.util
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("official_overlay",
    ROOT / "ports/sts2/src/scripts/make-official-runtime-overlay.py")
OVERLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OVERLAY)


def read_pack(blob):
    file_base, dir_base = struct.unpack_from("<QQ", blob, 24)
    count, = struct.unpack_from("<I", blob, dir_base)
    cursor, resources = dir_base + 4, {}
    for _ in range(count):
        length, = struct.unpack_from("<I", blob, cursor)
        cursor += 4
        path = blob[cursor:cursor + length].rstrip(b"\0").decode()
        cursor += length
        offset, size = struct.unpack_from("<QQ", blob, cursor)
        digest = blob[cursor + 16:cursor + 32]
        cursor += 36
        content = blob[file_base + offset:file_base + offset + size]
        if hashlib.md5(content).digest() != digest:
            raise AssertionError("PCK digest mismatch for " + path)
        resources[path] = content
    if len(resources) != count:
        raise AssertionError("Duplicate PCK path")
    return resources


class MenuResourcePatchTests(unittest.TestCase):
    def test_caps_gpu_warmup_without_changing_cpu_effects_or_scene_identity(self):
        scene = '''[gd_scene format=3 uid="uid://original"]
[ext_resource type="Script" path="res://src/Core/Nodes/Screens/MainMenu/NMainMenuBg.cs" id="script"]
[node name="MainMenuBg" type="Control"]
script = ExtResource("script")
[node name="Clouds" type="GPUParticles2D" parent="."]
amount = 40
preprocess = 400.0
lifetime = 400.0
[node name="LogoGlow" type="CPUParticles2D" parent="."]
amount = 1
preprocess = 5.0
[node name="Stars" type="GPUParticles2D" parent="."]
amount = 8
preprocess = 0.1
'''
        patched, changes = OVERLAY.rewrite_menu_scene(scene)
        self.assertIn('uid="uid://original"', patched)
        self.assertIn('lifetime = 400.0', patched)
        self.assertIn('amount = 32\npreprocess = 0.5', patched)
        self.assertIn('amount = 1\npreprocess = 5.0', patched)
        self.assertIn('amount = 8\npreprocess = 0.1', patched)
        self.assertEqual([line for line in patched.splitlines() if line.startswith('[node ')],
            [line for line in scene.splitlines() if line.startswith('[node ')])
        self.assertEqual(len(changes), 2)

    def test_refuses_unknown_menu_shape(self):
        with self.assertRaisesRegex(ValueError, "Unrecognized"):
            OVERLAY.rewrite_menu_scene('[node name="Other" type="Control"]\n')

    def test_refuses_menu_without_expected_warmup(self):
        with self.assertRaisesRegex(ValueError, "pre-simulation"):
            OVERLAY.rewrite_menu_scene('[node name="MainMenuBg" type="Control"]\n# NMainMenuBg.cs\n')

    def test_rejects_missing_variant_and_never_includes_unrelated_resource(self):
        profile = json.loads((ROOT / "ports/sts2/src/shaders/render-compat.json").read_text())
        variants = set().union(*(profile[key].values() for key in
            ("shader_paths", "material_paths", "embedded_codes")))
        required = variants | OVERLAY.NATIVE_RESOURCES
        entries = [(path, b"data", b"") for path in required]
        entries.append((next(iter(profile["shader_paths"])), b"unwanted alias", b""))
        self.assertEqual(set(OVERLAY.select_resources(entries, profile)), required)
        for missing in (next(iter(variants)), "res://shaders/mobile_compat/radial_blur_smooth.gdshader", "res://addons/portkit_performance/metrics.gd"):
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "Missing compatibility resources"):
                OVERLAY.select_resources([entry for entry in entries if entry[0] != missing], profile)

    def test_pack_contains_profile_variants_without_original_shader_aliases(self):
        scene = '''[node name="MainMenuBg" type="Control"]
# NMainMenuBg.cs
[node name="Clouds" type="GPUParticles2D" parent="."]
preprocess = 10.0
'''
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            source, pack, report = folder / "menu.tscn", folder / "overlay.pck", folder / "report.json"
            source.write_text(scene)
            subprocess.run([sys.executable, SPEC.origin, "--menu-background", str(source),
                "--output", str(pack), "--report", str(report)], check=True, capture_output=True)
            blob = pack.read_bytes()
            resources = read_pack(blob)
            profile = json.loads(resources["res://port_compat/render-compat.json"])
            variants = set().union(*(profile[key].values() for key in
                ("shader_paths", "material_paths", "embedded_codes")))
            smooth = "res://shaders/mobile_compat/radial_blur_smooth.gdshader"
            self.assertIn(smooth, resources)
            self.assertEqual({p for p in resources if p.startswith("res://shaders/mobile_compat/")}, variants | {smooth})
            self.assertFalse(set(profile["shader_paths"]) & resources.keys())
            self.assertFalse(set(profile["material_paths"]) & resources.keys())
            self.assertIn("res://scenes/backgrounds/main_menu_bg.tscn", resources)
            self.assertIn(b"preprocess = 0.5", resources["res://scenes/backgrounds/main_menu_bg.tscn"])
            expected = variants | OVERLAY.NATIVE_RESOURCES | {"res://scenes/backgrounds/main_menu_bg.tscn"}
            self.assertEqual(set(resources), expected)
            details = json.loads(report.read_text())
            self.assertFalse(details["smooth_customized_resources"])
            self.assertFalse(details["smooth_generated_simple_effects"])
            self.assertNotIn("res://port_compat/simple_effects_enabled.txt", resources)
            self.assertEqual(details["smooth_particle_scenes"], [])
            self.assertFalse({"res://" + path for path in OVERLAY.SMOOTH_PARTICLE_SCENES} & resources.keys())
            self.assertEqual(details["resources"], sorted(resources))
            self.assertEqual(details["resource_count"], len(resources))
            self.assertEqual(details["overlay_sha256"], hashlib.sha256(blob).hexdigest())
            shader_dir = ROOT / "ports/sts2/src/shaders/mobile_compat"
            for path in variants:
                self.assertEqual(resources[path], (shader_dir / Path(path).name).read_bytes())
            balanced = resources["res://shaders/mobile_compat/radial_blur_compat.gdshader"].decode()
            fluent = resources[smooth].decode()
            uniforms = lambda shader: set(re.findall(r"uniform\s+\w+\s+(\w+)", shader))
            self.assertEqual(uniforms(balanced), uniforms(fluent))
            self.assertTrue({"blur_center", "blur_power", "sampling_count", "SCREEN_TEXTURE"} <= uniforms(fluent))
            self.assertIn("clamp(sampling_count, 1, 4)", balanced)
            self.assertIn("clamp(sampling_count, 1, 2)", fluent)
            for name in ("overlay.gd", "overlay.tscn", "metrics.gd"):
                path = "res://addons/portkit_performance/" + name
                self.assertEqual(resources[path], (ROOT / "_kit/godot/addons/portkit_performance" / name).read_bytes())


    def test_smooth_rewrite_requires_exact_source_identity(self):
        for path, official in OVERLAY.SMOOTH_PARTICLE_SCENES.items():
            source = b"synthetic source"
            spec = {**official, "sha256": hashlib.sha256(source).hexdigest()}
            result, report = OVERLAY.rewrite_smooth_particle_scene(source, path, spec)
            text = result.decode()
            self.assertIn(f'[node name="{official["root"]}" type="Node2D"]', text)
            self.assertIn(f'path="{official["script"]}"', text)
            self.assertIn('name="PortSimpleEffect" type="Polygon2D"', text)
            self.assertNotIn("GPUParticles2D", text)
            self.assertNotIn("Material", text)
            self.assertNotIn("Texture", text)
            self.assertTrue(report["generated_simple_effect"])
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                OVERLAY.rewrite_smooth_particle_scene(source + b"!", path, spec)

    def test_smooth_cli_rejects_missing_and_unknown_inputs_without_output(self):
        menu = '[node name="MainMenuBg" type="Control"]\n# NMainMenuBg.cs\n[node name="Clouds" type="GPUParticles2D" parent="."]\npreprocess = 10.0\n'
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "menu.tscn").write_text(menu)
            command = [sys.executable, SPEC.origin, "--menu-background", str(folder / "menu.tscn"),
                "--smooth-particle-scenes", str(folder), "--output", str(folder / "out.pck"), "--report", str(folder / "report.json")]
            for bad_input in (False, True):
                if bad_input:
                    for path in OVERLAY.SMOOTH_PARTICLE_SCENES:
                        target = folder / path
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text("unknown revision")
                with self.subTest(unknown=bad_input):
                    run = subprocess.run(command, capture_output=True, text=True)
                    self.assertNotEqual(run.returncode, 0)
                    self.assertFalse((folder / "out.pck").exists())
                    self.assertFalse((folder / "report.json").exists())

    def test_changed_source_pck_rejected_with_scan_report(self):
        writer_spec = importlib.util.spec_from_file_location("pck_writer", ROOT / "ports/sts2/src/scripts/make-overlay-pck.py")
        writer = importlib.util.module_from_spec(writer_spec)
        writer_spec.loader.exec_module(writer)
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            data = b'[gd_scene format=3]\n\n[node name="Unexpected" type="Node2D"]\n'
            source, output, report = folder / "new.pck", folder / "out.pck", folder / "report.json"
            writer.write_pack([("res://scenes/vfx/new.tscn", data, hashlib.md5(data).digest())], source)
            run = subprocess.run([sys.executable, SPEC.origin, "--source-pck", str(source), "--smooth", "--output", str(output), "--report", str(report)], capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertFalse(output.exists())
            details = json.loads(report.read_text())
            self.assertEqual(details["status"], "source_identity_mismatch")
            self.assertEqual(details["actual_pck_sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
            self.assertTrue(details["changed_scenes"])

    def test_smooth_pack_from_optional_player_scenes(self):
        source_pck = Path(os.environ.get("STS2_TEST_SOURCE_PCK", ""))
        if not source_pck.is_file():
            self.skipTest("set STS2_TEST_SOURCE_PCK to the audited player PCK")
        menu = '[node name="MainMenuBg" type="Control"]\n# NMainMenuBg.cs\n[node name="Clouds" type="GPUParticles2D" parent="."]\npreprocess = 10.0\n'
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "menu.tscn").write_text(menu)
            subprocess.run([sys.executable, SPEC.origin, "--source-pck", str(source_pck), "--smooth", "--output", str(folder / "out.pck"), "--report", str(folder / "report.json")], check=True, capture_output=True)
            blob = (folder / "out.pck").read_bytes()
            resources = read_pack(blob)
            report = json.loads((folder / "report.json").read_text())
            profile = json.loads(resources["res://port_compat/render-compat.json"])
            variants = set().union(*(profile[key].values() for key in ("shader_paths", "material_paths", "embedded_codes")))
            modified = report["turbulence_modified_resources"]
            self.assertEqual((len(report["smooth_particle_scenes"]), len(modified), report["turbulence_modified_field_count"]), (13, 116, 268))
            policy = report['global_material_shader_policy']
            self.assertEqual(policy['examined'], {'tscn': 1037, 'tres': 2284, 'gdshader': 100})
            self.assertEqual(sum(c['rule'] == 'particle_turbulence_disabled' for r in policy['resources'] for c in r['changes']), 282)
            expected = variants | OVERLAY.NATIVE_RESOURCES | {"res://scenes/backgrounds/main_menu_bg.tscn", "res://port_compat/simple_effects_enabled.txt", "res://port_compat/simple_effects_manifest.json"} | {"res://" + p for p in OVERLAY.SMOOTH_PARTICLE_SCENES} | {x["path"] for x in policy['resources'] if x['disposition'] == 'applied'} | {x["path"] for x in report["startup_resource_changes"]}
            self.assertEqual(set(resources), expected)
            aliases = (set(profile["shader_paths"]) | set(profile["material_paths"])) & resources.keys()
            self.assertEqual(aliases, {r['path'] for r in policy['resources'] if r['disposition'] == 'applied' and r['runtime_remap_if_eligible']})
            self.assertIn('res://shaders/blur/canvas_group_mask_blur.gdshader', {r['path'] for r in policy['resources'] if r['disposition'] == 'retained_excluded_shader'})
            self.assertNotIn('res://shaders/blur/canvas_group_mask_blur.gdshader', resources)
            self.assertEqual(len(report["menu_changes"]), 6)
            self.assertTrue(all(item["node"]["name"] and item["reason"] for item in report["menu_changes"]))
            self.assertEqual(report["menu_output_sha256"], hashlib.sha256(resources["res://scenes/backgrounds/main_menu_bg.tscn"]).hexdigest())
            self.assertTrue(report["smooth_customized_resources"])
            self.assertEqual(report["resources"], sorted(resources))
            self.assertEqual(report["resource_count"], len(resources))
            self.assertEqual(report["overlay_sha256"], hashlib.sha256(blob).hexdigest())
            self.assertTrue(report["smooth_generated_simple_effects"])
            self.assertEqual(resources["res://port_compat/simple_effects_enabled.txt"], b"simple effects enabled\n")
            self.assertEqual({item["path"] for item in report["smooth_particle_scenes"]}, {"res://" + path for path in OVERLAY.SMOOTH_PARTICLE_SCENES})
            manifest = json.loads(resources["res://port_compat/simple_effects_manifest.json"])
            self.assertEqual({item["path"] for item in manifest["scenes"]}, {"res://" + p for p in OVERLAY.SMOOTH_PARTICLE_SCENES})
            reader = OVERLAY.load_pck_reader()
            index = reader.read_pack(source_pck)
            with source_pck.open("rb") as stream:
                originals = {item["path"]: reader.entry_bytes(stream, index[item["path"].removeprefix("res://")]) for item in modified}
            for item in modified:
                original = originals[item["path"]]
                output = resources[item["path"]]
                lines = output.splitlines(keepends=True)
                wanted_ids = {field["material_id"] for field in item["modified_fields"]}
                active_id = None
                restored = []
                for i, line in enumerate(lines):
                    if line.startswith(b"["):
                        match = re.match(rb'^\[sub_resource\s+type="ParticleProcessMaterial"\s+id="([^"]+)"\s*\]', line)
                        active_id = match.group(1).decode() if match else None
                    if active_id in wanted_ids and re.match(rb'^\s*turbulence_enabled\s*=\s*false\s*$', line):
                        lines[i] = re.sub(rb'false', b'true', line, count=1)
                        restored.append(active_id)
                self.assertEqual(set(restored), wanted_ids)
                self.assertEqual(len(restored), len(wanted_ids))
                self.assertEqual(b"".join(lines), original)
                self.assertEqual(hashlib.sha256(original).hexdigest(), item["source_sha256"])
                self.assertEqual(hashlib.sha256(output).hexdigest(), item["output_sha256"])
            for scene_report in report["smooth_particle_scenes"]:
                path = scene_report["path"].removeprefix("res://")
                with source_pck.open("rb") as stream:
                    original = reader.entry_bytes(stream, index[path])
                output = resources[scene_report["path"]]
                spec = OVERLAY.SMOOTH_PARTICLE_SCENES[path]
                text = output.decode()
                self.assertIn(f'[node name="{spec["root"]}" type="Node2D"]', text)
                self.assertIn(f'path="{spec["script"]}"', text)
                self.assertIn('name="PortSimpleEffect" type="Polygon2D"', text)
                if not spec.get("child_frees_root", spec.get("root_lifetime") is None):
                    self.assertIn("free_root_on_finish = false", text)
                if spec.get("root_lifetime") is not None:
                    self.assertIn("_lifetime = " + str(spec["root_lifetime"]), text)
                self.assertNotIn("GPUParticles2D", text)
                self.assertNotIn("Material", text)
                self.assertNotIn("Texture", text)
                self.assertTrue(scene_report["generated_simple_effect"])
                self.assertEqual(scene_report["root_script"], spec["script"])
                self.assertEqual(scene_report["source_sha256"], hashlib.sha256(original).hexdigest())
                self.assertEqual(scene_report["output_sha256"], hashlib.sha256(output).hexdigest())



if __name__ == "__main__":
    unittest.main()
