#!/usr/bin/env python3
# INPUT:  玩家菜单背景场景、可选的精确身份特效场景、兼容源码与 PCK 写入器
# OUTPUT: 原生适配资源覆盖包、来源和修改报告
# POS:    官方 Godot 菜单粒子预模拟与可选流畅档轻量特效场景
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
AUDITED_GAME_DLL_SHA256 = "7c446efabf80614c429b5088e87101423aa5bb4c04fc3e73393261f6e6d404fd"

_global_spec = importlib.util.spec_from_file_location("global_material_policy", ROOT / "scripts/global_material_policy.py")
_global_policy = importlib.util.module_from_spec(_global_spec)
_global_spec.loader.exec_module(_global_policy)


def global_visual_resources(source_pck, reader, index, simple_paths, profile):
    """Scan the entire PCK; rules depend on serialized type and shader syntax."""
    result = {}; records = []; unknown = []; counts = {"tscn": 0, "tres": 0, "gdshader": 0}
    with source_pck.open('rb') as source:
        for path in sorted(index):
            suffix = Path(path).suffix.lower()
            if suffix in ('.scn', '.remap', '.gdshaderinc', '.gdc'):
                unknown.append({"path": "res://"+path, "format": suffix, "reason": "binary, remap, compiled script or include not rewritten by text material rules"})
                continue
            if suffix not in ('.tscn', '.tres', '.gdshader'): continue
            counts[suffix[1:]] += 1
            data = reader.entry_bytes(source, index[path])
            if suffix in ('.tscn', '.tres') and not data.startswith((b'[gd_scene', b'[gd_resource')):
                unknown.append({"path": "res://"+path, "format": "unknown resource", "reason": "not a recognized Godot text resource"})
                continue
            if suffix in ('.tscn', '.tres'):
                spans = _global_policy.sections(data)
                root_type = None
                for i, (start, kind, attrs) in enumerate(spans):
                    type_match = _global_policy.TYPE.search(attrs)
                    section_type = type_match.group(1).decode() if type_match else None
                    if kind == b'gd_resource': root_type = section_type
                    if kind == b'resource': section_type = root_type
                    if section_type == 'VisualShader' and kind != b'resource':
                        unknown.append({"path":"res://"+path,"format":"VisualShader", "reason":"graph-generated shader is not rewritten by text shader rules"})
                    if section_type == 'Shader':
                        end = spans[i+1][0] if i+1<len(spans) else len(data)
                        chunk = data[start:end]; bounds = _global_policy.quoted_shader_range(chunk)
                        if bounds and b'\\' in chunk[bounds[0]:bounds[1]]:
                            unknown.append({"path":"res://"+path,"format":"escaped embedded Shader", "reason":"escaped code is retained without a lossless rewrite"})
                        elif bounds and not _global_policy.transform_shader(chunk[bounds[0]:bounds[1]])[1]:
                            unknown.append({"path":"res://"+path,"format":"embedded Shader", "reason":"not matched by a supported visual rule; retained"})
            output, changes = _global_policy.transform_resource(path, data)
            if not changes:
                if suffix == '.gdshader':
                    unknown.append({"path":"res://"+path,"format":"Shader", "reason":"not matched by a supported visual rule; retained"})
                continue
            superseded = path in simple_paths
            resource_path = "res://"+path
            excluded = resource_path in profile['excluded_shader_paths']
            runtime_remap = profile['shader_paths'].get(resource_path) or profile['material_paths'].get(resource_path)
            records.append({"path": resource_path, "source_sha256": _global_policy.sha(data),
                            "output_sha256": _global_policy.sha(data if excluded else output), "changes": changes,
                            "disposition": "retained_excluded_shader" if excluded else "superseded_by_complete_simple_scene" if superseded else "applied",
                            "retained_reason": "Protected mask/compositing contract" if excluded else None,
                            "runtime_remap_if_eligible": runtime_remap,
                            "runtime_note": "Recognized simplified shader code takes precedence in low quality; mask and other exclusions remain" if runtime_remap else None})
            if not superseded and not excluded: result["res://"+path] = output
    return result, {"examined": counts, "resources": records, "unknown_or_unhandled": unknown}

# The complete source digest pins all fields, including C# node paths and
# inherited scene references. Never accept a merely similar game revision.
SMOOTH_PARTICLE_SCENES = {
    "scenes/vfx/hit_spark_vfx.tscn": {
        "sha256": "27925af9d28d8df1d36cbf2f0e341951cc5737fcdf7bd4d31a0910d25ed3aacd",
        "script": "res://src/Core/Nodes/Vfx/NHitSparkVfx.cs",
        "uid": "uid://dpewwkyopcvc4", "scene_uid": "uid://266giv2m6upb", "root": "HitSparkVfx",
        "color": "Color(1, 0.72, 0.4, 1)",
        "category": "flash",
    },
    "scenes/vfx/ui/vfx_debuff_applied.tscn": {
        "sha256": "49a39474c5ff182985bef8d313c5af6ca394b79d9aae770aecf078e5a00cd78c",
        "script": "res://src/Core/Nodes/Vfx/Ui/NPowerAppliedDebuffVfx.cs",
        "uid": "uid://dq4vce50arh5l", "scene_uid": "uid://hcia40gpn3yi", "root": "vfx_debuff_applied",
        "color": "Color(1, 0.3, 0.38, 1)",
        "category": "flash",
    },
    "scenes/vfx/ui/vfx_buff_applied.tscn": {
        "sha256": "2f6f7b31d4cfa3fb8ee3c7753d40fc215b09d5b8908e72b62979d48041b98f90",
        "script": "res://src/Core/Nodes/Vfx/Ui/NPowerAppliedBuffVfx.cs",
        "uid": "uid://bli4qyb6xcot2", "scene_uid": "uid://dprqwxp02gv51", "root": "vfx_buff_applied",
        "color": "Color(0.31, 1, 0.46, 1)",
        "category": "green_plus",
    },
    "scenes/vfx/vfx_cross_heal.tscn": {
        "sha256": "dd2b0e3116bea3f6706790326a02c0c49094bd4935e4470da94378ebaeba5940",
        "script": "res://src/Core/Nodes/Vfx/Utilities/NVfxParticleSystem.cs",
        "uid": "uid://cx71ev3yexjaf", "scene_uid": "uid://cuikx8jvp1trp", "root": "VfxHeal",
        "color": "Color(0.31, 1, 0.46, 1)", "root_lifetime": 4.0,
        "category": "green_plus",
    },
}

_generic_spec = importlib.util.spec_from_file_location("simple_effects_specs", ROOT / "scripts/simple_effects_specs.py")
_generic_module = importlib.util.module_from_spec(_generic_spec)
_generic_spec.loader.exec_module(_generic_module)
SMOOTH_PARTICLE_SCENES.update(_generic_module.GENERIC_TIMED_SCENES)

POLYGONS = {
    "green_plus": "-28, -3, -4, -3, -4, -22, 4, -22, 4, -3, 28, -3, 28, 3, 4, 3, 4, 22, -4, 22, -4, 3, -28, 3",
    "flash": "-28, -3, -5, -5, 0, -22, 5, -5, 28, -3, 5, 5, 0, 22, -5, 5",
    "slash": "-35, 11, -27, 3, 35, -11, 27, -3",
    "ember": "-18, 5, -9, -12, 0, -25, 9, -12, 18, 5, 10, 16, -10, 16",
}

NOT_SIMPLIFIED_REASONS = {
    "res://scenes/vfx/vfx_cross_heal_fullscreen.tscn": "PlayerFullscreenHealVfx.Play accesses the beam GPUParticles2D by name",
    **{f"res://scenes/vfx/{name}.tscn": "Contains LightOccluder2D; child and visual contract not audited"
       for name in ("vfx_blood_wall", "vfx_coin_explosion_jumbo", "vfx_coin_explosion_regular",
                    "vfx_coin_explosion_small", "vfx_rock_shatter", "vfx_sandy_impact", "vfx_slime_impact")},
}

def load_pck_reader():
    spec = importlib.util.spec_from_file_location("low_texture_overlay", ROOT / "tools/godot_pck/low_texture_overlay.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def report_changed_source(source_pck, source_sha, inventory, turbulence, report_path):
    tools_dir = str(ROOT / "tools/godot_pck")
    sys.path.insert(0, tools_dir)
    try:
        spec = importlib.util.spec_from_file_location("scan_vfx_catalog", Path(tools_dir) / "scan_vfx_catalog.py")
        scanner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scanner)
        current = scanner.scan(source_pck)
    finally:
        sys.path.remove(tools_dir)
    before = {item["path"]: item for item in inventory["scenes"]}
    after = {item["path"]: item for item in current["scenes"]}
    differences = []
    for path in sorted(before.keys() | after.keys()):
        old, new = before.get(path), after.get(path)
        old_sha = old.get("source_sha256") if old else None
        new_sha = new.get("sha256") if new else None
        if old_sha != new_sha:
            differences.append({"path": path, "old_sha256": old_sha, "new_sha256": new_sha,
                "old_root_script": old.get("root_script") if old else None,
                "root_script": new.get("root_script") if new else None,
                "root_type": new.get("root_type") if new else None,
                "root_properties": new.get("root", {}).get("properties", {}) if new else None,
                "static_class": new.get("candidate_class") if new else None,
                "reason": "Source identity changed; review scene structure and managed callers before approving a rule"})
    new_materials = {}
    for material in current["particle_materials_with_turbulence_fields"]:
        if material["properties"].get("turbulence_enabled") == "true":
            item = new_materials.setdefault(material["scene"], {"sha256": material["source_sha256"], "ids": []})
            item["ids"].append(material["id"])
    material_differences = []
    for path in sorted(turbulence["resources"].keys() | new_materials.keys()):
        old, new = turbulence["resources"].get(path), new_materials.get(path)
        old_sha = old.get("source_sha256") if old else None
        new_sha = new.get("sha256") if new else None
        if old_sha != new_sha:
            material_differences.append({"path": path, "old_sha256": old_sha, "new_sha256": new_sha,
                "material_ids": sorted(new["ids"], key=lambda x: x or "") if new else [],
                "reason": "Unreviewed material identity or structure; no turbulence rewrite applied"})
    result = {"status": "source_identity_mismatch", "profile": "smooth",
        "expected_pck_sha256": inventory["source_pck_sha256"], "actual_pck_sha256": source_sha,
        "scan_scene_count": len(after), "changed_scenes": differences, "changed_turbulence_resources": material_differences,
        "reason": "Managed caller and resource identities must be re-audited; no new overlay was generated and any existing output was left untouched"}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(result, indent=2) + "\n")


def rewrite_turbulence(source, path, spec):
    source_sha = hashlib.sha256(source).hexdigest()
    if source_sha != spec["source_sha256"]:
        raise ValueError(f"Unrecognized turbulence resource SHA-256: {path} ({source_sha})")
    lines = source.splitlines(keepends=True)
    current = None
    modified = []
    header = re.compile(rb'^\[sub_resource\s+type="ParticleProcessMaterial"\s+id="([^\"]+)"\s*\]')
    setting = re.compile(rb'^([ \t]*turbulence_enabled[ \t]*=[ \t]*)true([ \t]*\r?\n?)$')
    for index, line in enumerate(lines):
        if line.startswith(b"["):
            match = header.match(line)
            current = match.group(1).decode("utf-8") if match else None
        match = setting.fullmatch(line) if current is not None else None
        if match:
            lines[index] = match.group(1) + b"false" + match.group(2)
            modified.append(current)
    if sorted(modified) != sorted(spec["material_ids"]):
        raise ValueError(f"Unexpected turbulence material fields: {path}")
    result = b"".join(lines)
    return result, {"path": path, "source_sha256": source_sha,
        "output_sha256": hashlib.sha256(result).hexdigest(),
        "profile": "smooth", "rule": "particle_turbulence_disabled",
        "reason": "Reduce particle motion shader cost while preserving nodes, scripts and timing",
        "modified_fields": [{"material_id": item, "field": "turbulence_enabled", "before": True, "after": False} for item in modified],
        "referenced_by": spec["referenced_by"]}


def rewrite_smooth_particle_scene(source, path, spec):
    source_sha = hashlib.sha256(source).hexdigest()
    if source_sha != spec["sha256"]:
        raise ValueError(f"Unrecognized smooth effect scene SHA-256: {path} ({source_sha})")
    # Keep the game's exact root script, but do not include any original VFX
    # dependencies. Generic particles retain their original timer; audited
    # managed _Ready hooks on hit/power roots let the flash free those roots.
    lifetime = spec.get("root_lifetime")
    properties = dict(spec.get("root_properties", {}))
    if lifetime is not None:
        properties["_lifetime"] = str(lifetime)
    root_properties = "".join(f"\n{key} = {value}" for key, value in properties.items())
    frees_root = spec.get("child_frees_root", lifetime is None)
    child_properties = "" if frees_root else "\nfree_root_on_finish = false"
    result = f'''[gd_scene load_steps=3 format=3 uid="{spec["scene_uid"]}"]

[ext_resource type="Script" uid="{spec["uid"]}" path="{spec["script"]}" id="1"]
[ext_resource type="Script" path="res://port_compat/simple_effect.gd" id="2"]

[node name="{spec["root"]}" type="Node2D"]
script = ExtResource("1"){root_properties}

[node name="PortSimpleEffect" type="Polygon2D" parent="."]
color = {spec["color"]}
polygon = PackedVector2Array({POLYGONS[spec["category"]]})
script = ExtResource("2"){child_properties}
'''.encode("utf-8")
    return result, {"path": "res://" + path, "source_sha256": source_sha,
                    "output_sha256": hashlib.sha256(result).hexdigest(),
                    "profile": "smooth", "rule": "audited_typed_root_simple_polygon",
                    "reason": "Replace audited particle visuals while retaining the managed root and its lifecycle contract",
                    "generated_simple_effect": True, "category": spec["category"],
                    "root_script": spec["script"], "root_type": "Node2D",
                    "root_lifetime": lifetime, "root_properties": properties,
                    "child_frees_root": frees_root}


def rewrite_menu_scene(text):
    if '[node name="MainMenuBg" type="Control"]' not in text or 'NMainMenuBg.cs' not in text:
        raise ValueError("Unrecognized main-menu background scene")
    lines = []
    particles = False
    node = None
    changes = []
    for line in text.splitlines(keepends=True):
        if line.startswith("[node "):
            particles = 'type="GPUParticles2D"' in line
            name = re.search(r'\bname="([^"]+)"', line)
            parent = re.search(r'\bparent="([^"]+)"', line)
            node = {"name": name.group(1) if name else None, "parent": parent.group(1) if parent else None}
        if particles:
            match = re.fullmatch(r"(amount|preprocess) = ([0-9.]+)(\r?\n)?", line)
            if match:
                field, number, ending = match.groups()
                old = float(number)
                new = min(old, 32 if field == "amount" else 0.5)
                if new != old:
                    line = f"{field} = {new:g}{ending or ''}"
                    changes.append({"node": node, "field": field, "before": old, "after": new,
                        "reason": "Bound menu particle pre-simulation cost while preserving node and timing lifecycle"})
        lines.append(line)
    if not any(change["field"] == "preprocess" for change in changes):
        raise ValueError("No expected particle pre-simulation settings found")
    return "".join(lines), changes


NATIVE_RESOURCES = {
    "res://port_compat/bundled_font_trial.gd",
    "res://port_compat/combat_warmup.gd",
    "res://port_compat/render_compat.gd",
    "res://port_compat/simple_effect.gd",
    "res://port_compat/startup_effect_preload.gd",
    "res://port_compat/render_compat.tscn",
    "res://port_compat/shader_compat.gd",
    "res://port_compat/render-compat.json",
    "res://addons/portkit_performance/overlay.gd",
    "res://addons/portkit_performance/overlay.tscn",
    "res://addons/portkit_performance/metrics.gd",
    "res://shaders/mobile_compat/radial_blur_smooth.gdshader",
}


def select_resources(collected, profile):
    variants = set().union(*(profile[key].values() for key in
        ("shader_paths", "material_paths", "embedded_codes")))
    if len(variants) != 27 or any(not path.startswith("res://shaders/mobile_compat/")
            or not path.endswith(".gdshader") for path in variants):
        raise ValueError("Unexpected shader compatibility variants")
    entries = {path: data for path, data, _ in collected}
    required = variants | NATIVE_RESOURCES
    missing = required - entries.keys()
    if missing:
        raise ValueError("Missing compatibility resources: " + ", ".join(sorted(missing)))
    # Only the audited native resources and profile variants belong in this pack.
    # In particular, no original shader or material path may become a PCK alias.
    return {path: entries[path] for path in required}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-pck", type=Path, help="original player PCK; resources are verified and read into memory")
    parser.add_argument("--smooth", action="store_true", help="enable audited Smooth scene and turbulence rules with --source-pck")
    parser.add_argument("--menu-background", type=Path, help="legacy mode: extracted original main menu scene")
    parser.add_argument("--smooth-particle-scenes", type=Path, metavar="DIR",
                        help="explicit Smooth trial: directory containing the audited scenes/ paths")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    if args.source_pck is not None:
        if args.menu_background is not None or args.smooth_particle_scenes is not None:
            parser.error("--source-pck cannot be combined with extracted input paths")
    elif args.menu_background is None or args.smooth:
        parser.error("provide --source-pck (required for --smooth) or --menu-background")
    if args.output.resolve() == args.report.resolve() or (args.source_pck and args.source_pck.resolve() in (args.output.resolve(), args.report.resolve())):
        parser.error("source PCK, output and report must be distinct")
    smooth = args.smooth or args.smooth_particle_scenes is not None
    spec = importlib.util.spec_from_file_location("pck_writer", ROOT / "scripts/make-overlay-pck.py")
    writer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(writer)
    profile = json.loads((ROOT / "shaders/render-compat.json").read_text())
    entries = select_resources(writer.collect_files(), profile)
    variants = set().union(*(profile[key].values() for key in
        ("shader_paths", "material_paths", "embedded_codes")))
    smooth_changes = []
    turbulence_changes = []
    global_policy_report = None
    inventory_path = ROOT / "scripts/simple_effects_inventory.json"
    inventory = json.loads(inventory_path.read_text())
    audited = {item["path"]: item for item in inventory["scenes"]}
    if len(audited) != inventory["scene_count"]:
        raise ValueError("Invalid VFX inventory: duplicate paths or count mismatch")
    turbulence_path = ROOT / "scripts/turbulence_specs.json"
    turbulence = json.loads(turbulence_path.read_text())
    if turbulence["source_pck_sha256"] != inventory["source_pck_sha256"]:
        raise ValueError("VFX inventory and turbulence identities disagree")
    source_pck_sha = None
    source_resources = {}
    startup_resource_changes = []
    if args.source_pck is not None:
        source_pck_sha = sha256_file(args.source_pck)
        if smooth and source_pck_sha != inventory["source_pck_sha256"]:
            report_changed_source(args.source_pck, source_pck_sha, inventory, turbulence, args.report)
            raise ValueError("Source PCK identity changed; see the scan and difference report")
        reader = load_pck_reader()
        index = reader.read_pack(args.source_pck)
        if smooth:
            runtime_spec = importlib.util.spec_from_file_location("windows_runtime_resources", ROOT / "scripts/windows_runtime_resources.py")
            runtime = importlib.util.module_from_spec(runtime_spec)
            runtime_spec.loader.exec_module(runtime)
            runtime_entries, startup_resource_changes = runtime.build(args.source_pck, reader, index)
            entries.update(runtime_entries)
        wanted = {"scenes/backgrounds/main_menu_bg.tscn"}
        if smooth:
            wanted.update(SMOOTH_PARTICLE_SCENES)
            global_entries, global_policy_report = global_visual_resources(args.source_pck, reader, index, set(SMOOTH_PARTICLE_SCENES), profile)
            entries.update(global_entries)
            profile_for_pack = dict(profile)
            profile_for_pack['global_simplified_code_hashes'] = sorted({change['output_code_sha256']
                for item in global_policy_report['resources'] if item['disposition'] == 'applied'
                for change in item['changes'] if 'output_code_sha256' in change})
            entries['res://port_compat/render-compat.json'] = (json.dumps(profile_for_pack, indent=2) + '\n').encode()
        with args.source_pck.open("rb") as stream:
            for path in sorted(wanted):
                if path not in index:
                    raise ValueError(f"Missing source PCK resource: {path}")
                source_resources[path] = reader.entry_bytes(stream, index[path])
        menu_source = entries.get("res://scenes/backgrounds/main_menu_bg.tscn", source_resources["scenes/backgrounds/main_menu_bg.tscn"])
    else:
        menu_source = args.menu_background.read_bytes()
    scene, menu_changes = rewrite_menu_scene(menu_source.decode("utf-8"))
    entries["res://scenes/backgrounds/main_menu_bg.tscn"] = scene.encode()
    if smooth:
        for path, scene_spec in SMOOTH_PARTICLE_SCENES.items():
            source = source_resources[path] if args.source_pck else (args.smooth_particle_scenes / path).read_bytes()
            rewritten, scene_report = rewrite_smooth_particle_scene(source, path, scene_spec)
            known = audited.get(scene_report["path"])
            if known is None or known["source_sha256"] != scene_report["source_sha256"] or known["root_script"] != scene_report["root_script"]:
                raise ValueError(f"VFX inventory does not match generated scene: {path}")
            entries["res://" + path] = rewritten
            smooth_changes.append(scene_report)
        if args.source_pck:
            for item in global_policy_report['resources']:
                material_changes = [c for c in item['changes'] if c['rule'] == 'particle_turbulence_disabled']
                if material_changes and item['disposition'] == 'applied':
                    turbulence_changes.append({'path':item['path'], 'source_sha256':item['source_sha256'],
                        'output_sha256':item['output_sha256'], 'modified_fields':material_changes,
                        'referenced_by':turbulence['resources'].get(item['path'],{}).get('referenced_by',[])})
        else:
            for path, material_spec in turbulence["resources"].items():
                if path in entries:
                    continue  # The complete scene replacement takes precedence.
                relative = path.removeprefix("res://")
                source = (args.smooth_particle_scenes / relative).read_bytes()
                rewritten, material_report = rewrite_turbulence(source, path, material_spec)
                entries[path] = rewritten
                turbulence_changes.append(material_report)
        entries["res://port_compat/simple_effects_enabled.txt"] = b"simple effects enabled\n"
        entries["res://port_compat/simple_effects_manifest.json"] = (json.dumps(
            {"scenes": smooth_changes}, indent=2, sort_keys=True) + "\n").encode()
    converted = {item["path"] for item in smooth_changes}
    turbulence_paths = {item["path"] for item in turbulence_changes}
    affected = set().union(*(set(item["referenced_by"]) for item in turbulence_changes))
    writer.write_pack([(path, data, hashlib.md5(data).digest())
        for path, data in sorted(entries.items())], args.output)
    report = {"profile": "smooth" if smooth else "standard", "source": profile["source"], "shader_identities": len(profile["shader_paths"]),
        "material_identities": len(profile["material_paths"]), "inline_identities": len(profile["embedded_codes"]),
        "mobile_variants": len(variants), "native_resource_count": len(NATIVE_RESOURCES),
        "resource_count": len(entries),
        "semantic_checks": {"original_shader_and_material_aliases_absent":
                not bool((set(profile["shader_paths"]) | set(profile["material_paths"])) & entries.keys()),
            "excluded_shader_aliases_absent": not bool(set(profile["excluded_shader_paths"]) & entries.keys()),
            "menu_gpu_particles": "amount <= 32 and preprocess <= 0.5 when explicitly set",
            "menu_cpu_particles": "unchanged"},
        "overlay_bytes": args.output.stat().st_size, "menu_changes": menu_changes,
        "smooth_customized_resources": smooth,
        "smooth_generated_simple_effects": smooth,
        "smooth_particle_scenes": smooth_changes,
        "source_pck_sha256": source_pck_sha,
        "audited_game_dll_sha256": AUDITED_GAME_DLL_SHA256,
        "game_dll_verified_by_overlay_builder": False,
        "turbulence_rule": turbulence["rule"],
        "turbulence_specs_sha256": hashlib.sha256(turbulence_path.read_bytes()).hexdigest(),
        "turbulence_modified_resources": turbulence_changes,
        "turbulence_modified_field_count": sum(len(x["modified_fields"]) for x in turbulence_changes),
        "global_material_shader_policy": global_policy_report,
        "turbulence_affected_source_closure_scenes": sorted(affected),
        "vfx_inventory_source_pck_sha256": inventory["source_pck_sha256"],
        "vfx_inventory_sha256": hashlib.sha256(inventory_path.read_bytes()).hexdigest(),
        "vfx_inventory_scene_count": inventory["scene_count"],
        "vfx_not_simplified": [{"path": item["path"], "reason":
            NOT_SIMPLIFIED_REASONS.get(item["path"], item["review_reason"]),
            "turbulence_rule": "direct" if item["path"] in turbulence_paths else
                "source_dependency" if item["path"] in affected else "not_applied"}
            for item in inventory["scenes"] if item["path"] not in converted],
        "startup_resource_changes": startup_resource_changes,
        "menu_source_sha256": hashlib.sha256(source_resources.get("scenes/backgrounds/main_menu_bg.tscn", menu_source)).hexdigest(),
        "menu_rewrite_input_sha256": hashlib.sha256(menu_source).hexdigest(),
        "menu_output_sha256": hashlib.sha256(entries["res://scenes/backgrounds/main_menu_bg.tscn"]).hexdigest(),
        "overlay_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
        "resources": sorted(entries)}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
