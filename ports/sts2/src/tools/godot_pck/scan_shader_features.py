#!/usr/bin/env python3
# INPUT:  玩家原始 Godot PCK、着色器兼容映射与湍流规格
# OUTPUT: 私有静态资源类型、特征、依赖与覆盖 JSON 报告
# POS:    只读全包类型审计；不执行或导出原始游戏内容
"""Inventory recognisable rendering features without extracting game content."""
import argparse
import collections
import hashlib
import json
import re
import sys
from pathlib import Path

import low_texture_overlay as pck

ROOT = Path(__file__).resolve().parents[2]
HEADER = re.compile(r'^\[([^\]]+)\][ \t]*(?:\r?\n|$)')
ATTR = re.compile(r'(\w+)="([^"\n]*)"')
PROP = re.compile(r'^([\w/.-]+)\s*=\s*(.*)$', re.M)
REF = re.compile(r'ExtResource\("([^"]+)"\)')
CODE = re.compile(r'^code\s*=\s*("(?:\\.|[^"\\])*")', re.M | re.S)
TARGETS = {'ParticleProcessMaterial', 'ShaderMaterial', 'Shader', 'VisualShader',
           'StandardMaterial3D', 'ORMMaterial3D', 'CanvasItemMaterial',
           'GPUParticles2D', 'GPUParticles3D', 'CPUParticles2D', 'CPUParticles3D'}
SHADER_EXTS = ('.gdshader', '.gdshaderinc')
TEXT_EXTS = ('.tscn', '.tres', '.gdshader', '.gdshaderinc', '.remap', '.import', '.cs', '.gd')


def sections(text):
    """Split Godot sections while respecting quoted multiline values."""
    headers = []
    quoted = False
    offset = 0
    for line in text.splitlines(keepends=True):
        if not quoted:
            match = HEADER.match(line)
            if match:
                headers.append((offset, offset + len(line), match.group(1)))
        escaped = False
        for char in line:
            if escaped:
                escaped = False
            elif char == "\\" and quoted:
                escaped = True
            elif char == '"':
                quoted = not quoted
        offset += len(line)
    if quoted:
        raise ValueError('unterminated quoted resource field')
    return [(header, text[body_start:headers[i + 1][0] if i + 1 < len(headers) else len(text)])
            for i, (_, body_start, header) in enumerate(headers)]


def hash_file(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def shader_features(code):
    # Counts are lexical indicators, not execution or performance estimates.
    clean = re.sub(r'/\*.*?\*/|//[^\n]*', '', code, flags=re.S)
    code = code.replace('\r\n', '\n').replace('\r', '\n')
    screens = re.findall(r'\buniform\s+sampler\w*\s+(\w+)\s*:\s*hint_screen_texture', clean)
    samples = re.findall(r'\b(?:texture|textureLod|textureGrad|textureProj)\s*\(\s*(\w+)', clean)
    screen_samples = sum(s in screens or s == 'SCREEN_TEXTURE' for s in samples)
    flags = []
    for name, present in (
        ('shader_type_particles', bool(re.search(r'\bshader_type\s+particles\s*;', clean))),
        ('shader_turbulence', bool(re.search(r'\bturbulen\w*\b', clean, re.I))),
        ('screen_texture', bool(screens or re.search(r'\bSCREEN_TEXTURE\b', clean))),
        ('screen_multi_sample', screen_samples > 1),
        ('texture_sampling', bool(samples)),
        ('texture_multi_call', len(samples) >= 3),
        ('screen_sampling_loop', bool(screens) and bool(re.search(r'\b(?:for|while|do)\s*(?:\(|\{)', clean))),
        ('blur', bool(re.search(r'\bblur\b|\bblur\w*|\bgaussian\b', clean, re.I))),
        ('noise', bool(re.search(r'\b\w*noise\w*\b|\bhash\w*\s*\(', clean, re.I))),
        ('loops', bool(re.search(r'\b(?:for|while|do)\s*(?:\(|\{)', clean))),
        ('large_generated_candidate', len(clean) >= 10000),
    ):
        if present:
            flags.append(name)
    return flags, {'code_sha256': hashlib.sha256(code.encode()).hexdigest(),
                   'code_bytes': len(code.encode()), 'texture_call_sites': len(samples),
                   'screen_texture_call_sites': screen_samples}


def scan(base, profile, turbulence):
    entries = pck.read_pack(base)
    inventory = collections.Counter(Path(n).suffix.lower() or '(no extension)' for n in entries)
    records, edges, unreadable, binaries = [], collections.defaultdict(set), [], []
    scripts = []
    script_placeholders = 0
    with base.open('rb') as f:
        for path, entry in entries.items():
            ext = Path(path).suffix.lower()
            name = 'res://' + path
            if ext in ('.scn', '.res', '.gdc'):
                raw = pck.entry_bytes(f, entry)
                # String hits are only hints; binary formats are not decoded.
                hits = [t for t in TARGETS if t.encode() in raw]
                binaries.append({'path': name, 'sha256': hashlib.sha256(raw).hexdigest(),
                                 'bytes': len(raw), 'magic_hex': raw[:4].hex(), 'type_string_hints': sorted(hits)})
                continue
            if ext not in TEXT_EXTS:
                continue
            raw = pck.entry_bytes(f, entry)
            digest = hashlib.sha256(raw).hexdigest()
            try:
                text = raw.decode('utf-8')
            except UnicodeDecodeError:
                unreadable.append({'path': name, 'sha256': digest, 'reason': 'non-UTF-8'})
                continue
            if ext in ('.cs', '.gd'):
                if not text.strip():
                    script_placeholders += 1
                terms = [t for t in ('TurbulenceEnabled', 'turbulence_enabled', 'ParticleProcessMaterial',
                         'GPUParticles2D', 'GPUParticles3D', 'ShaderMaterial', 'VisualShader',
                         'SetShaderParameter', 'SetInstanceShaderParameter', 'Load<', 'ResourceLoader') if t in text]
                if terms:
                    scripts.append({'path': name, 'sha256': digest, 'terms': terms})
                continue
            if ext in ('.remap', '.import'):
                for dest in re.findall(r'^path(?:\.\w+)?\s*=\s*"(res://[^"]+)"', text, re.M):
                    edges[name[:-len(ext)]].add(dest)
                continue
            if ext in SHADER_EXTS:
                flags, detail = shader_features(text)
                records.append({'path': name, 'sha256': digest, 'kind': 'shader_file', 'type': 'ShaderInclude' if ext == '.gdshaderinc' else 'Shader',
                                'id': None, 'features': flags, **detail, 'coverage': 'shader_path' if name in profile['shader_paths'] else None})
                for dest in re.findall(r'^\s*#include\s+["<](res://[^">]+)[">]', text, re.M):
                    edges[name].add(dest)
                continue
            if not text.startswith(('[gd_scene', '[gd_resource')):
                unreadable.append({'path': name, 'sha256': digest, 'reason': 'unrecognised text resource header'})
                continue
            header = text.splitlines()[0]
            root_type = dict(ATTR.findall(header)).get('type')
            parsed_sections = sections(text)
            local = {dict(ATTR.findall(hdr)).get('id'): (dict(ATTR.findall(hdr)).get('type'), body) for hdr, body in parsed_sections if hdr.startswith('sub_resource ')}
            external = {dict(ATTR.findall(hdr)).get('id'): dict(ATTR.findall(hdr)).get('path') for hdr, _ in parsed_sections if hdr.startswith('ext_resource ')}
            for hdr, body in parsed_sections:
                attrs = dict(ATTR.findall(hdr))
                if hdr.split(' ', 1)[0] == 'ext_resource' and attrs.get('path', '').startswith('res://'):
                    edges[name].add(attrs['path'])
            for hdr, body in parsed_sections:
                section = hdr.split(' ', 1)[0]
                if section not in ('resource', 'sub_resource', 'node'):
                    continue
                attrs = dict(ATTR.findall(hdr))
                typ = root_type if section == 'resource' else attrs.get('type')
                props = dict(PROP.findall(body))
                # Retain suspicious fields on other types, so misclassification is visible.
                if typ not in TARGETS and 'turbulence_enabled' not in props:
                    continue
                features = []
                if props.get('turbulence_enabled') == 'true': features.append('turbulence_enabled')
                if any(k.startswith('turbulence_') for k in props): features.append('turbulence_fields')
                if any(k.startswith('collision_') and v not in ('0', 'false', 'null') for k, v in props.items()): features.append('collision_fields_nonzero')
                if any(k.startswith('sub_emitter') and v not in ('0', 'false', 'null', 'NodePath("")') for k, v in props.items()): features.append('subemitter_fields_nonzero')
                if any(k.startswith('trail_') and v not in ('0', 'false', 'null') for k, v in props.items()): features.append('trail_fields_nonzero')
                if any(k.startswith('draw_pass_') or k in ('material', 'material_override', 'draw_passes') for k in props): features.append('draw_material_or_pass')
                if typ == 'VisualShader': features.append('visual_shader')
                relevant = {k: v for k, v in props.items() if k == 'turbulence_enabled' or k in ('collision_mode', 'sub_emitter_mode', 'sub_emitter', 'trail_enabled', 'draw_passes', 'process_material', 'material', 'shader')}
                record = {'path': name, 'sha256': digest, 'kind': section, 'type': typ or 'unknown',
                          'id': attrs.get('id') if section == 'sub_resource' else attrs.get('name') if section == 'node' else None,
                          'features': features, 'fields': relevant,
                          'coverage': 'turbulence_spec' if typ == 'ParticleProcessMaterial' and props.get('turbulence_enabled') == 'true' and name in turbulence['resources'] and attrs.get('id') in turbulence['resources'][name]['material_ids'] and digest == turbulence['resources'][name]['source_sha256'] else 'material_path' if name in profile['material_paths'] and section == 'resource' else None}
                record['references'] = []
                for field, value in props.items():
                    for ref_type, ref_id in re.findall(r'(SubResource|ExtResource)\("([^"]+)"\)', value):
                        target = name + '::' + ref_id if ref_type == 'SubResource' else external.get(ref_id)
                        record['references'].append({'field': field, 'target': target, 'unresolved_id': ref_id if target is None else None})
                if typ == 'VisualShader':
                    ids = set(re.findall(r'SubResource\("([^"]+)"\)', body))
                    queue = list(ids)
                    while queue:
                        _, node_body = local.get(queue.pop(), (None, ''))
                        for ref_id in re.findall(r'SubResource\("([^"]+)"\)', node_body):
                            if ref_id not in ids:
                                ids.add(ref_id); queue.append(ref_id)
                    node_types = collections.Counter(local[i][0] for i in ids if i in local and local[i][0] and local[i][0].startswith('VisualShaderNode'))
                    record['graph_node_types'] = dict(sorted(node_types.items()))
                    record['graph_node_count'] = sum(node_types.values())
                    if node_types.get('VisualShaderNodeTexture', 0): record['features'].append('visual_shader_texture_nodes')
                    if record['graph_node_count'] >= 30: record['features'].append('visual_shader_large_graph_candidate')
                if typ == 'Shader':
                    match = CODE.search(body)
                    if match:
                        try:
                            code = json.loads(match.group(1).replace('\n', r'\n').replace('\r', r'\r').replace('\t', r'\t'))
                        except json.JSONDecodeError:
                            unreadable.append({'path': name, 'id': record['id'], 'reason': 'embedded shader literal parse failed'})
                        else:
                            shader_flags, detail = shader_features(code)
                            record['features'] += shader_flags
                            record.update(detail)
                            if detail['code_sha256'] in profile['embedded_codes']:
                                record['coverage'] = 'embedded_code'
                    else:
                        record['features'].append('shader_without_code')
                records.append(record)
    reverse = collections.defaultdict(set)
    for source, destinations in edges.items():
        for dest in destinations:
            reverse[dest].add(source)
    def scene_closure(path):
        seen, pending = {path}, [path]
        while pending:
            for parent in reverse.get(pending.pop(), ()):
                if parent not in seen:
                    seen.add(parent); pending.append(parent)
        return sorted(p for p in seen if p.endswith('.tscn'))
    closures = {path: scene_closure(path) for path in sorted({r['path'] for r in records if r['features']})}
    counts = collections.Counter(r['type'] for r in records)
    features = {}
    known_flags = {'shader_type_particles', 'shader_turbulence', 'screen_texture', 'screen_multi_sample',
                   'screen_sampling_loop', 'texture_sampling', 'texture_multi_call', 'blur', 'noise', 'loops',
                   'large_generated_candidate', 'visual_shader', 'visual_shader_texture_nodes',
                   'visual_shader_large_graph_candidate', 'turbulence_enabled', 'turbulence_fields',
                   'collision_fields_nonzero', 'subemitter_fields_nonzero', 'trail_fields_nonzero', 'draw_material_or_pass'}
    for flag in sorted(known_flags | {flag for r in records for flag in r['features']}):
        matching = [r for r in records if flag in r['features']]
        def covered(r):
            if flag in ('turbulence_enabled', 'turbulence_fields'):
                return r['coverage'] == 'turbulence_spec'
            if r['type'] in ('Shader', 'ShaderInclude'):
                return r['coverage'] in ('shader_path', 'embedded_code')
            return False
        features[flag] = {'records': len(matching), 'paths': len({r['path'] for r in matching}),
                          'covered_records': sum(covered(r) for r in matching),
                          'uncovered_records': sum(not covered(r) for r in matching),
                          'potential_scene_closure': len({s for r in matching for s in closures[r['path']]})}
    missing_refs = sorted({dest for destinations in edges.values() for dest in destinations if dest[6:] not in entries and dest not in edges})
    return {'source_sha256': hash_file(base), 'inventory': {'entries': len(entries), 'extensions': dict(sorted(inventory.items())),
            'binary_unparsed': binaries, 'text_unparsed': unreadable, 'type_counts': dict(sorted(counts.items())),
            'missing_static_references': missing_refs, 'script_files_with_type_or_dynamic_load_terms': len(scripts), 'empty_script_placeholders': script_placeholders},
            'features': features, 'records': records, 'script_hints': scripts,
            'dependencies': {k: sorted(v) for k, v in sorted(edges.items())}, 'potential_scene_closures': closures,
            'limitations': ['Lexical static indicators are not measured GPU cost or actual execution frequency.',
              'Binary .scn/.res/.gdc are not parsed; byte-string hits are hints only.',
              'Static reverse dependency closure is file-level over-approximation; script and UID loads and runtime parameters may be missing.',
              'Implicit defaults, engine-created resources, conditional loops, generated shader code and unknown include syntax require separate review.',
              'Empty script placeholders and binary scripts provide no proof about runtime changes or dynamic loads.',
              'Coverage means a matching configured identity, not proof the runtime reaches it; VisualShader generated-code identity requires runtime evaluation.',
              'VisualShader node counts follow static subresource links only; large graph means 30 or more nodes, not measured cost.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True, help='private fresh output directory')
    args = parser.parse_args()
    try:
        base = args.base.resolve(strict=True)
        out = args.output_dir.resolve()
        target = out / 'shader-features.json'
        if not base.is_file() or target.exists() or target.is_symlink() or target == base:
            raise ValueError('input must be a file and output must be new and distinct')
        profile = json.loads((ROOT / 'shaders/render-compat.json').read_text())
        turbulence = json.loads((ROOT / 'scripts/turbulence_specs.json').read_text())
        result = scan(base, profile, turbulence)
        out.mkdir(parents=True, exist_ok=True)
        with target.open('x', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
            f.write('\n')
        print(f"scanned {result['inventory']['entries']} entries; private report: {target}")
    except (OSError, ValueError, UnicodeError, KeyError) as exc:
        print(f'shader feature scan failed: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
