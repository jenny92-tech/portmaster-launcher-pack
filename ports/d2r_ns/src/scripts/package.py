#!/usr/bin/env python3
# INPUT:  显式准备目录、端口源码、标准构建工具与可选 7-Zip/密码
# OUTPUT: 合并生效资源的无存档完整目录与可选文件名加密 7z
# POS:    D2R NS 私人资源包构建，不读取来源设备档案
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

PORT = Path(__file__).resolve().parents[2]
ROOT = PORT.parents[1]


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def regular_files(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('missing regular input directory: ' + str(root))
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('linked package input: ' + str(path))
        if path.is_file():
            if path.name in {'.env', 'prod.keys', 'title.keys', 'device-id.bin', 'session.lock'}:
                raise ValueError('private state is not a package input')
            yield path.relative_to(root).as_posix(), path


def effective_romfs(prepared):
    layers = [prepared / name for name in ('game/Update/RomFS', 'overlays/world', 'overlays/menu')]
    effective = {}
    before_bytes = 0
    for layer in layers:
        for name, path in regular_files(layer):
            before_bytes += path.stat().st_size
            effective[name] = path
    required = {'data/.build.config', 'data/build_manifest.psv'}
    if not required <= effective.keys() or not any(name.endswith('.data') for name in effective):
        raise ValueError('incomplete effective NS RomFS')
    return effective, before_bytes


def build(prepared, output):
    prepared, output = Path(prepared).resolve(), Path(output).absolute()
    if output.exists():
        raise ValueError('output must be a new directory')
    binary = prepared / 'runtime/d2r-linux-novideo'
    if binary.is_symlink() or b'D2R-LINUX-GAME-BUILD=94012\0' not in binary.read_bytes():
        raise ValueError('the NS package requires the 94012 runtime')
    subprocess.run(['bash', str(ROOT / '_kit/dist_port.sh'), 'd2r_ns'], check=True)
    shutil.copytree(PORT / 'dist', output)
    data = output / 'd2r_ns'
    for component in ('runtime', 'native'):
        for name, source in regular_files(prepared / component):
            if component == 'native' and name == 'classic-native.json':
                continue  # Preparation report, never read by the native runtime.
            destination = data / component / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    effective, before_bytes = effective_romfs(prepared)
    merged = {}
    for name, source in effective.items():
        destination = data / 'game/Update/RomFS' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o644)
        merged[name] = {'bytes': source.stat().st_size, 'sha256': sha256(destination)}
        if sha256(source) != merged[name]['sha256']:
            raise ValueError('merged NS resource checksum mismatch: ' + name)
    for name in ('game/classic-shaders/shaders.squashfs', 'game/owned-content.txt'):
        source, destination = prepared / name, data / name
        if source.is_symlink() or not source.is_file():
            raise ValueError('missing regular input file: ' + name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        if sha256(source) != sha256(destination):
            raise ValueError('package input checksum mismatch: ' + name)
    shutil.copytree(PORT / 'src/licenses', data / 'licenses')
    runtime_files = {}
    for component in ('runtime', 'native', 'bin'):
        for name, path in regular_files(data / component):
            relative = component + '/' + name
            mode = 0o755 if (relative in ('runtime/d2r-linux-novideo', 'runtime/run-bringup.sh',
                                         'bin/portkit-launcher') or path.suffix == '.so') else 0o644
            path.chmod(mode)
            runtime_files[relative] = {'bytes': path.stat().st_size,
                                       'sha256': sha256(path), 'mode': mode}
    (data / 'runtime-files.json').write_text(json.dumps({'files': runtime_files}, indent=2, sort_keys=True) + '\n')
    layout = {'game_build': '94012', 'effective_files': merged,
              'before_layer_bytes': before_bytes,
              'merged_layer_bytes': sum(info['bytes'] for info in merged.values()),
              'saves_included': False, 'device_identity_included': False,
              'runtime_caches_included': False, 'resource_bytes_changed': False}
    (data / 'resource-layout.json').write_text(json.dumps(layout, indent=2, sort_keys=True) + '\n')
    spec = importlib.util.spec_from_file_location('build_info', ROOT / '_kit/build_info.py')
    build_info = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build_info)
    build_info.stamp(PORT / 'manifest.json', output)
    forbidden = {'profile', 'save', 'save.work', 'diagnostics', 'pipeline-cache',
                 'snapshot-cache-offline90447', 'launcher-backups', 'device-id.bin',
                 'state.txt', 'launch_config.env', '.DS_Store'}
    for path in output.rglob('*'):
        if path.is_symlink() or forbidden.intersection(path.relative_to(output).parts):
            raise ValueError('private or generated state in package: ' + str(path))
    return layout


def encrypt(output, archive, password):
    archive = Path(archive).absolute()
    if archive.exists():
        raise ValueError('archive must be a new file')
    sevenzip = shutil.which('7zz') or shutil.which('7z')
    if not sevenzip:
        raise ValueError('7-Zip is required for the encrypted archive')
    archive.parent.mkdir(parents=True, exist_ok=True)
    command = [sevenzip, 'a', '-t7z', '-m0=lzma2', '-mx=5', '-mmt=4', '-mhe=on',
               '-mtm=off', '-mtc=off', '-mta=off', '-bsp0', '-p' + password, str(archive)]
    command += sorted(path.name for path in output.iterdir())
    result = subprocess.run(command, cwd=output, capture_output=True, text=True)
    if result.returncode:
        raise ValueError('7-Zip creation failed: ' + result.stderr)
    result = subprocess.run([sevenzip, 't', '-bsp0', '-p' + password, str(archive)],
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError('7-Zip integrity check failed: ' + result.stderr)
    listing = subprocess.run([sevenzip, 'l', '-slt', '-p' + password, str(archive)],
                             capture_output=True, text=True, check=True).stdout
    if '7zAES' not in listing or 'Encrypted = +' not in listing:
        raise ValueError('7-Zip encryption was not enabled')
    return {'archive': str(archive), 'archive_bytes': archive.stat().st_size,
            'archive_sha256': sha256(archive), 'integrity_test_passed': True,
            'aes_encrypted': True, 'header_encrypted': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--password')
    args = parser.parse_args()
    if bool(args.archive) != bool(args.password):
        parser.error('--archive and --password must be supplied together')
    layout = build(args.prepared, args.output)
    receipt = {'complete': True, 'output': str(args.output.absolute()), 'resources': layout}
    if args.archive:
        receipt.update(encrypt(args.output, args.archive, args.password))
    receipt_path = args.output.parent / (args.output.name + '-receipt.json')
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({key: value for key, value in receipt.items() if key != 'resources'}))


if __name__ == '__main__':
    main()
