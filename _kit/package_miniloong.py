#!/usr/bin/env python3
# INPUT:  显式的设备导出目录、传输校验记录、端口清单、7zz 与 Rudroid Release 审计工具
# OUTPUT: 无存档的 ports/<port>/dist 和无密码标准 PortMaster 7z
# POS:    将已验收迷你龙安装封装为可搬移发行包，不连接或启动设备
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

from build_info import stamp, unstamp

ROOT = Path(__file__).resolve().parents[1]
PORTS = {
    'vampiresurvivors114': ('Je-吸血鬼幸存者_114.sh', 'vampiresurvivors114'),
    'hk': ('Je-空洞骑士[中].sh', 'hollowknight'),
    'silksong': ('Je-空洞骑士_丝之歌[中].sh', 'silksong'),
    'heishenhua': ('Je-黑神话像素版[中].sh', 'heishenhua'),
    'terraria': ('Je-泰拉瑞亚[中].sh', 'terraria'),
    'pvz_portable_jenny': ('Je-植物大战僵尸年度版[中].sh', 'pvz_portable_jenny'),
    'sts2': ('Je-杀戮尖塔2[中].sh', 'sts2'),
}
FORBIDDEN = {'conf', 'userdata', 'Players', 'Worlds', 'default_players', 'cache',
             'cache32', 'cache64', 'UnityShaderCache', '__pycache__', '__MACOSX'}


def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 << 20), b''):
            result.update(block)
    return result.hexdigest()


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('unexpected installed launcher: ' + old[:100])
    return source.replace(old, new, 1)


def portable_sts2(data, source):
    source = replace_once(source, 'GAMEDIR=/roms/ports/sts2-vk-test',
                          'GAMEDIR="$JE_GAME_DIR/launcher-runtime"')
    source = replace_once(source, '/bin/bash /roms/ports/.sts2-v110-vulkan-handoff.sh',
                          '/bin/bash "$JE_GAME_DIR/launcher-runtime/handoff.sh"')
    source = replace_once(source, '      PROFILE="$GAMEDIR/conf/data"',
                          '''      JE_STS2_CONF="$GAMEDIR/conf"
      if [ -d "$JE_PACKAGE_DIR/sts2-vk-test/conf/data/SlayTheSpire2" ]; then
        JE_STS2_CONF="$JE_PACKAGE_DIR/sts2-vk-test/conf"
      fi
      export JE_STS2_CONF
      PROFILE="$JE_STS2_CONF/data"''')
    source = replace_once(source, '  [ -d "$GAMEDIR" ] && [ ! -L "$GAMEDIR" ] && [ -d "$PROFILE/SlayTheSpire2" ] || exit 1',
                          '  mkdir -p "$PROFILE/SlayTheSpire2" || exit 1\n  [ -d "$GAMEDIR" ] && [ ! -L "$GAMEDIR" ] && [ -d "$PROFILE/SlayTheSpire2" ] || exit 1')
    helper = data / 'launcher-runtime/bin/sts2_official_profile_v2.py'
    text = helper.read_text()
    text = replace_once(text, "pathlib.Path('/roms/ports/sts2-vk-test')",
                        "pathlib.Path(os.environ['JE_GAME_DIR'])/'launcher-runtime'")
    text = replace_once(text, "pathlib.Path('/roms/ports/PortMaster/libs/godot_4.5.mono.squashfs')",
                        "base/'runtime/godot_4.5.mono.squashfs'")
    helper.write_text(text)
    source = replace_once(source, '6afcaacb918d7bf76feb7ce9a8f4ef15f198147fa663df62f39738eb881c9512', sha256(helper))
    runner = data / 'launcher-runtime/handoff.sh'
    text = runner.read_text()
    text = replace_once(text, 'ORIGINAL="$SCRIPT_DIR/sts2"', 'ORIGINAL="$JE_GAME_DIR"')
    text = replace_once(text, 'TESTDIR="$SCRIPT_DIR/sts2-vk-test"', 'TESTDIR="$JE_GAME_DIR/launcher-runtime"')
    text = replace_once(text, 'RUNTIME_IMAGE="$controlfolder/libs/godot_4.5.mono.squashfs"',
                        'RUNTIME_IMAGE="$TESTDIR/runtime/godot_4.5.mono.squashfs"')
    text = text.replace('$TESTDIR/conf', '$JE_STS2_CONF')
    # Portable archives cannot retain a source filesystem's nanosecond mtimes.
    # Validate the same immutable bytes instead of weakening the content checks.
    text = replace_once(text,
        "if side!={'build_sha256':identity,'main_sha256':manifest['main_sha256'],'size':s.st_size,'mtime_ns':s.st_mtime_ns} or s.st_size!=manifest['main_bytes']:raise ValueError('main pack identity changed')",
        "if set(side)!={'build_sha256','main_sha256','size','mtime_ns'} or side['build_sha256']!=identity or side['main_sha256']!=manifest['main_sha256'] or side['size']!=s.st_size or s.st_size!=manifest['main_bytes'] or digest(main)!=manifest['main_sha256']:raise ValueError('main pack identity changed')")
    for message in ('runtime baseline changed: ', 'native extension changed: '):
        old = "if set(expected)!={'sha256','size','mtime_ns'} or {'size':st.st_size,'mtime_ns':st.st_mtime_ns}!={k:expected[k] for k in ('size','mtime_ns')}:raise ValueError('" + message + "'+name)"
        new = "if set(expected)!={'sha256','size','mtime_ns'} or st.st_size!=expected['size'] or digest(path)!=expected['sha256']:raise ValueError('" + message + "'+name)"
        text = replace_once(text, old, new)
    runner.write_text(text)
    return source


def add_exec_view(source, folder, unity):
    source = unstamp(source)
    source = ''.join(line for line in source.splitlines(keepends=True)
                     if line.strip() != '#@BUILD-LOG')
    source = source.split('\n', 1)[1]
    prefix = '''#!/bin/bash
# INPUT: 同目录游戏包与私有执行视图，不修改全局挂载或存档路径
# OUTPUT: 原设备启动流程和原退出状态
# POS: 迷你龙发行包入口；内部安装与资源保持相对布局
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH##*/}" = sh ]; then
    exec /bin/bash "$0" "$@"
fi
JE_PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
export JE_GAME_DIR="$JE_PACKAGE_DIR/FOLDER"
if [ "${JE_EXEC_READY:-}" != "$JE_GAME_DIR" ]; then
    export JE_EXEC_READY="$JE_GAME_DIR"
    exec python3 "$JE_GAME_DIR/bin/package-exec-view.py" --quiet --root "$JE_GAME_DIR" -- /bin/bash "$0" "$@"
fi
'''.replace('FOLDER', folder)
    if unity:
        prefix += 'export UNITY_RUNTIME_DIR="$JE_GAME_DIR/runtime"\n'
    prefix += '''if [ "${RUDROID_DIAGNOSTICS:-0}" = 1 ]; then
    :
#@BUILD-LOG
fi
'''
    return prefix + source


def privacy_check(dist, key):
    for path in dist.rglob('*'):
        parts = path.relative_to(dist).parts
        if path.is_symlink() or FORBIDDEN.intersection(parts):
            raise ValueError('player state/cache/link in export: ' + str(path))
        if path.is_file() and (path.name in {'state.txt', 'launch_config.env', 'registry.regemu'} or
                path.name.endswith(('.log', '.bak', '.save', '.sav', '.tmp')) or '.bak-' in path.name):
            raise ValueError('player state/log in export: ' + str(path))
        if key == 'terraria' and 'gamedata' in parts and path.is_file():
            raise ValueError('Terraria game resources are forbidden')
        if key == 'pvz_portable_jenny' and (path.name.lower() == 'main.pak' or 'properties' in parts):
            raise ValueError('PvZ game resources are forbidden')


def build(prepared, key, output, rudroid_scripts):
    entry, folder = PORTS[key]
    original = prepared / key
    receipt = json.loads((original / 'complete.json').read_text())
    source_files = {str(p.relative_to(original)): p for p in original.rglob('*')
                    if p.is_file() and p != original / 'complete.json'}
    if set(source_files) != set(receipt['sha256']):
        raise ValueError('export inventory changed: ' + key)
    for name, path in source_files.items():
        if path.is_symlink() or sha256(path) != receipt['sha256'][name]:
            raise ValueError('export checksum mismatch: ' + name)
    port = ROOT / 'ports' / key
    stage = port / ('.dist-stage.' + uuid.uuid4().hex)
    stage.mkdir()
    data = stage / folder
    shutil.copytree(original / folder, data)
    source = (original / entry).read_text()
    runtime = data / 'runtime'
    unity = key in ('vampiresurvivors114', 'hk', 'silksong', 'heishenhua', 'terraria')
    audit = []
    if unity:
        sys.path.insert(0, str(rudroid_scripts))
        from kit_markers import production_build_issue
        active_loader = runtime / 'unityloader'
        issue = production_build_issue(active_loader)
        if issue:
            raise ValueError(str(active_loader) + ': ' + issue)
        # Older installs retained an unused historical duplicate in the kit.
        # Ship the exact active Release loader in both names, without rebuilding
        # or changing the loader that the verified device entry actually uses.
        duplicate = runtime / 'rudroid.runtime/rudroid-unity-loader'
        if duplicate.exists() and production_build_issue(duplicate):
            shutil.copy2(active_loader, duplicate)
        for member in [active_loader, *sorted((runtime / 'rudroid.runtime').glob('*.so')), duplicate]:
            if not member.exists():
                continue
            issue = production_build_issue(member)
            if issue:
                raise ValueError(str(member) + ': ' + issue)
            audit.append(dict(file=str(member.relative_to(stage)), sha256=sha256(member), release=True))
    if key == 'sts2':
        source = portable_sts2(data, source)
    if key == 'pvz_portable_jenny' and (data / 'gameinfo.xml').is_file():
        info = data / 'gameinfo.xml'
        info.write_text(info.read_text().replace('Z_植物大战僵尸年度版[中].sh', entry))
    if key == 'terraria':
        (data / 'gamedata').mkdir(exist_ok=True)
        instructions = '将自备的合法泰拉瑞亚 Android APK 放入 terraria/gamedata/，首次启动自动准备。此包不含游戏资源、角色和世界存档。\n'
    elif key == 'pvz_portable_jenny':
        instructions = '将自备 GOTY 年度版的 main.pak 与 properties/ 放入 pvz_portable_jenny/。此包仅含维护版引擎和依赖，不含原版游戏资源或玩家存档。\n'
    else:
        instructions = '解压到迷你龙 Ports 目录，保持 Je- 启动 SH 与游戏目录同级，并安装 PortMaster。此包不含玩家存档、缓存和个人设置。\n'
    (data / '安装说明.txt').write_text(instructions)
    (data / 'bin').mkdir(exist_ok=True)
    shutil.copyfile(ROOT / '_kit/launch_exec_view.py', data / 'bin/package-exec-view.py')
    (stage / entry).write_text(add_exec_view(source, folder, unity))
    (stage / entry).chmod(0o755)
    manifest = json.loads((port / 'manifest.json').read_text())
    manifest.update(script=entry, port_dir=folder, portable_dir=folder)
    pm = manifest.setdefault('portmaster', {})
    items = [entry, folder]
    if (data / 'screenshot.png').is_file():
        picture = entry[:-3] + '.png'
        shutil.copyfile(data / 'screenshot.png', stage / picture)
        items.append(picture)
        pm.setdefault('attr', {})['image'] = {'screenshot': folder + '/screenshot.png', 'names': [picture]}
    pm['items'] = items
    manifest_file = stage / '.package-manifest.json'
    manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    subprocess.run([sys.executable, str(ROOT / '_kit/port_json.py'), str(manifest_file), str(stage), key], check=True)
    descriptor = stage / 'port.json'
    shutil.copyfile(descriptor, data / 'port.json')
    # The temporary build manifest is not part of the delivered file set.
    manifest_file.rename(output / ('.' + key + '-package-manifest.json'))
    manifest_file = output / ('.' + key + '-package-manifest.json')
    privacy_check(stage, key)
    identity = stamp(manifest_file, stage)
    identity['packaging'] = 'portmaster'
    (data / 'build-info.json').write_text(json.dumps(identity, ensure_ascii=False, indent=2) + '\n')
    subprocess.run(['/bin/bash', '-n', str(stage / entry)], check=True)
    if key == 'sts2':
        subprocess.run(['/bin/bash', '-n', str(data / 'launcher-runtime/handoff.sh')], check=True)
        compile((data / 'launcher-runtime/bin/sts2_official_profile_v2.py').read_text(), 'profile-check', 'exec')
    destination = port / 'dist'
    if destination.exists():
        subprocess.run(['/usr/bin/trash', str(destination)], check=True)
    stage.rename(destination)
    archive = output / (entry[:-3] + '.7z')
    if archive.exists():
        raise ValueError('archive already exists: ' + str(archive))
    subprocess.run(['7zz', 'a', '-t7z', '-m0=lzma2', '-mx=3', '-mmt=2', '-ms=on',
                    str(archive), 'port.json', *items], cwd=destination, check=True,
                   stdout=subprocess.DEVNULL)
    return dict(port=key, archive=str(archive), bytes=archive.stat().st_size,
                sha256=sha256(archive), build=identity, saves_included=False,
                game_resources_included=key not in ('terraria', 'pvz_portable_jenny'),
                encrypted=False, release_audit=audit)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rudroid-scripts', type=Path, required=True)
    parser.add_argument('--port', choices=PORTS, required=True)
    args = parser.parse_args()
    args.output.mkdir(exist_ok=True, parents=True)
    result = build(args.prepared.resolve(), args.port, args.output.resolve(), args.rudroid_scripts.resolve())
    (args.output / ('.' + args.port + '-receipt.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))
