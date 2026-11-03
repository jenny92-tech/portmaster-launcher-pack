#!/usr/bin/env python3
# INPUT:  端口按键/兼容文件、共享 WSI 归档与可选显式 PCK
# OUTPUT: 不含玩家状态的 emberward 数据目录
# POS:    以固定文件清单组装余烬灯塔的部署负载
import hashlib
import json
from pathlib import Path
import shutil
import sys

PORT = Path(__file__).resolve().parents[2]
ROOT = PORT.parents[1]


def copy_regular(source, target):
    if source.is_symlink() or not source.is_file():
        raise ValueError('regular package input required: ' + str(source))
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(0o644)


def stage(data, pck=None):
    data = Path(data)
    compat = PORT / 'src/compat'
    identity = json.loads((compat / 'loong-egl-compat.json').read_text())
    for name, key in [('egl_client_extensions.c', 'source_sha256'),
                      ('loong-egl-compat.so', 'binary_sha256')]:
        path = compat / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != identity[key]:
            raise ValueError('rebuild the Emberward EGL adapter: ' + name)
    for name in ['loong-egl-compat.so', 'loong-egl-compat.json', 'NOTICE.txt', 'xwayland-shm.sh']:
        copy_regular(compat / name, data / 'compat' / name)
    copy_regular(PORT / 'src/emberward.gptk', data / 'emberward.gptk')
    wsi = ROOT / '_kit/compat/vulkan-wsi-arm64-wayland'
    artifact = json.loads((wsi / 'artifact.json').read_text())
    binary = wsi / 'libVkLayer_window_system_integration.so'
    if binary.is_symlink() or hashlib.sha256(binary.read_bytes()).hexdigest() != artifact['binary']['sha256']:
        raise ValueError('shared WSI archive checksum mismatch')
    for source, name in [(binary, binary.name), (wsi / 'LICENSE', 'LICENSE'),
                         (wsi / 'artifact.json', 'source.json')]:
        copy_regular(source, data / 'compat/vulkan-wsi' / name)
    manifest = json.loads((wsi / 'manifests/godot-implicit-template.json').read_text())
    layer = manifest['layer']
    layer['library_path'] = '@EMBERWARD_WSI_LIBRARY@'
    layer['enable_environment'] = {'EMBERWARD_VULKAN_WSI': '1'}
    layer['disable_environment'] = {'EMBERWARD_DISABLE_VULKAN_WSI': '1'}
    (data / 'compat/vulkan-wsi/layer-template.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if pck is not None:
        pck = Path(pck)
        with pck.open('rb') as stream:
            if stream.read(4) != b'GDPC':
                raise ValueError('expected an exported Godot PCK')
        copy_regular(pck, data / 'emberward.pck')


if __name__ == '__main__':
    stage(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
