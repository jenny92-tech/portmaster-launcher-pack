#!/usr/bin/env python3
# INPUT: Explicit source-matched Release runtime and selected private game preparation.
# OUTPUT: One allowlisted private installation, preserving external player profiles.
# POS: Host-side assembly; never discovers keys or recursively collects an installation.
from pathlib import Path
import argparse,hashlib,json,re,shlex,shutil,subprocess,sys

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--implementation',type=Path,required=True)
    parser.add_argument('--private-game-root',type=Path,required=True)
    parser.add_argument('--resource-manifest',type=Path,required=True)
    parser.add_argument('--profile',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--gles-shaders',type=Path,required=True,help='Explicit complete prepared GLES bank')
    parser.add_argument('--portable-wayland',type=Path,help='Explicit audited Pack client bundle for TrimUI')
    args=parser.parse_args();implementation=args.implementation.resolve(strict=True);game=args.private_game_root.resolve(strict=True)
    if not args.profile.is_absolute() or '..' in args.profile.parts or any(c in str(args.profile) for c in '\0\r\n'):raise ValueError('Profile must be an explicit absolute device path')
    source=implementation/'dm/linux/soulknight_ns';sys.path.insert(0,str(source))
    from runtime_identity import production_identity
    binary=implementation/'dm/linux/out/soulknight_ns/soulknight-ns'
    identity=production_identity(binary.read_bytes())
    mapping={'runtime/soulknight-ns':binary}
    gles=implementation/'dm/linux/out/soulknight_ns_gles/soulknight-ns-gles'
    receipt=json.loads(gles.with_name('build-receipt.json').read_text())
    expected={'profile':'Release','kind':'linux-native-gles-experiment','title_id':identity['title_id'],'game_build':identity['game_build'],'source_revision':identity['source_revision']}
    marker=json.dumps(expected,separators=(',',':')).encode()+b'\0'
    if receipt['identity']!=expected or receipt['sha256']!=digest(gles) or gles.read_bytes().count(marker)!=1:
        raise ValueError('Rebuild matching GLES experiment runtime')
    mapping['runtime/soulknight-ns-gles']=gles
    gles_bank=args.gles_shaders.resolve(strict=True)
    report=json.loads((gles_bank/'gles-manifest.json').read_text())
    if report['programs']!=627 or report['offline_unsupported'] or report['source_index_sha256']!='f2c8d474611c3d0937976aab2a23a2281b595f19edf3de679afb0da22f8e8d19':
        raise ValueError('Incomplete or mismatched GLES shader bank')
    for f in gles_bank.iterdir():
        if f.name in ('shader_index.bin','gles-manifest.json') or re.fullmatch('[0-9a-f]{16}\.(?:glsl|glmeta|glfacts)',f.name):
            mapping['shaders-gles/'+f.name]=f
    if len([n for n in mapping if n.startswith('shaders-gles/')])!=1883:
        raise ValueError('Incomplete GLES stage payloads')
    resources=json.loads(args.resource_manifest.read_text())
    if (resources['title_id']!='0100a0800b83a000' or resources['file_count']!=298
        or not isinstance(resources.get('files'),dict) or len(resources['files'])!=298):raise ValueError('Wrong selected resource inventory')
    for relative,wanted in resources['files'].items():
        part=Path(relative)
        if part.is_absolute() or '..' in part.parts:raise ValueError('Unsafe resource path')
        p=game/'gamedata/RomFS'/part
        if digest(p)!=wanted:raise ValueError('Changed original resource '+relative)
        mapping['RomFS/'+relative]=p
    for name in ('main','subsdk0','sdk'):
        for suffix in ('patched.bin','fixups.tsv','gates.tsv'):mapping['native/'+name+'.'+suffix]=game/'native-linux'/(name+'.'+suffix)
    native={'main':'360363e1f2084e3b7500b651cbb6e5cc7fde52620cb96d0d8514ee4b041c4e8b','subsdk0':'6f1e7a94a0aa8bd1b440380ce539c0d050ad2c415367cb7dfd5c5a62594c3ac0','sdk':'3ffb331368792374b090ac0a04414f5deb72675a264d4ba7ec866ecd57bab267'}
    for name,wanted in native.items():
        if digest(mapping['native/'+name+'.patched.bin'])!=wanted:raise ValueError('Wrong native module '+name)
    for directory in ('shader-validated','shader-validated-builtins'):
        for p in (game/directory).iterdir():
            if re.fullmatch('[0-9a-f]{16}\.(?:vkmeta|spv\.gz)',p.name):mapping['shaders/'+p.name]=p
    mapping['shaders/shader_index.bin']=game/'shader-runtime-complete/shader_index.bin'
    if digest(mapping['shaders/shader_index.bin'])!='f2c8d474611c3d0937976aab2a23a2281b595f19edf3de679afb0da22f8e8d19':raise ValueError('Wrong 627-shader cache')
    if len([k for k in mapping if k.startswith('shaders/')])!=1255:raise ValueError('Incomplete shader payloads')
    for p in (game/'fonts').iterdir():
        if p.name in ('NotoSansCJKsc-Regular.otf','NotoSansCJK-LICENSE.txt'):mapping['fonts/'+p.name]=p
    if digest(mapping['fonts/NotoSansCJK-LICENSE.txt'])!='6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2':raise ValueError('Wrong shared font license')
    if digest(mapping['fonts/NotoSansCJKsc-Regular.otf'])!='2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b':raise ValueError('Wrong shared font')
    # Only the WSI library, its relative-path descriptor and recorded licenses.
    wsi=game/'runtime/vulkan-wsi'
    allowed=('libVkLayer_window_system_integration.so','VkLayer_window_system_integration.json','sources.json','LICENSE-WSI.txt','THIRD-PARTY-NOTICES-Rudroid.txt','LICENSE-MIT.txt','LICENSE-Vulkan-Headers.md','NOTICE-Rudroid.txt','LICENSE-Wayland-Protocols.txt','LICENSE-Rudroid.txt','LICENSE-Apache-2.0.txt')
    for name in allowed:mapping['runtime/vulkan-wsi/'+name]=wsi/name
    if digest(mapping['runtime/vulkan-wsi/libVkLayer_window_system_integration.so'])!='2b0084f9cf6f17d142d5c75b4900e82a30cafb1b7cfa75515024cb974025c58c':raise ValueError('Wrong verified WSI')
    port=Path(__file__).resolve().parents[1];repo=port.parents[1]
    mapping['libexec/soulknight-graphics-probe.sh']=port/'src/graphics-probe.sh'
    mapping['bin/graphics-probe']=repo/'_kit/runtime/graphics-probe.aarch64'
    probe_revision=digest(repo/'_kit/graphics_probe.c')
    if ((repo/'_kit/graphics-probe-revision.txt').read_text().strip()!=probe_revision
        or ('PORTKIT_GRAPHICS_PROBE Release '+probe_revision).encode() not in mapping['bin/graphics-probe'].read_bytes()):
        raise ValueError('Rebuild the source-matched Release graphics probe')
    if args.portable_wayland:
        clients=args.portable_wayland.resolve(strict=True)
        client_manifest=json.loads((clients/'manifest.json').read_text())
        if not {'libSDL2-2.0.so.0','libvulkan.so.1'}<=client_manifest['files'].keys():raise ValueError('Incomplete portable Wayland clients')
        for name,entry in client_manifest['files'].items():
            if Path(name).name!=name or name in ('.','..','manifest.json'):raise ValueError('Unsafe portable client name')
            path=clients/name
            if path.is_symlink() or not path.is_file() or path.stat().st_size!=entry['size'] or digest(path)!=entry['sha256']:raise ValueError('Changed portable client '+name)
            mapping['runtime/portable-wayland/'+name]=path
        mapping['runtime/portable-wayland/manifest.json']=clients/'manifest.json'
    if args.out.exists():raise ValueError('Output already exists; preserve or move the previous package first')
    stage=args.out.with_name(args.out.name+'.building')
    stage.mkdir(parents=True);data=stage/'soulknight_ns';data.mkdir()
    hashes={}
    for relative,p in mapping.items():
        if p.is_symlink() or not p.is_file():raise ValueError('Invalid explicit package input '+relative)
        target=data/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target);hashes[relative]=digest(target)
        if hashes[relative]!=digest(p):raise ValueError('Input changed during assembly '+relative)
    (data/'runtime/soulknight-ns').chmod(0o755)
    (data/'runtime/soulknight-ns-gles').chmod(0o755)
    (data/'bin/graphics-probe').chmod(0o755)
    shutil.copyfile(port/'README.md',data/'README.md');shutil.copyfile(implementation/'LICENSE',data/'runtime/LICENSE-MIT.txt')
    manifest={'title_id':identity['title_id'],'game_build':identity['game_build'],'runtime_identity':identity,'files':hashes,'profile':str(args.profile),'private_game_files':True}
    from unify import finalize_native
    finalize_native(stage,manifest,profile=str(args.profile))
    if production_identity(binary.read_bytes())!=identity:raise ValueError('Runtime source changed during assembly')
    stage.rename(args.out)
    print(json.dumps({'private_installation':str(args.out),'files':len(hashes),'runtime_identity':identity,'gameplay_verified':False},ensure_ascii=False))
if __name__=='__main__':main()
