#!/usr/bin/env python3
# INPUT:  固定校验的 ARM64 CPython、开源输入工具、字体/数据库与本地 Docker 镜像
# OUTPUT: 启动器专用只读 SquashFS、校验文件和来源授权
# POS:    在电脑上构建不依赖系统 Python/PortMaster 的公共启动环境
from __future__ import annotations

import argparse
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/build-runtime.py"))
digest, extract_source = helpers["digest"], helpers["extract_source"]


def build(inputs, output, image):
    if not image.startswith("sha256:") or len(image) != 71:
        raise ValueError("构建环境必须使用完整本地镜像 ID")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    contract = json.loads((ROOT.parent / "bootstrap-sources.json").read_text())
    for key in ["python", "portmaster", "font", "font-license", "controller-database", "input-license"]:
        if digest(inputs[key]) != contract["inputs"][key]["sha256"]:
            raise ValueError("启动环境来源校验失败：" + key)
    with tempfile.TemporaryDirectory(prefix="bootstrap-", dir=output) as temporary:
        staging = Path(temporary)
        extract_source(Path(inputs["python"]), staging)
        for name in ["bin", "lib", "share", "notices"]:
            (staging / name).mkdir(exist_ok=True)
        with zipfile.ZipFile(inputs["portmaster"]) as archive:
            for key, target in [("gptokeyb2", "bin/gptokeyb2"), ("libinterpose.aarch64.so", "lib/libinterpose.aarch64.so")]:
                payload = archive.read("PortMaster/" + key)
                destination = staging / target
                destination.write_bytes(payload)
                if digest(destination) != contract["files"][key]:
                    raise ValueError("配套输入工具校验失败：" + key)
                destination.chmod(0o755)
        for key, target in [("font", "share/NotoSansSC-Regular.ttf"), ("controller-database", "share/gamecontrollerdb.txt"),
                            ("font-license", "notices/LICENSE-Noto.txt"), ("input-license", "notices/LICENSE-input.txt")]:
            shutil.copyfile(inputs[key], staging / target)
        (staging / "notices/SOURCES.json").write_text(json.dumps(contract, ensure_ascii=False, indent=2))
        subprocess.run(["docker", "run", "--rm", "--platform", "linux/amd64", "--network", "none", "--read-only", "--cap-drop", "ALL",
                        "--security-opt", "no-new-privileges", "--memory", "1g", "--pids-limit", "128",
                        "--mount", "type=bind,source=" + str(staging) + ",target=/source,readonly",
                        "--mount", "type=bind,source=" + str(output) + ",target=/output", image,
                        "mksquashfs", "/source", "/output/bootstrap-aarch64.squashfs", "-noappend", "-all-root", "-no-xattrs",
                        "-comp", "xz", "-processors", "2", "-mkfs-time", "0", "-all-time", "0"], check=True, stdout=subprocess.DEVNULL)
    image_file = output / "bootstrap-aarch64.squashfs"
    (output / "bootstrap.sha256").write_text(digest(image_file) + "\n")
    (output / "bootstrap-sources.json").write_text(json.dumps(contract, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"bootstrap": str(image_file), "bytes": image_file.stat().st_size, "sha256": digest(image_file)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()
    build(json.loads(args.inputs.read_text()), args.output, args.image)
