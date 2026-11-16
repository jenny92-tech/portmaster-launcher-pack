#!/usr/bin/env python3
# INPUT: Explicit, verified installed package; device preset; optional audited Weston image.
# OUTPUT: Relocatable SH + game folder, without player profiles or diagnostic state.
# POS: Installed-byte export, not a runtime build or a current-source Release gate.
from pathlib import Path
import argparse,hashlib,json,shutil,struct,subprocess,sys

PORT=Path(__file__).resolve().parents[1]
REPO=PORT.parents[1]
sys.path.insert(0,str(REPO/'_kit'))
sys.path.insert(0,str(PORT/'src'))
from package_miniloong import privacy_check

ENTRY='Je-元气骑士_ns.sh'
TITLE='0100a0800b83a000'
BUILD='02242ae4e90dcf439210fe87f692de05'
WESTON_SHA='0bccaeebc11296bb1fe4278c9677cb82965c5a04bcd63745fa09d78228bc1a93'
# These exact installed entries were hash-checked on the two devices. Rebasing
# is intentionally limited to their audited layout, not arbitrary launch scripts.
LAUNCHER_SHA={'miniloong':'29c3d35b8d4d26c642d847b3cbe3743da79d370ef5f98262bee1e1932a345793',
              'trimui':'6e84bbf51e9cec6709ebc5cf18a49b727e1892b4bcd895a5ea96040d28cb5455'}
STATE={'save','identity','profile','profiles','cache','temp','logs','userdata','__pycache__'}
PROFILES={'miniloong':'/userdata/soulknight_ns/profile','trimui':'/mnt/UDISK/soulknight_ns/profile'}

def digest(path):
    h=hashlib.sha256()
    with path.open('rb')as f:
        for block in iter(lambda:f.read(4*1024*1024),b''):h.update(block)
    return h.hexdigest()

def installed_identity(data,kind='linux-native-vulkan'):
    if kind not in ('linux-native-vulkan','linux-native-gles-experiment'):raise ValueError('Unknown runtime kind')
    # Historical installed builds deliberately retain their embedded revision.
    # New builds still use runtime_identity.production_identity's live-source gate.
    if len(data)<64 or data[:7]!=b'\x7fELF\x02\x01\x01' or struct.unpack_from('<H',data,18)[0]!=183:
        raise ValueError('Installed runtime must be ARM64 ELF')
    offset=struct.unpack_from('<Q',data,40)[0];size,count,names=struct.unpack_from('<HHH',data,58)
    if size!=64 or not 0<count<=4096 or names>=count or offset+size*count>len(data):raise ValueError('Invalid installed ELF sections')
    sections=[struct.unpack_from('<IIQQQQIIQQ',data,offset+i*size)for i in range(count)]
    strings=sections[names]
    if strings[4]+strings[5]>len(data):raise ValueError('Invalid installed ELF names')
    strings=data[strings[4]:strings[4]+strings[5]];identity=None
    for section in sections:
        at=section[0]
        if at>=len(strings)or b'\0'not in strings[at:]:raise ValueError('Invalid installed ELF section name')
        name=strings[at:].split(b'\0',1)[0]
        if name==b'.symtab' or name.startswith((b'.debug',b'.zdebug')):raise ValueError('Debug runtime is not an installed Release')
        if name==b'.soulknight_build':
            if identity is not None or not 0<section[5]<=1024 or section[4]+section[5]>len(data):raise ValueError('Invalid installed build identity')
            identity=json.loads(data[section[4]:section[4]+section[5]].rstrip(b'\0'))
    if not isinstance(identity,dict)or (identity.get('profile'),identity.get('kind'),identity.get('title_id'),identity.get('game_build'))!=('Release',kind,TITLE,BUILD):
        raise ValueError('Wrong installed Release identity')
    return identity

def input_file(root,relative):
    p=Path(relative)
    if p.is_absolute()or '..'in p.parts or p.as_posix()!=relative or not p.parts or p.parts[0]in STATE:
        raise ValueError('Unsafe or player-state input: '+relative)
    path=root/p
    if not path.is_file()or any(x.is_symlink()for x in [path,*path.parents]if x!=root.parent):raise ValueError('Missing or linked input: '+relative)
    return path

def export(source,platform,out,image=None,probe=None,launcher=None):
    source=source.resolve(strict=True);data=source/'soulknight_ns'
    manifest_path=input_file(data,'installation.json');manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest['title_id']!=TITLE or manifest['game_build']!=BUILD:raise ValueError('Wrong game build')
    identity=installed_identity(input_file(data,'runtime/soulknight-ns').read_bytes())
    if identity!=manifest['runtime_identity']:raise ValueError('Installed identity does not match manifest')
    selected={}
    for relative,want in manifest['files'].items():
        path=input_file(data,relative)
        if digest(path)!=want:raise ValueError('Changed installed payload: '+relative)
        selected[relative]=path
    if platform=='trimui':
        if image is None or not image.is_file() or image.is_symlink() or digest(image)!=WESTON_SHA:raise ValueError('TrimUI needs the audited PortMaster Weston image')
        if 'runtime/portable-wayland/manifest.json' not in selected:raise ValueError('TrimUI portable Wayland clients are incomplete')
    entry=input_file(source,ENTRY)
    if digest(entry)!=LAUNCHER_SHA[platform]:raise ValueError('Installed launcher differs from the device-audited entry')
    if out.exists():raise ValueError('Export staging already exists')
    payload=out/'soulknight_ns';payload.mkdir(parents=True)
    retired={'libexec/launch.py','libexec/wayland-session.py','bin/package-exec-view.py','libexec/graphics-probe.sh','libexec/native-bootstrap.sh','bin/portkit-launcher.sha256','libexec/soulknight-graphics-probe.sh'}
    for relative,path in selected.items():
        if relative.startswith(('launcher','debug/','bin/portkit-debug')) or relative in retired:continue
        target=payload/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy(path,target)
    shutil.copyfile(input_file(data,'runtime/LICENSE-MIT.txt'),payload/'runtime/LICENSE-MIT.txt')
    if platform=='trimui':shutil.copyfile(image,payload/'runtime/weston_pkg_0.2.squashfs')
    from unify import finalize_native
    return finalize_native(out,manifest,probe,launcher,PROFILES[platform])

def main():
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--platform',choices=PROFILES,required=True);p.add_argument('--stage',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--weston-image',type=Path);a=p.parse_args()
    config=export(a.source,a.platform,a.stage,a.weston_image)
    subprocess.run([sys.executable,str(REPO/'_kit/port_zip.py'),str(config),str(a.stage),str(a.out)],check=True)
if __name__=='__main__':main()
