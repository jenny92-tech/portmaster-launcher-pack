#!/usr/bin/env python3
# INPUT: private scan_vfx_catalog JSON from the exact audited player PCK
# OUTPUT: path/hash/class metadata and VFX turbulence dependency identities
# POS: reproducible inventory update; never copies proprietary scene contents
import argparse
import collections
import json
from pathlib import Path

REASONS = {
    'typed_cs_callback_contract_audit': 'Custom typed root; callback, child and lifetime contracts require audit.',
    'other_scriptless_or_inherited_audit': 'Non-targeted root or inherited scene; particle roots, child dependencies and callers require audit.',
    'protected_information_or_ui_audit': 'May carry gameplay or UI information; preserve pending semantic and caller audit.',
    'scriptless_visual_candidate_factory_and_child_audit': 'Scriptless static visual candidate; factory, callers and child contracts require audit.',
    'generic_particle_system_requires_lifetime_audit': 'Generic particle root; verify actual build manifest and source identity, and audit lifetime and callers.',
    'known_four_existing': 'Existing targeted scene; verify actual build manifest and source identity.',
}

def make_inventory(scan):
    scenes = []
    for item in scan['scenes']:
        kind = item['candidate_class']
        if kind not in REASONS:
            raise ValueError('Unrecognized static class: ' + kind)
        scenes.append({'path': item['path'], 'source_sha256': item['sha256'],
            'root_script': item['root_script'], 'categories_guessed': item['categories_guessed'],
            'static_class': kind, 'build_status': 'candidate_verify_build_manifest' if kind in
            ('known_four_existing', 'generic_particle_system_requires_lifetime_audit') else 'not_targeted_in_static_inventory',
            'review_reason': REASONS[kind]})
    if len(scenes) != scan['vfx_scene_count'] or len({x['path'] for x in scenes}) != len(scenes):
        raise ValueError('Scene inventory count or uniqueness mismatch')
    return {'source_pck_sha256': scan['source_pck_sha256'],
        'scope': 'All scenes/vfx .tscn entries in the identified source PCK; additional combat/UI inventory remains private.',
        'notes': ['This is an exhaustive static inventory, not a dynamic usage or safety audit.',
            'Category labels are pathname guesses and can overlap; empty means no inferred label.',
            'Candidate status requires comparison with the actual build manifest and source hash; it is not evidence that a scene was converted.',
            'Other entries are unreviewed static candidates or protected information, not a claim that no independent overlay contains them.',
            'This file contains identifiers and audit metadata only, not original scene contents.'],
        'scene_count': len(scenes), 'static_class_counts': dict(collections.Counter(x['static_class'] for x in scenes)), 'scenes': scenes}

def make_turbulence(scan):
    resources = {}
    for item in scan['particle_materials_with_turbulence_fields']:
        if item['properties'].get('turbulence_enabled') != 'true':
            continue
        record = resources.setdefault(item['scene'], {'source_sha256': item['source_sha256'], 'material_ids': [], 'referenced_by': []})
        if record['source_sha256'] != item['source_sha256'] or not item['id']:
            raise ValueError('Unrecognized VFX material identity: ' + item['scene'])
        record['material_ids'].append(item['id'])
        record['referenced_by'] = sorted(set(record['referenced_by']) | set(item['referenced_by']))
    for record in resources.values():
        record['material_ids'].sort()
    return {'source_pck_sha256': scan['source_pck_sha256'],
        'rule': 'ParticleProcessMaterial.turbulence_enabled true -> false; preserve every other byte', 'resources': dict(sorted(resources.items()))}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--catalog', required=True, type=Path)
    parser.add_argument('--expected-pck-sha256', required=True)
    parser.add_argument('--inventory', required=True, type=Path)
    parser.add_argument('--turbulence', required=True, type=Path)
    args = parser.parse_args()
    scan = json.loads(args.catalog.read_text())
    if scan['source_pck_sha256'] != args.expected_pck_sha256:
        raise ValueError('Catalog source identity does not match audited input')
    for path, payload in ((args.inventory, make_inventory(scan)), (args.turbulence, make_turbulence(scan))):
        path.write_text(json.dumps(payload, indent=2) + '\n')

if __name__ == '__main__':
    main()
