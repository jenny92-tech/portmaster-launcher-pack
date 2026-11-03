#!/usr/bin/env python3
# INPUT:  已校验组装的运行器目录与 ROCKNIX SD 卡布局
# OUTPUT: roms/windows/.winecellar 下的运行器 ZIP 和 Ports 桥接
# POS:    将公共构建暂存目录封装为可直接解压到 SD 卡根目录的发行包
import argparse
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from wine_layout import APP_REL, WINDOWS_REL, ports_bridge


def build(dist, output):
    dist, output = Path(dist), Path(output)
    files = {}
    entry = "Je-Wine.sh"
    for source in sorted((dist / "wine-loongos").rglob("*")):
        if source.is_symlink():
            raise ValueError("运行器发行目录不能包含符号链接")
        if source.is_file():
            payload = source.read_bytes()
            if source.name == "build-info.json":
                metadata = json.loads(payload)
                metadata["packaging"] = "rocknix-sdcard"
                payload = (json.dumps(metadata, ensure_ascii=False, indent=2) + "\n").encode()
            files[(APP_REL / source.relative_to(dist / "wine-loongos")).as_posix()] = (source.stat().st_mode, payload)
    for name in [entry, "Je-Wine.png"]:
        source = dist / name
        files[(WINDOWS_REL / name).as_posix()] = (source.stat().st_mode, source.read_bytes())
    files["roms/ports/" + entry] = (0o100755, ports_bridge(entry))
    files["roms/ports/Je-Wine.png"] = files[(WINDOWS_REL / "Je-Wine.png").as_posix()]
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".preparing")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as target:
        for name, (mode, payload) in sorted(files.items()):
            item = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            item.external_attr = (0o100755 if mode & 0o111 else 0o100644) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            target.writestr(item, payload)
    temporary.replace(output)
    print(output)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dist", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    build(args.dist, args.output)
