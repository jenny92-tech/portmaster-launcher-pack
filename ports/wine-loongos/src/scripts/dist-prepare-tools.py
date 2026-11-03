#!/usr/bin/env python3
# INPUT:  固定校验值的未修改准备工具、来源/授权记录和本项目准备入口
# OUTPUT: 与游戏和设备运行包分开分发的电脑端准备工具 ZIP
# POS:    共用预处理工具只分发一份，读取用户文件并在隔离容器中生成副本
import argparse
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from wine_catalog import digest


def build(source, output):
    source, output = Path(source), Path(output)
    contract = json.loads((ROOT / "preprocessors/steamless.json").read_text())
    files = {"tool.json": json.dumps(contract, indent=2).encode()}
    for name, checksum in contract["files"].items():
        if digest(source / name) != checksum:
            raise ValueError("准备工具不是已记录构建：" + name)
        files[name] = (source / name).read_bytes()
    for name in ["wine_game.py", "wine_catalog.py"]:
        files[name] = (ROOT / name).read_bytes()
    files["Dockerfile"] = (ROOT / "preprocessors/Dockerfile").read_bytes()
    files["LICENSE.Steamless.txt"] = (ROOT / "preprocessors/LICENSE.Steamless.txt").read_bytes()
    files["SOURCE.txt"] = (contract["source"] + "\n" + contract["license"] + "\n").encode()
    files["README.txt"] = b"Extract the game adapter ZIP at the SD-card layout root. Build this Dockerfile with Docker, obtain its full local image ID, then use wine_game.py --adapter <id> --adapter-directory <layout-root>/roms/windows/<id> --game <user-folder> --tools <this-folder> --docker-image sha256:<image-id>.\nCopy the prepared complete game, including .wine/, into roms/windows/<id>/data/. The tool never executes the game and checks the output hash before installing the copy.\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr("wine-prepare-tools/" + name, data)
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    build(args.input, args.output)
