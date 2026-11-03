#!/usr/bin/env python3
# INPUT: 玩家提供的原始 Godot PCK 与私有输出目录
# OUTPUT: 全量视觉资源静态目录与低内存掌机审计摘要，不修改原包
# POS:    复用 PCK 校验读取器，递归分析场景依赖；不执行游戏脚本
"""Read-only static scene inventory; never execute or redistribute game assets."""
import argparse
import collections
import hashlib
import json
import re
import sys
from pathlib import Path
import low_texture_overlay as m

def scan(p):
    idx = m.read_pack(p)
    textpaths = [x for x in idx if x.endswith(('.tscn', '.tres', '.gdshader', '.gdshaderinc'))]
    with p.open('rb') as f:
        data = {n: m.entry_bytes(f, idx[n]).decode('utf-8') for n in textpaths}

    def attrs(s):
        result = dict(re.findall('(\\w+)="([^"]*)"', s))
        for (k, v) in re.findall('(\\w+)=ExtResource\\("([^"]+)"\\)', s):
            result[k] = 'ExtResource("' + v + '")'
        return result
    sections = re.compile('^\\[([^\\]]+)\\]\\s*\\n(.*?)(?=^\\[|\\Z)', re.M | re.S)
    refs = re.compile('ExtResource\\("([^"]+)"\\)')
    flags = {'screen_sampling': 'SCREEN_TEXTURE|screen_texture|hint_screen_texture|screen_uv', 'noise': 'noise|Noise', 'visual_shader': 'VisualShader', 'hash': '\\bhash\\w*\\s*\\(', 'texture_sampling': '\\btexture\\s*\\('}
    known = {'scenes/vfx/hit_spark_vfx.tscn', 'scenes/vfx/ui/vfx_debuff_applied.tscn', 'scenes/vfx/ui/vfx_buff_applied.tscn', 'scenes/vfx/vfx_cross_heal.tscn'}
    category_patterns = {'hit': 'hit|impact|attack|slash|strike|blunt|scratch|spark|stab', 'buff': 'buff|power_up|power_applied|strength', 'debuff': 'debuff|weak|vulnerab|stun|affliction', 'heal': 'heal|healing', 'block': 'block|shield', 'poison': 'poison|spore|toxic', 'burn': 'burn|fire|flame', 'lightning': 'lightning|electric|thunder|zap', 'death': 'death|die|explode|explosion', 'cardUI': 'card|damage_num|heal_num|blocked_text|arrow|target|selection|icon|status|energy'}
    records = {}
    for (name, t) in data.items():
        ext = {}
        nodes = []
        subs = []
        for (hdr, body) in sections.findall(t):
            typ = hdr.split(' ', 1)[0]
            a = attrs(hdr)
            if typ == 'ext_resource':
                ext[a.get('id', '')] = {'path': a.get('path'), 'type': a.get('type'), 'uid': a.get('uid')}
            elif typ in ('node', 'sub_resource', 'resource'):
                props = {}
                for line in body.splitlines():
                    match = re.match('^([\\w/.-]+)\\s*=\\s*(.*)$', line)
                    if match:
                        props[match.group(1)] = match.group(2)
                if typ == 'resource':
                    declaration = re.search('^\\[gd_resource ([^\\]]+)\\]', t, re.M)
                    if declaration:
                        a.update(attrs(declaration.group(1)))
                (nodes if typ == 'node' else subs).append({'attributes': a, 'header': hdr, 'properties': props})
        dep = [v for v in ext.values() if v.get('path')]
        if name.endswith(('.gdshader', '.gdshaderinc')):
            dep.extend(({'path': inc, 'type': 'shader_include', 'uid': None} for inc in re.findall('^\\s*#include\\s+["<](res://[^">]+)[">]', t, re.M)))
        shader_flags = [k for (k, pat) in flags.items() if re.search(pat, t, re.I)] if name.endswith(('.gdshader', '.gdshaderinc')) else []
        records[name] = {'external': ext, 'dependencies': dep, 'nodes': nodes, 'subresources': subs, 'shader_flags': shader_flags}

    def closure(name):
        seen = set()
        stack = [name]
        while stack:
            x = stack.pop()
            if x in seen:
                continue
            seen.add(x)
            if x in records:
                for d in records[x]['dependencies']:
                    path = d['path'].removeprefix('res://')
                    if path in records:
                        stack.append(path)
        return sorted(seen)

    def extresolve(v, ext):
        x = refs.search(v or '')
        return ext.get(x.group(1), {}).get('path') if x else None

    def scene(name):
        r = records[name]
        nodes = r['nodes']
        root = nodes[0] if nodes else None
        if not root:
            return None
        ex = r['external']
        script = extresolve(root['properties'].get('script'), ex)
        deps = closure(name)
        particles = []
        overrides = []
        scripts = []
        turb = []
        shaders = []
        for dep in deps:
            dr = records[dep]
            for n in dr['nodes']:
                at = n['attributes']
                props = n['properties']
                inst = extresolve(at.get('instance', ''), dr['external'])
                ns = extresolve(props.get('script'), dr['external'])
                if ns:
                    scripts.append({'scene': 'res://' + dep, 'node': at.get('name'), 'path': ns})
                if at.get('type', '').endswith('Particles2D') or at.get('type', '').endswith('Particles3D'):
                    particles.append({'scene': 'res://' + dep, 'node': at.get('name'), 'type': at.get('type'), 'parent': at.get('parent'), 'properties': {k: v for (k, v) in props.items() if k in ('amount', 'amount_ratio', 'emitting', 'one_shot', 'lifetime', 'preprocess', 'fixed_fps', 'process_material', 'speed_scale', 'trail_enabled', 'local_coords', 'explosiveness')}})
                if inst:
                    overrides.append({'scene': 'res://' + dep, 'node': at.get('name'), 'parent': at.get('parent'), 'instance': inst, 'properties': props})
            for sub in dr['subresources']:
                if sub['attributes'].get('type') == 'ParticleProcessMaterial':
                    tp = {k: v for (k, v) in sub['properties'].items() if k.startswith('turbulence_')}
                    if tp:
                        turb.append({'scene': 'res://' + dep, 'source_sha256': hashlib.sha256(data[dep].encode()).hexdigest(), 'id': sub['attributes'].get('id'), 'properties': tp})
            shader_marks = list(dr['shader_flags'])
            if any(('VisualShader' in sub['attributes'].get('type', '') for sub in dr['subresources'])):
                shader_marks.append('visual_shader_resource')
            if shader_marks:
                shaders.append({'path': 'res://' + dep, 'flags': shader_marks})
        allscripts = sorted(set((x['path'] for x in scripts)))
        rt = root['attributes'].get('type')
        rootinstance = extresolve(root['attributes'].get('instance', ''), ex)
        protected = bool(re.search('arrow|target|select|damage_num|heal_num|blocked_text|affliction|status|icon|energy|speech|thought|fullscreen_text', name, re.I))
        if name in known:
            klass = 'known_four_existing'
        elif protected:
            klass = 'protected_information_or_ui_audit'
        elif script and script.endswith('/NVfxParticleSystem.cs'):
            klass = 'generic_particle_system_requires_lifetime_audit'
        elif script:
            klass = 'typed_cs_callback_contract_audit'
        elif rt in ('Node2D', 'Control') and not allscripts and not rootinstance:
            klass = 'scriptless_visual_candidate_factory_and_child_audit'
        elif not script:
            klass = 'other_scriptless_or_inherited_audit'
        else:
            klass = 'audit'
        header_match = re.search('^\\[gd_scene ([^\\]]+)\\]', data[name], re.M)
        root_script_info = next((v for v in ex.values() if v.get('path') == script), None)
        return {
            'path': 'res://' + name,
            'scene_header': attrs(header_match.group(1)) if header_match else {},
            'root_script_resource': root_script_info,
            'sha256': hashlib.sha256(data[name].encode()).hexdigest(),
            'root': root,
            'root_type': rt,
            'root_script': script,
            'root_instance': rootinstance,
            'source_nodes': nodes,
            'source_parent_children': [{'name': n['attributes'].get('name'), 'parent': n['attributes'].get('parent'), 'type': n['attributes'].get('type'), 'instance': extresolve(n['attributes'].get('instance', ''), ex)} for n in nodes],
            'external_resources': r['dependencies'],
            'dependency_closure': ['res://' + x for x in deps if x != name],
            'dependency_text_sha256': {'res://' + x: hashlib.sha256(data[x].encode()).hexdigest() for x in deps if x != name},
            'unresolved_text_dependencies': sorted(set((d['path'] for x in deps for d in records[x]['dependencies'] if d['path'].endswith(('.tscn', '.tres', '.gdshader', '.gdshaderinc')) and d['path'].removeprefix('res://') not in records))),
            'dependency_instances_and_overrides': overrides,
            'script_paths_in_closure': allscripts,
            'particle_nodes_unique_source': particles,
            'particle_source_counts': dict(collections.Counter((n['type'] for n in particles))),
            'particle_process_material_turbulence_unique_source': turb,
            'heavy_shader_flags_unique_source': shaders,
            'categories_guessed': [k for (k, pat) in category_patterns.items() if re.search(pat, name, re.I)],
            'candidate_class': klass,
            'known_existing': name in known,
            'flags': {'protected_information_ui': protected, 'has_subscene_scripts': len(allscripts) > bool(script), 'cost_is_static_not_measured': True},
        }
    names = sorted((n for n in records if n.startswith('scenes/vfx/') and n.endswith('.tscn')))
    scenes = [scene(n) for n in names]
    if any((x is None for x in scenes)):
        raise ValueError('VFX scene has no parseable root node')
    other = [n for n in records if n.endswith('.tscn') and (n.startswith('scenes/combat/') or n.startswith('scenes/ui/'))]
    related = [n for n in other if re.search('vfx|effect|particle|damage|heal|target|arrow|select|status|icon|energy|combat', n, re.I)]
    roots = collections.Counter((x['root_script'] or 'type=' + str(x['root_type']) for x in scenes))
    counts = collections.Counter((x['candidate_class'] for x in scenes))
    result = {
        'source_pck': p.name,
        'source_pck_sha256': m.file_hash(p),
        'tool_sha256': m.file_hash(Path(__file__)),
        'reader_sha256': m.file_hash(Path(m.__file__)),
        'configuration': {'profile': 'low-memory-handheld', 'vfx_prefix': 'res://scenes/vfx/', 'scene_suffix': '.tscn', 'semantic_patterns': category_patterns, 'shader_patterns': flags, 'known_path_candidates': sorted(known)},
        'scope': 'all res://scenes/vfx/**/*.tscn; additional combat/ui names listed separately, not replacements',
        'method_notes': ['All categories are pathname guesses, not timings or runtime invocation evidence.', 'Particle nodes and process materials are unique source definitions over recursive ext_resource closure, not effective instance counts; inherited instance overrides are recorded separately.', 'Runtime-created children, dynamic loads, gameplay logic, callbacks, relative or UID-only shader includes, and actual GPU cost need separate audit.', 'Scene text encoded UTF-8 and entry integrity validated with PCK MD5.'],
        'entry_count': len(idx),
        'vfx_scene_count': len(scenes),
        'counts_by_root': dict(roots.most_common()),
        'counts_by_candidate_class': dict(counts),
        'scenes': scenes,
        'combat_ui_scene_count': len(other),
        'combat_ui_related_name_candidates': ['res://' + n for n in sorted(related)],
        'combat_ui_other_scene_names': ['res://' + n for n in sorted(set(other) - set(related))],
    }
    materials = {}
    for item in scenes:
        for material in item['particle_process_material_turbulence_unique_source']:
            key = (material['scene'], material['id'] or '')
            if key not in materials:
                materials[key] = dict(material, referenced_by=[])
            materials[key]['referenced_by'].append(item['path'])
    result['particle_materials_with_turbulence_fields'] = [materials[key] for key in sorted(materials)]
    return result

def report(result):
    scenes = result['scenes']
    gpu = sum((any(('GPU' in n['type'] for n in x['particle_nodes_unique_source'])) for x in scenes))
    cpu = sum((any(('CPU' in n['type'] for n in x['particle_nodes_unique_source'])) for x in scenes))
    turbulence = sum((any((t['properties'].get('turbulence_enabled') == 'true' for t in x['particle_process_material_turbulence_unique_source'])) for x in scenes))
    lines = [
        '# 低内存掌机 VFX 静态扫描', '',
        '输入 PCK SHA-256：`' + result['source_pck_sha256'] + '`',
        '扫描器 SHA-256：`' + result['tool_sha256'] + '`',
        'PCK 读取器 SHA-256：`' + result['reader_sha256'] + '`',
        '配置：`low-memory-handheld`；完整匹配规则见 JSON configuration。', '',
        f"全量扫描 {result['entry_count']} 条 PCK 记录，VFX 场景 {len(scenes)} 个。",
        f'递归依赖含 GPU 粒子 {gpu}、CPU 粒子 {cpu}、显式开启湍流 {turbulence} 个场景。',
        '', '## 筛查与限制', '',
        'GPU 粒子、湍流、屏幕采样及 VisualShader 是可能增加着色器或运行负担的线索，'
        '不是卡顿测量或耗时排序。闭包按源定义去重，实例数量、覆盖、默认值及运行时分支可能改变实际负担。',
        '脚本根、子脚本、场景实例及其属性保留在目录中；删除或替换前须审计强类型、回调、'
        '生命周期和运行时调用。路径语义类别只是猜测，伤害数字、目标箭头和状态图标等信息必须保留。',
        '扫描器不执行脚本，不访问设备，无法证明场景安全、运行频率或优化效果。'
        '动态加载、相对或 UID shader include、引擎默认值和现场表现需要独立审计。',
        '', '## 静态分类数量', '',
    ]
    lines.extend((f'- `{key}`：{value}' for (key, value) in result['counts_by_candidate_class'].items()))
    return '\n'.join(lines) + '\n'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True, help='只读输入 PCK')
    parser.add_argument('--output-dir', type=Path, required=True, help='私有目录；输出文件必须不存在')
    args = parser.parse_args()
    try:
        source = args.base.resolve(strict=True)
        if not source.is_file():
            raise ValueError('input must be a regular file')
        output = args.output_dir.resolve()
        if output == source:
            raise ValueError('output directory aliases input')
        targets = [output / 'vfx-catalog.json', output / 'vfx-catalog-report.md']
        if any((p.exists() or p.is_symlink() for p in targets)):
            raise FileExistsError('output file already exists; choose a fresh output directory')
        if any((p.resolve() == source for p in targets)):
            raise ValueError('output path aliases input')
        result = scan(source)
        contents = [json.dumps(result, ensure_ascii=False, indent=2) + '\n', report(result)]
        output.mkdir(parents=True, exist_ok=True)
        for (path, content) in zip(targets, contents):
            with path.open('x', encoding='utf-8') as fh:
                fh.write(content)
        print(f"scanned {result['vfx_scene_count']} scenes; outputs: {output}")
        return 0
    except (OSError, ValueError, UnicodeError) as exc:
        print(f'VFX scan failed: {exc}', file=sys.stderr)
        return 1
if __name__ == '__main__':
    sys.exit(main())
