#!/usr/bin/env python3
# INPUT: Explicit prepared ZIP/manifest, source-matched Release and shared probe.
# OUTPUT: One capability-selected installation with a single runtime and no player data.
# POS: Host composition; graphics policy stays in _kit and the title adapter.
from pathlib import Path,PurePosixPath
import argparse,hashlib,json,stat,subprocess,sys,zipfile
from export import ENTRY,TITLE,BUILD,STATE,PORT,REPO,digest,installed_identity,privacy_check

def sha(data):return hashlib.sha256(data).hexdigest()

def relative(name):
    p=PurePosixPath(name)
    if not name or p.is_absolute() or '..' in p.parts or p.as_posix()!=name or '\\' in name or p.parts[0] in STATE:
        raise ValueError('Unsafe or player-state export path: '+name)
    return name

def compose(source,stage,manifest_name='installation.json',probe=None,launcher=None):
    if stage.exists():raise ValueError('Unified stage already exists')
    relative(manifest_name)
    if source.is_symlink() or not source.is_file():raise ValueError('Expected a regular prepared ZIP')
    if probe is None:
        probe=REPO/'_kit/runtime/graphics-probe.aarch64'
        revision=digest(REPO/'_kit/graphics_probe.c')
        raw=probe.read_bytes()
        if ((REPO/'_kit/graphics-probe-revision.txt').read_text().strip()!=revision
            or ('PORTKIT_GRAPHICS_PROBE Release '+revision).encode() not in raw
            or raw[:6]!=b'\x7fELF\x02\x01' or raw[18:20]!=b'\xb7\x00'):
            raise ValueError('Rebuild the source-matched Release graphics probe')
    with zipfile.ZipFile(source) as z:
        if len(set(z.namelist()))!=len(z.namelist()):raise ValueError('Duplicate ZIP entries')
        for info in z.infolist():
            relative(info.filename.rstrip('/'))
            if stat.S_ISLNK(info.external_attr>>16):raise ValueError('Linked ZIP entry')
        manifest=json.loads(z.read('soulknight_ns/'+manifest_name))
        if (manifest['title_id'],manifest['game_build'])!=(TITLE,BUILD):raise ValueError('Wrong game identity')
        files=manifest['files']
        if not isinstance(files,dict) or 'runtime/soulknight-ns' not in files:raise ValueError('Missing selected runtime')
        # Validate the entire explicit input before creating an output. Only
        # manifest-listed inputs are copied, never archive-wide player state.
        for name,wanted in files.items():
            relative(name)
            if sha(z.read('soulknight_ns/'+name))!=wanted:raise ValueError('Changed exported input: '+name)
        identity=installed_identity(z.read('soulknight_ns/runtime/soulknight-ns'))
        if identity!=manifest['runtime_identity']:raise ValueError('Wrong installed Release')
        gles_name='runtime/soulknight-ns-gles'
        expected=dict(identity,kind='linux-native-gles-experiment')
        if gles_name not in files or installed_identity(z.read('soulknight_ns/'+gles_name),'linux-native-gles-experiment')!=expected:
            raise ValueError('Unified settings require the matching GLES runtime')
        payload=stage/'soulknight_ns';payload.mkdir(parents=True)
        for name in files:
            if name.startswith(('launcher','debug/','bin/portkit-debug')) or name in {'libexec/launch.py','libexec/wayland-session.py','bin/package-exec-view.py','libexec/graphics-probe.sh','libexec/native-bootstrap.sh','bin/portkit-launcher.sha256','libexec/soulknight-graphics-probe.sh'}:continue
            out=payload/name;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(z.read('soulknight_ns/'+name))
            out.chmod((z.getinfo('soulknight_ns/'+name).external_attr>>16)&0o777)
        license_name='runtime/LICENSE-MIT.txt'
        (payload/license_name).write_bytes(z.read('soulknight_ns/'+license_name))
    return finalize_native(stage,manifest,probe,launcher)

def finalize_native(stage,manifest,probe=None,launcher=None,profile=None):
    payload=stage/"soulknight_ns"
    if probe is None:
        probe=REPO/"_kit/runtime/graphics-probe.aarch64"
        revision=digest(REPO/"_kit/graphics_probe.c")
        if ((REPO/"_kit/graphics-probe-revision.txt").read_text().strip()!=revision or ("PORTKIT_GRAPHICS_PROBE Release "+revision).encode() not in probe.read_bytes()):
            raise ValueError("Rebuild the source-matched Release graphics probe")
    mappings={
        'README.md':PORT/'README.md',
        'libexec/soulknight-graphics-probe.sh':PORT/'src/graphics-probe.sh',
        'bin/graphics-probe':probe,
    }
    for name,path in mappings.items():
        if path.is_symlink() or not path.is_file():raise ValueError('Missing shared helper: '+name)
        out=payload/name;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(path.read_bytes())
        out.chmod(0o755 if name=='bin/graphics-probe' else 0o644)
    subprocess.run(['bash',str(REPO/'_kit/stage_love_ui.sh'),str(payload/'love_ui')],check=True)
    (payload/'love_ui/main.lua').write_bytes((PORT/'love/main.lua').read_bytes())
    (payload/'libexec/soulknight-gles-graphics-probe.sh').write_bytes((PORT/'src/gles-graphics-probe.sh').read_bytes())
    if launcher is None:
        subprocess.run(['bash',str(REPO/'_kit/stage_portkit_launcher.sh'),str(payload)],check=True)
    else:
        # Explicit host-test fixture; production always uses the Release gate.
        target=payload/'bin/portkit-launcher';target.write_bytes(launcher.read_bytes());target.chmod(0o755)
    subprocess.run(['bash',str(REPO/'_kit/assemble.sh'),str(PORT/'src/launcher.sh'),str(payload/'launcher.sh')],check=True)
    (stage/ENTRY).write_bytes((PORT/'src/menu-entry.sh').read_bytes());(stage/ENTRY).chmod(0o755)
    (payload/'runtime/soulknight-ns').chmod(0o755)
    (payload/'runtime/soulknight-ns-gles').chmod(0o755)
    # Profile selection reuses an existing stable player location at runtime;
    # it never uses that storage location to select a GPU or display mode.
    manifest.update(profile=profile or '/userdata/soulknight_ns/profile',session=json.loads((PORT/'session.json').read_text()),files={
        p.relative_to(payload).as_posix():digest(p) for p in sorted(payload.rglob('*')) if p.is_file() and p.name!='installation.json'})
    (payload/'installation.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (payload/'安装说明.txt').write_text('元气骑士 NS 1.2.0 统一包\n需已安装 PortMaster；解压到 Ports，SH 与 soulknight_ns 同级。\n优先系统原生呈现，其次仅补 WSI；没有现成显示会话时，使用已实现接管/恢复的私有会话。不会替换系统 GPU 驱动。\n按实际逻辑显示尺寸选择 4:3 或 16:9；可用 --aspect 4:3 或 --aspect 16:9 覆盖。Select+Start 正常退出。\n不含存档、身份、缓存、日志。复用 /userdata/soulknight_ns/profile 或 /mnt/UDISK/soulknight_ns/profile 中已有档案；低内存文件后备需要 768 MiB 可用存储。\n通过预检不代表新机型已完成玩法验收。\n',encoding='utf-8')
    privacy_check(stage,'soulknight_ns')
    if any(p.suffix in {'.py','.pyc'}for p in payload.rglob('*')if p.is_file()):raise ValueError('Device payload must not require Python')
    if any('debug' in p.relative_to(payload).parts or p.name in {'native-bootstrap.sh','portkit-debug-launch','portkit-debug-launch.aarch64'} for p in payload.rglob('*') if p.is_file()):raise ValueError('Release payload must not contain debug launch tools')
    pm=json.loads((PORT/'manifest.json').read_text())
    pm['portmaster']={'zip_name':'Je-元气骑士_ns.zip','items':[ENTRY,'soulknight_ns'],'rtr':True,'exp':True,'desc':'NS 1.2.0；共享能力预检，按实际屏幕选择比例。','inst':'需已安装 PortMaster；解压到 Ports，SH 与游戏目录同级。'}
    config=stage/'.package-manifest.json';config.write_text(json.dumps(pm,ensure_ascii=False,indent=2)+'\n')
    subprocess.run([sys.executable,str(REPO/'_kit/port_json.py'),str(config),str(stage),'soulknight_ns'],check=True)
    for entry in [stage/ENTRY,payload/'launcher.sh']:subprocess.run(['/bin/bash','-n',str(entry)],check=True)
    return config

def main():
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--manifest',default='installation.json');p.add_argument('--stage',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    config=compose(a.source,a.stage,a.manifest)
    subprocess.run([sys.executable,str(REPO/'_kit/port_zip.py'),str(config),str(a.stage),str(a.out)],check=True)
if __name__=='__main__':main()
