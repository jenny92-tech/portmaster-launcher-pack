#!/usr/bin/env python3
# INPUT:  player-provided ARM64/Mali STS2 PCK, matching managed files and local build tools
# OUTPUT: private scan, auditable texture/scene reports, four-file patch and merged main PCK
# POS:    reproducible handheld-low build; does not connect to or operate a device
"""Rebuild the supported private STS2 handheld-low experiment without downloading tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
SRC = HERE.parent
PROFILE = HERE / 'handheld_low_profile.json'
WINDOWS_PROFILE = HERE / 'handheld_low_v110_profile.json'
WINDOWS_TEXTURE = HERE / 'godot_pck/windows_texture_overlay.py'
WINDOWS_PREPARE = HERE / 'prepare_windows_game.py'
SCAN = HERE / 'godot_pck/scan_vfx_catalog.py'
SHADER_SCAN = HERE / 'godot_pck/scan_shader_features.py'
TEXTURE = HERE / 'godot_pck/low_texture_overlay.py'
MERGE = HERE / 'godot_pck/merge_texture_pck.py'
OVERLAY = SRC / 'scripts/make-official-runtime-overlay.py'
TEXTURE_DIAGNOSTIC = SRC / 'scripts/make-texture-diagnostic-pck.py'
COMPAT_PROJECT = SRC / 'STS2LinuxLauncher/STS2LinuxLauncher.csproj'
PATCH_PROJECT = HERE / 'dll_surgery/official_runtime/official_runtime.csproj'
REPO = HERE.parents[3]


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def regular(path, label):
    if not path: raise ValueError(label + ' not found; supply its explicit path')
    p = Path(path).resolve(strict=True)
    if not p.is_file(): raise ValueError(label + ' must be a regular file: ' + str(p))
    return p


def run(command, env=None, capture=False):
    print('+ ' + shlex.join(map(str, command)), flush=True)
    if capture:
        result = subprocess.run(list(map(str, command)), env=env, capture_output=True, text=True)
        print(result.stdout, end='', flush=True)
        if result.stderr: print(result.stderr, end='', file=sys.stderr, flush=True)
        result.check_returncode()
        return result.stdout
    subprocess.run(list(map(str, command)), check=True, env=env)


def source_identities(profile=PROFILE):
    selected = [profile, Path(__file__).resolve(), SCAN, SHADER_SCAN, TEXTURE, MERGE, OVERLAY,
                SRC/'scripts/make-overlay-pck.py', SRC/'scripts/simple_effects_specs.py',
                SRC/'scripts/simple_effects_inventory.json', SRC/'scripts/turbulence_specs.json', SRC/'scripts/global_material_policy.py',
                HERE/'godot_pck/low_texture_worker.gd', SRC.parent/'love/vulkan-trial.sh.template']
    if profile == WINDOWS_PROFILE:
        selected.extend([WINDOWS_TEXTURE, WINDOWS_PREPARE, HERE/'godot_pck/windows_texture_worker.gd', SRC/'scripts/windows_runtime_resources.py', HERE/'device_tools/runtime_baseline_v110.json',
                         TEXTURE_DIAGNOSTIC, HERE/'godot_pck/combine_restored_texture.py', HERE/'godot_pck/restore_vram_texture.py',
                         HERE/'godot_pck/restore_vram_texture_inventory.py', HERE/'godot_pck/scan_memory_candidates.py',
                         HERE/'godot_pck/merge_font_cache.py', HERE/'godot_pck/strip_font_cache.py', HERE/'godot_pck/strip_font_cache.gd',
                         HERE/'godot_pck/merge_common_font_cache.py', HERE/'godot_pck/strip_common_font_cache.py', HERE/'godot_pck/strip_common_font_cache.gd',
                         HERE/'godot_pck/merge_quarter_texture.py', HERE/'godot_pck/quarter_texture_overlay.py', HERE/'godot_pck/quarter_texture_worker.gd',
                         HERE/'godot_pck/merge_refined_quarter.py', HERE/'godot_pck/refine_quarter_texture.py', HERE/'godot_pck/refine_quarter_texture.gd', HERE/'godot_pck/refine_quarter_astc.cpp',
                         HERE/'assemble_release_743.py', HERE/'assemble_two_language_delivery.py',
                         HERE/'godot_pck/merge_font_budget_trial.py', HERE/'godot_pck/font_budget_trial.py', HERE/'godot_pck/font_budget_trial.gd',
                         HERE/'assemble_mono_subset_delivery.py', HERE/'godot_pck/merge_mono_subset_trial.py', HERE/'godot_pck/subset_mono_font.py',
                         HERE/'godot_pck/subset_mono_font.gd', HERE/'godot_pck/subset_mono_font_worker.py', HERE/'godot_pck/subset_mono_uid_fixture.gd', HERE/'godot_pck/font_fallback_trial.py',
                         HERE/'godot_pck/restore_vram_texture_worker.gd', SRC/'scripts/vram_texture_specs.json',
                         REPO/'_kit/assemble.sh', REPO/'_kit/portmaster_bootstrap.sh', REPO/'_kit/launcher_platform.sh', SRC.parent/'manifest.json'])
        selected.extend(p for p in (SRC/'texture_diagnostics').rglob('*') if p.is_file() and p.suffix in ('.gd', '.tscn'))
    selected.extend((HERE/'device_tools').glob('*.py'))
    for directory in (COMPAT_PROJECT.parent, PATCH_PROJECT.parent, SRC/'rendering',
                      SRC/'shaders', REPO/'_kit/godot/addons/portkit_performance'):
        selected.extend(p for p in directory.rglob('*') if p.is_file() and not any(part in ('bin','obj','__pycache__') for part in p.parts)
                        and p.suffix in ('.cs', '.csproj', '.props', '.gd', '.tscn', '.tres', '.gdshader', '.json'))
    return {str(p.relative_to(REPO)): sha(p) for p in sorted(set(selected))}


def build(args):
    profile_path = getattr(args, '_profile_path', PROFILE)
    profile = json.loads(profile_path.read_text())
    windows = profile.get('texture_mode') == 'windows-bc-to-astc'
    source = regular(args.source_pck, 'source PCK')
    game = regular(args.game_dll, 'game DLL')
    deps = regular(args.game_deps, 'game deps')
    godot = regular(args.godot, 'Godot')
    dotnet = regular(args.dotnet, 'dotnet')
    reference = Path(args.reference_dir).resolve(strict=True)
    harmony = regular(reference/'0Harmony.dll', 'Harmony reference')
    reference_game = regular(reference/'sts2.dll', 'game reference')
    output = Path(args.output_dir).resolve()
    if output.exists(): raise ValueError('output directory already exists; choose a fresh private directory')
    if any(output == x or output in x.parents for x in (source, game, deps, godot, dotnet, harmony, reference_game)):
        raise ValueError('output directory cannot contain an input')
    if bool(args.reuse_verified_texture) != bool(args.reuse_texture_report):
        raise ValueError('reuse requires both texture PCK and its original report')
    reuse = regular(args.reuse_verified_texture, 'texture overlay') if args.reuse_verified_texture else None
    reuse_report = regular(args.reuse_texture_report, 'texture report') if args.reuse_texture_report else None
    delta_arg, delta_report_arg = getattr(args, 'restore_delta', None), getattr(args, 'restore_report', None)
    if bool(delta_arg) != bool(delta_report_arg) or (delta_arg and (not windows or not reuse)):
        raise ValueError('restoration requires Windows build, verified base texture and both delta and report')
    delta = regular(delta_arg, 'restoration delta') if delta_arg else None
    delta_report = regular(delta_report_arg, 'restoration report') if delta_report_arg else None
    font_arg, font_report_arg = getattr(args, 'font_delta', None), getattr(args, 'font_report', None)
    if bool(font_arg) != bool(font_report_arg) or (font_arg and (not windows or not delta)):
        raise ValueError('font restoration requires Windows build, verified texture restoration and both font delta and report')
    font_delta = regular(font_arg, 'font delta') if font_arg else None
    font_report = regular(font_report_arg, 'font report') if font_report_arg else None
    common_arg, common_report_arg = getattr(args, 'common_font_delta', None), getattr(args, 'common_font_report', None)
    if bool(common_arg) != bool(common_report_arg) or (common_arg and not font_delta):
        raise ValueError('common font restoration requires the three-font restoration and both common inputs')
    common_delta = regular(common_arg, 'common font delta') if common_arg else None
    common_report = regular(common_report_arg, 'common font report') if common_report_arg else None
    quarter_arg, quarter_report_arg = getattr(args, 'quarter_delta', None), getattr(args, 'quarter_report', None)
    if bool(quarter_arg) != bool(quarter_report_arg) or (quarter_arg and not common_delta):
        raise ValueError('quarter restoration requires common font restoration and both quarter inputs')
    quarter_delta = regular(quarter_arg, 'quarter delta') if quarter_arg else None
    quarter_report = regular(quarter_report_arg, 'quarter report') if quarter_report_arg else None
    if quarter_delta and any(output == x or output in x.parents for x in (quarter_delta, quarter_report)):
        raise ValueError('output directory cannot contain quarter inputs')
    if common_delta and any(output == x or output in x.parents for x in (common_delta, common_report)):
        raise ValueError('output directory cannot contain common font inputs')
    if font_delta and any(output == x or output in x.parents for x in (font_delta, font_report)):
        raise ValueError('output directory cannot contain font inputs')
    if delta and any(output == x or output in x.parents for x in (delta, delta_report)):
        raise ValueError('output directory cannot contain restoration inputs')
    if reuse and any(output == x or output in x.parents for x in (reuse, reuse_report)):
        raise ValueError('output directory cannot contain reuse inputs')
    inputs = {'source_pck': sha(source), 'game_dll': sha(game), 'game_deps': sha(deps), 'harmony': sha(harmony), 'game_reference': sha(reference_game)}
    versions = {'godot': subprocess.run([str(godot), '--version'], check=True, capture_output=True, text=True).stdout.strip(),
                'dotnet': subprocess.run([str(dotnet), '--version'], check=True, capture_output=True, text=True).stdout.strip()}
    sources = source_identities(profile_path)
    if not versions['godot'].startswith('4.5.1.stable.official'): raise ValueError('official Godot 4.5.1 required')
    if not versions['dotnet'].startswith('9.'): raise ValueError('.NET SDK 9 required')
    if inputs['game_reference'] != inputs['game_dll']: raise ValueError('reference sts2.dll differs from game input')
    commands = {'scan': [sys.executable, SCAN, '--base', source, '--output-dir', output/'scan'],
                'shader_scan': [sys.executable, SHADER_SCAN, '--base', source, '--output-dir', output/'shader-scan'],
                'compat_overlay': [sys.executable, OVERLAY, '--source-pck', source, '--smooth', '--output', output/'port_compat.pck', '--report', output/'compat-report.json']}
    if windows:
        commands['texture_diagnostic'] = [sys.executable, TEXTURE_DIAGNOSTIC, '--source-pck', source,
                                          '--texture-report', output/'texture-report.json', '--output', output/'texture_diagnostic.pck']
    print('Input identities: ' + json.dumps(inputs), flush=True)
    if args.plan:
        print('Plan (no output or device writes):')
        for name, cmd in commands.items(): print(name + ': ' + shlex.join(map(str, cmd)))
        print('Spine candidates: ' + ('include with unverified binary identity override' if args.allow_unverified_spine_binary else 'preserve original textures'))
        print('Then: verify/build texture overlay, build compat and Cecil, patch ARM64 DLL, merge texture PCK, write reports and immutable four-file manifest.')
        return
    output.mkdir(parents=True)
    run(commands['scan'])
    run(commands['shader_scan'])
    unsupported = {k: {'expected': profile[k + '_sha256'], 'actual': inputs[k]} for k in ('source_pck', 'game_dll', 'game_deps') if inputs[k] != profile[k + '_sha256']}
    if unsupported:
        (output/'unsupported-input.json').write_text(json.dumps({'reason':'input identity differs; audit scanner output and IL before adopting a new build', 'differences':unsupported}, indent=2)+'\n')
        raise ValueError('unsupported game input identity; see scan and unsupported-input.json')
    run(commands['compat_overlay'])
    if reuse:
        t = json.loads(reuse_report.read_text())
        encoder = hashlib.sha256((sha(godot)+(sha(HERE/'godot_pck/windows_texture_worker.gd') if windows else '')+sha(HERE/'godot_pck/low_texture_worker.gd')+sha(WINDOWS_TEXTURE if windows else TEXTURE)).encode()).hexdigest()
        if (t.get('source_sha256') != inputs['source_pck'] or t.get('output_sha256') != sha(reuse) or
            t.get('verified_spine_loader') is not args.allow_unverified_spine_binary or
            t.get('encoder_sha256') != encoder or t.get('godot') != versions['godot']):
            raise ValueError('reused texture and report do not match source, encoder, or explicit Spine setting')
        texture, texture_report = output/'texture-low.pck', output/'texture-report.json'
        shutil.copyfile(reuse, texture); shutil.copyfile(reuse_report, texture_report)
        if sha(texture) != t['output_sha256'] or json.loads(texture_report.read_text()) != t:
            raise ValueError('copied texture or report changed')
        if delta:
            run([sys.executable, HERE/'godot_pck/combine_restored_texture.py', '--source', source,
                 '--base', texture, '--base-report', texture_report, '--delta', delta,
                 '--delta-report', delta_report, '--specs', SRC/'scripts/vram_texture_specs.json',
                 '--output-dir', output/'texture-restoration'])
            texture_report = output/'texture-restoration/report.json'
            combined = json.loads(texture_report.read_text())
            texture = output/'texture-restoration/packs'/(combined['output_sha256']+'.pck')
    else:
        texture, texture_report = output/'texture-low.pck', output/'texture-report.json'
        cache = Path(args.texture_cache).resolve() if args.texture_cache else output/'texture-cache'
        command = [sys.executable, WINDOWS_TEXTURE if windows else TEXTURE, '--base', source, '--godot', godot, '--cache', cache, '--output', texture,
                   '--report', texture_report]
        if windows: command.extend(['--expected-source-sha256', inputs['source_pck']])
        if args.allow_unverified_spine_binary: command.append('--allow-spine-half' if windows else '--verified-spine-loader')
        run(command)
    if windows:
        run([sys.executable, TEXTURE_DIAGNOSTIC, '--source-pck', source,
             '--texture-report', texture_report, '--output', output/'texture_diagnostic.pck'])
    env = os.environ.copy()
    env['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
    env['DOTNET_ROOT'] = str(dotnet.parent)
    offline = output/'NuGet.Config'
    offline.write_text('<configuration><packageSources><clear/></packageSources></configuration>')
    common = ['-c', 'Release', '--nologo', '-v:q', '-p:NuGetAudit=false', '-p:DebugType=none',
              '-p:DebugSymbols=false', '-p:RestoreConfigFile='+str(offline)]
    if args.nuget_cache: env['NUGET_PACKAGES'] = str(Path(args.nuget_cache).resolve())
    for project, name in ((COMPAT_PROJECT, 'compat'), (PATCH_PROJECT, 'tool')):
        staged = output/(name+'-source')
        shutil.copytree(project.parent, staged, ignore=shutil.ignore_patterns('obj', 'bin'))
        compat_args = ['-p:CompatReferenceDir='+str(reference)] if name == 'compat' else []
        if windows and name == 'compat':
            compat_args.append('-p:TextureDiagnosticPck='+str(output/'texture_diagnostic.pck'))
        run([dotnet, 'build', staged/project.name, *common, '-p:OutDir='+str(output/name)+'/', *compat_args], env)
    if windows:
        diagnostic_verified = json.loads(run([dotnet, output/'tool/official_runtime.dll', 'verify-texture-diagnostic',
                                             output/'compat/sts2_compat.dll', output/'texture_diagnostic.pck'], env, capture=True))
        if diagnostic_verified.get('sha256') != sha(output/'texture_diagnostic.pck'):
            raise ValueError('embedded texture diagnostic identity mismatch')
    input_dir = output/'game-input'; input_dir.mkdir()
    shutil.copyfile(game, input_dir/'sts2.dll'); shutil.copyfile(deps, input_dir/'sts2.deps.json')
    release = getattr(args, '_release_info', None)
    if windows:
        if release is None or sha(release) != profile['release_info_sha256']:
            raise ValueError('release info does not match the audited Windows input')
        shutil.copyfile(release, input_dir/'release_info.json')
    if sha(input_dir/'sts2.dll') != inputs['game_dll'] or sha(input_dir/'sts2.deps.json') != inputs['game_deps']:
        raise ValueError('game inputs changed while staging')
    # Cecil resolves signatures from the input directory when rewriting. Stage
    # the player's reference DLLs, never the already-injected compatibility DLL.
    for folder in (reference, game.parent):
        for library in sorted(folder.glob('*.dll')):
            if library.name in ('sts2.dll', 'sts2_compat.dll'): continue
            dest = input_dir/library.name
            if dest.exists():
                if sha(dest) != sha(library): raise ValueError('conflicting reference DLL: '+library.name)
            else:
                shutil.copyfile(library, dest)
    inputs['reference_dependencies'] = {p.name: sha(p) for p in sorted(input_dir.glob('*.dll')) if p.name != 'sts2.dll'}
    material_audit = json.loads(run([dotnet, output/'tool/official_runtime.dll', 'inspect-vfx-material-usage', input_dir/'sts2.dll'], env, capture=True))
    (output/'vfx-material-audit.json').write_text(json.dumps(material_audit, indent=2)+'\n')
    if material_audit['source_sha256'] != inputs['game_dll'] or material_audit['turbulence_flag_accesses']:
        raise ValueError('VFX turbulence access requires manual review; see vfx-material-audit.json')
    patched = output/'patched'; patched.mkdir()
    verification = run([dotnet, output/'tool/official_runtime.dll', 'patch', input_dir/'sts2.dll', output/'compat/sts2_compat.dll', patched/'sts2.dll'], env, capture=True)
    (output/'patch-verification.txt').write_text(verification)
    base_merge_dir = output/('font-base-merged' if font_delta else 'merged')
    merge_command = [sys.executable, MERGE, '--source', source, '--overlay', texture, '--report', texture_report, '--output-dir', base_merge_dir]
    if windows: merge_command += ['--compat', output/'port_compat.pck', '--compat-report', output/'compat-report.json']
    run(merge_command)
    packs = list(base_merge_dir.glob('*.pck'))
    if len(packs) != 1: raise ValueError('expected exactly one merged PCK')
    font_provenance = None
    if font_delta:
        shutil.copyfile(font_delta, output/'font-delta.pck'); shutil.copyfile(font_report, output/'font-report.json')
        run([sys.executable,HERE/'godot_pck/merge_font_cache.py','--source',source,'--base',packs[0],
             '--delta',output/'font-delta.pck','--report',output/'font-report.json','--godot',godot,
             '--output-dir',output/'font-merge'])
        font_provenance=json.loads((output/'font-merge/report.json').read_text())
        merged=output/'merged';merged.mkdir()
        f=output/'font-merge/packs'/(font_provenance['merged_sha256']+'.pck')
        f.replace(merged/f.name);f.with_suffix('.json').replace(merged/(f.stem+'.json'))
        packs=[merged/f.name]
    common_provenance = None
    if common_delta:
        shutil.copyfile(common_delta, output/'common-font-delta.pck'); shutil.copyfile(common_report, output/'common-font-report.json')
        base = output/'common-font-base-merged'; (output/'merged').rename(base)
        previous = base/(font_provenance['merged_sha256']+'.pck')
        run([sys.executable,HERE/'godot_pck/merge_common_font_cache.py','--source',source,'--base',previous,
             '--delta',output/'common-font-delta.pck','--report',output/'common-font-report.json','--godot',godot,
             '--output-dir',output/'common-font-merge'])
        common_provenance=json.loads((output/'common-font-merge/report.json').read_text())
        merged=output/'merged';merged.mkdir()
        f=output/'common-font-merge/packs'/(common_provenance['merged_sha256']+'.pck')
        f.replace(merged/f.name);f.with_suffix('.json').replace(merged/(f.stem+'.json'))
        packs=[merged/f.name]
    quarter_provenance = None
    if quarter_delta:
        shutil.copyfile(quarter_delta, output/'quarter-delta.pck'); shutil.copyfile(quarter_report, output/'quarter-report.json')
        base = output/'quarter-base-merged'; (output/'merged').rename(base)
        previous = base/(common_provenance['merged_sha256']+'.pck')
        run([sys.executable,HERE/'godot_pck/merge_quarter_texture.py','--source',source,'--base',previous,'--texture-report',texture_report,
             '--delta',output/'quarter-delta.pck','--delta-report',output/'quarter-report.json','--godot',godot,'--output-dir',output/'quarter-merge'])
        quarter_provenance=json.loads((output/'quarter-merge/report.json').read_text())
        merged=output/'merged';merged.mkdir()
        f=output/'quarter-merge/packs'/(quarter_provenance['merged_sha256']+'.pck')
        f.replace(merged/f.name);f.with_suffix('.json').replace(merged/(f.stem+'.json'))
        packs=[merged/f.name]
    entry = output/'vulkan-entry.sh'
    if windows:
        run([REPO/'_kit/assemble.sh', SRC.parent/'love/vulkan-trial.sh.template', entry])
    bundle = output/'patch'; bundle.mkdir()
    for name, path in {'sts2.dll':patched/'sts2.dll', 'sts2.deps.json':patched/'sts2.deps.json',
                       'sts2_compat.dll':output/'compat/sts2_compat.dll', 'port_compat.pck':output/'port_compat.pck'}.items():
        shutil.copyfile(path, bundle/name)
    manifest = {'files':{n:sha(bundle/n) for n in sorted(('sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck'))},
                'source_files':{'sts2.dll':inputs['game_dll'],'sts2.deps.json':inputs['game_deps']}}
    raw = (json.dumps(manifest, indent=2)+'\n').encode(); (bundle/'manifest.json').write_bytes(raw)
    t = json.loads(texture_report.read_text()); c = json.loads((output/'compat-report.json').read_text())
    if source_identities(profile_path) != sources: raise ValueError('build sources changed during execution; use a fresh output directory')
    report = {'profile':profile, 'input_sha256':inputs, 'game_version_metadata':json.loads(release.read_text()) if release else 'missing or not supplied; input identified by hashes',
              'spine_binary_identity_verified':False, 'spine_override_acknowledged':args.allow_unverified_spine_binary,
              'tool_versions':versions, 'tool_sha256':{'godot':sha(godot),'dotnet':sha(dotnet),'texture_builder':sha(TEXTURE),'merge':sha(MERGE),'overlay_builder':sha(OVERLAY),'scanner':sha(SCAN)},
              'build_source_sha256':sources, 'patch_verification':verification.splitlines(),
              'vfx_material_audit':material_audit,
              'texture':{k:v for k,v in t.items() if k != 'resources'}, 'compatibility':c,
              'shader_scan_report':str(output/'shader-scan/shader-features.json'),
              'patch_manifest_sha256':hashlib.sha256(raw).hexdigest(), 'patch_files':manifest['files'],
              'merged_sha256':packs[0].stem, 'merged_bytes':packs[0].stat().st_size,
              'font_restoration':font_provenance, 'common_font_restoration':common_provenance, 'quarter_restoration':quarter_provenance,
              'entry_sha256':sha(entry) if windows else None,
              'texture_report':str(texture_report), 'texture_overlay':str(texture),
              'reproduce_command':shlex.join(sys.argv), 'device_deployed':False}
    if windows:
        report['texture_diagnostic'] = {**diagnostic_verified, 'embedded_in':'sts2_compat.dll',
                                        'bridge_default':'off', 'trial_entry_default':'off'}
        if quarter_provenance:
            report['texture_diagnostic']['candidate_identity_scope'] = ('The candidate paths are indexed from the pre-quarter texture overlay; '
                'the quarter delta changes texture contents at existing paths. Runtime format and dimensions come from the live renderer.')
            report['texture_diagnostic']['quarter_delta_sha256'] = quarter_provenance['delta_sha256']
    (output/'build-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print('Build complete: '+str(output/'build-report.json'))


def build_windows(args):
    profile = json.loads(WINDOWS_PROFILE.read_text())
    root = Path(args.windows_game_dir).resolve(strict=True)
    source = regular(root/'SlayTheSpire2.pck', 'Windows source PCK')
    data = (root/'data_sts2_windows_x86_64').resolve(strict=True)
    release = regular(root/'release_info.json', 'Windows release info')
    output = Path(args.output_dir).resolve()
    if output.exists() or any(output == p or output in p.parents for p in (root, source, release)):
        raise ValueError('Windows build output must be new and cannot contain input')
    if sha(source) != profile['source_pck_sha256'] or sha(release) != profile['release_info_sha256']:
        raise ValueError('Windows PCK or release info differs from audited profile')
    if sha(regular(args.linux_godotsharp, 'Linux GodotSharp')) != profile['linux_godotsharp_sha256']:
        raise ValueError('Linux GodotSharp differs from audited runtime')
    if sha(regular(args.linux_runtime_deps, 'Linux runtime deps')) != profile['linux_runtime_deps_sha256']:
        raise ValueError('Linux runtime dependency identity differs from audited baseline')
    command = [sys.executable, WINDOWS_PREPARE, '--windows-dir', data, '--dll-sha256', profile['windows_dll_sha256'],
               '--deps-sha256', profile['windows_deps_sha256'], '--linux-runtime-deps', args.linux_runtime_deps,
               '--linux-godotsharp', args.linux_godotsharp, '--release-info', release, '--output-dir', output/'prepared']
    if args.plan:
        print('Plan (no output or device writes): ' + shlex.join(map(str, command)))
        if bool(args.restore_delta) != bool(args.restore_report) or (args.restore_delta and not (args.reuse_verified_texture and args.reuse_texture_report)):
            raise ValueError('restoration requires verified base texture and both delta and report')
        if bool(args.font_delta) != bool(args.font_report) or (args.font_delta and not args.restore_delta):
            raise ValueError('font restoration requires texture restoration and both font delta and report')
        if bool(args.common_font_delta) != bool(args.common_font_report) or (args.common_font_delta and not args.font_delta):
            raise ValueError('common font restoration requires both common inputs and the three-font restoration')
        if bool(args.quarter_delta) != bool(args.quarter_report) or (args.quarter_delta and not args.common_font_delta):
            raise ValueError('quarter restoration requires common font restoration and both quarter inputs')
        if args.restore_delta:
            print('Then verify the source-bound ASTC delta against the audited candidate specification and combine it with the verified base texture.')
        print('Then scan, convert BC textures and import maps, build audited compatibility, patch managed DLL and merge both overlays before Godot starts.')
        return
    run(command)
    args.source_pck = source
    args.game_dll = output/'prepared/sts2.dll'
    args.game_deps = output/'prepared/sts2.deps.json'
    args.reference_dir = output/'prepared'
    args.output_dir = output/'build'
    args._profile_path = WINDOWS_PROFILE
    args._release_info = release
    build(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    s = sub.add_parser('scan', help='scan a player PCK without modifying it')
    s.add_argument('--source-pck', required=True, type=Path); s.add_argument('--output-dir', required=True, type=Path)
    b = sub.add_parser('build', help='build the supported handheld-low profile')
    for arg in ('source-pck','game-dll','game-deps','reference-dir','output-dir'):
        b.add_argument('--'+arg, required=True, type=Path)
    local_tools = REPO/'.cache/sts2-vulkan-trial/build-tools'
    discovered_godot = shutil.which('godot') or (local_tools/'godot-4.5.1-macos/Godot.app/Contents/MacOS/Godot' if (local_tools/'godot-4.5.1-macos/Godot.app/Contents/MacOS/Godot').is_file() else None)
    discovered_dotnet = shutil.which('dotnet') or (local_tools/'dotnet/dotnet' if (local_tools/'dotnet/dotnet').is_file() else None)
    b.add_argument('--godot', type=Path, default=discovered_godot)
    b.add_argument('--dotnet', type=Path, default=discovered_dotnet)
    b.add_argument('--texture-cache', type=Path); b.add_argument('--nuget-cache', type=Path)
    b.add_argument('--reuse-verified-texture', type=Path); b.add_argument('--reuse-texture-report', type=Path)
    b.add_argument('--allow-unverified-spine-binary', action='store_true', help='include Spine textures despite the installed binary not being bound to the audited loader source')
    b.add_argument('--plan', action='store_true', help='show plan without output writes or device access')
    w = sub.add_parser('build-windows', help='prepare and build the audited Windows v0.110.1 input')
    for name in ('windows-game-dir','linux-runtime-deps','linux-godotsharp','output-dir'):
        w.add_argument('--'+name, required=True, type=Path)
    w.add_argument('--godot', type=Path, default=discovered_godot)
    w.add_argument('--dotnet', type=Path, default=discovered_dotnet)
    w.add_argument('--texture-cache', type=Path); w.add_argument('--nuget-cache', type=Path)
    w.add_argument('--reuse-verified-texture', type=Path); w.add_argument('--reuse-texture-report', type=Path)
    w.add_argument('--restore-delta', type=Path); w.add_argument('--restore-report', type=Path)
    w.add_argument('--font-delta', type=Path); w.add_argument('--font-report', type=Path)
    w.add_argument('--common-font-delta', type=Path); w.add_argument('--common-font-report', type=Path)
    w.add_argument('--quarter-delta', type=Path); w.add_argument('--quarter-report', type=Path)
    w.add_argument('--allow-unverified-spine-binary', action='store_true')
    w.add_argument('--plan', action='store_true')
    d = sub.add_parser('deploy', help='explicitly install a completed build to a specified device')
    for name in ('target','device-root','device-source-pck','device-game-dir','device-entry','entry-sha256','build-dir','state-dir'):
        d.add_argument('--'+name, required=True)
    d.add_argument('--plan', action='store_true', help='validate locally without contacting the device')
    d.add_argument('--allow-unverified-spine-binary', action='store_true', help='explicitly accept the unverified Spine binary identity')
    d.add_argument('--reuse-main', action='store_true', help='require and reuse the matching installed main PCK; never upload or merge textures')
    wd = sub.add_parser('deploy-windows', help='install one audited v0.110.1 bundle with a single selector')
    for name in ('target','device-root','device-original','device-entry','old-entry-sha256','build-dir','state-dir'):
        wd.add_argument('--'+name, required=True)
    wd.add_argument('--plan', action='store_true')
    wd.add_argument('--allow-unverified-spine-binary', action='store_true')
    wd.add_argument('--replace-build', help='require an active build and reuse its identical main pack locally')
    wd.add_argument('--restore-delta'); wd.add_argument('--restore-report')
    wd.add_argument('--font-delta'); wd.add_argument('--font-report')
    wd.add_argument('--common-font-delta'); wd.add_argument('--common-font-report')
    wd.add_argument('--quarter-delta'); wd.add_argument('--quarter-report')
    args = parser.parse_args()
    try:
        if args.command == 'scan': run([sys.executable, SCAN, '--base', args.source_pck, '--output-dir', args.output_dir])
        elif args.command == 'deploy':
            command = [sys.executable, HERE/'device_tools/install_handheld.py']
            for name in ('target','device_root','device_source_pck','device_game_dir','device_entry','entry_sha256','build_dir','state_dir'):
                command += ['--'+name.replace('_','-'), getattr(args,name)]
            if args.plan: command.append('--plan')
            if args.allow_unverified_spine_binary: command.append('--allow-unverified-spine-binary')
            if args.reuse_main: command.append('--reuse-main')
            run(command)
        elif args.command == 'deploy-windows':
            command = [sys.executable, HERE/'device_tools/install_v110.py']
            for name in ('target','device_root','device_original','device_entry','old_entry_sha256','build_dir','state_dir'):
                command += ['--'+name.replace('_','-'), getattr(args,name)]
            if args.plan: command.append('--plan')
            if args.allow_unverified_spine_binary: command.append('--allow-unverified-spine-binary')
            if args.replace_build: command.extend(['--replace-build',args.replace_build])
            if args.restore_delta: command.extend(['--restore-delta',args.restore_delta])
            if args.restore_report: command.extend(['--restore-report',args.restore_report])
            if args.font_delta: command.extend(['--font-delta',args.font_delta])
            if args.font_report: command.extend(['--font-report',args.font_report])
            if args.common_font_delta: command.extend(['--common-font-delta',args.common_font_delta])
            if args.common_font_report: command.extend(['--common-font-report',args.common_font_report])
            if args.quarter_delta: command.extend(['--quarter-delta',args.quarter_delta])
            if args.quarter_report: command.extend(['--quarter-report',args.quarter_report])
            run(command)
        elif args.command == 'build-windows': build_windows(args)
        else: build(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as exc:
        print('handheld optimization failed: '+str(exc),file=sys.stderr); return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
