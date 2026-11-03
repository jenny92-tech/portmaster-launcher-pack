#!/usr/bin/env python3
# INPUT:  独立游戏适配目录、共享运行器入口约定和输出目录
# OUTPUT: ROCKNIX 布局的独立游戏适配 ZIP 与 Ports 首页桥接
# POS:    单独分发 bottle、入口和按键，游戏资源由玩家放入 data
from __future__ import annotations

import argparse
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from wine_game import load_adapter
from wine_bottle import load_bottle, check_graphics_dependencies
from wine_layout import WINDOWS_REL, ports_bridge


def build(adapter_id, output):
    adapter = load_adapter(adapter_id, ROOT)
    source = ROOT / "adapters" / adapter_id
    folder = adapter_id
    entry = "Je-" + adapter["title"] + ".sh"
    bottle = load_bottle(source)
    if bottle["settings"].get("adapter") != adapter_id:
        raise ValueError("游戏 bottle 与适配标识不一致")
    check_graphics_dependencies(bottle["dependencies"], adapter["graphics_api"])
    script = '''#!/bin/sh
# INPUT:  已安装的共享 Je-Wine 与本游戏适配包
# OUTPUT: 指定游戏的补文件提示或启动会话
# POS:    为游戏提供首页入口，不重复安装运行环境
set -eu
WINDOWS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$WINDOWS_DIR/Je-Wine.sh" --game ''' + adapter_id + ''' "$@"
'''
    readme = (adapter["title"] + "：本包不含游戏资源。\n"
              "将运行器和游戏适配 ZIP 解压到 SD 卡根目录，保留 roms/windows 与可选 roms/ports 桥接。\n"
              "离线运行环境 ZIP 可直接放在卡根目录，由 Je-Wine 识别导入。\n"
              "完整 Windows 游戏文件放入 roms/windows/" + folder + "/data/。\n"
              "需要处理入口时，在电脑使用 wine_game.py 准备，原始游戏文件保持不变。\n")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / ("wine-game-" + folder + ".zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
        files = {(WINDOWS_REL / entry).as_posix(): script.encode(),
                 "roms/ports/" + entry: ports_bridge(entry),
                 (WINDOWS_REL / folder / "adapter.json").as_posix(): (source / "adapter.json").read_bytes(),
                 (WINDOWS_REL / folder / "bottle.json").as_posix(): (source / "bottle.json").read_bytes(),
                 (WINDOWS_REL / folder / adapter["input_mapping"]).as_posix(): (source / adapter["input_mapping"]).read_bytes(),
                 (WINDOWS_REL / folder / "data/README.txt").as_posix(): readme.encode()}
        for name, data in files.items():
            item = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            item.external_attr = (0o100755 if name.endswith(".sh") else 0o100644) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(item, data)
    print(archive)
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("adapter")
    parser.add_argument("--output", default=ROOT.parents[2] / "dist", type=Path)
    args = parser.parse_args()
    build(args.adapter, args.output)
