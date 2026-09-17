#!/usr/bin/env python3
# INPUT:  json, os, stat, sys, zipfile, pathlib；端口清单和已生成 dist
# OUTPUT: main()；校验后原子写入标准 PortMaster ZIP
# POS:    按 portmaster.items 打包启动脚本与数据目录并拒绝符号链接输入
"""Build one standard PortMaster ZIP from a generated port dist directory."""

from __future__ import annotations

import json
import os
import stat
import sys
import zipfile
from pathlib import Path

ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def fail(message: str) -> None:
    raise SystemExit(f"port zip: {message}")


def safe_component(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or value in {".", ".."}:
        fail(f"invalid {field}")
    if "/" in value or "\\" in value or "\0" in value:
        fail(f"invalid {field}: {value!r}")
    return value


def reject_symlinks(path: Path) -> None:
    if path.is_symlink():
        fail(f"package input must not be a symlink: {path}")
    if not path.is_dir():
        return
    for directory, names, files in os.walk(path, followlinks=False):
        parent = Path(directory)
        for name in (*names, *files):
            candidate = parent / name
            if candidate.is_symlink():
                fail(f"package input contains a symlink: {candidate}")


def add_path(archive: zipfile.ZipFile, dist: Path, path: Path) -> None:
    reject_symlinks(path)
    paths = [path] if path.is_file() else [path, *sorted(path.rglob("*"))]
    for item in paths:
        relative = item.relative_to(dist).as_posix()
        if item.is_dir():
            info = zipfile.ZipInfo(relative.rstrip("/") + "/")
            info.date_time = ZIP_TIMESTAMP
            info.create_system = 3
            info.external_attr = (stat.S_IFDIR | 0o755) << 16
            archive.writestr(info, b"")
        elif item.is_file():
            info = zipfile.ZipInfo(relative)
            info.date_time = ZIP_TIMESTAMP
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | stat.S_IMODE(item.stat().st_mode)) << 16
            archive.writestr(info, item.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=1)
        else:
            fail(f"package input is not a regular file or directory: {item}")


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: port_zip.py <manifest> <dist> <output-dir>")
    manifest_path, dist, output_dir = map(Path, sys.argv[1:])
    with manifest_path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    items = manifest.get("portmaster", {}).get("items")
    if not isinstance(items, list) or len(items) < 2:
        fail("portmaster.items must contain a launcher and data folder")
    items = [safe_component(value, "portmaster.items item") for value in items]
    if len(items) != len(set(items)):
        fail("portmaster.items must be unique")
    launchers = [item for item in items if item.endswith(".sh")]
    directories = [item for item in items if (dist / item).is_dir()]
    if len(launchers) != 1 or len(directories) != 1:
        fail("the standard Port format requires one launcher and one data folder")
    for item in items:
        if not (dist / item).exists():
            fail(f"dist item does not exist: {item}")
    port_json = dist / "port.json"
    if not port_json.is_file() or port_json.is_symlink():
        fail("generated dist is missing a regular port.json")
    with port_json.open(encoding="utf-8") as handle:
        descriptor = json.load(handle)
    if descriptor.get("items") != items:
        fail("port.json items disagree with the manifest")
    archive_name = safe_component(descriptor.get("name"), "port.json.name")
    if not archive_name.lower().endswith(".zip"):
        fail("port.json.name must end in .zip")

    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / archive_name
    temporary = output.with_name(f".{output.name}.tmp")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
        add_path(archive, dist, port_json)
        for item in items:
            add_path(archive, dist, dist / item)
    os.replace(temporary, output)
    print(output)


if __name__ == "__main__":
    main()
