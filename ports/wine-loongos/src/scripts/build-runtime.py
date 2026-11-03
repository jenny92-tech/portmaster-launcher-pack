#!/usr/bin/env python3
# INPUT:  显式指定并已校验的组件构建输入、运行包来源和可选 HTTPS 发布根地址
# OUTPUT: 无游戏资源的独立组件归档、固定校验目录与带身份清单的标准离线 ZIP
# POS:    从白名单组件构建共享运行包，禁止从已玩过的 runtime.ext4 打包
from __future__ import annotations

import argparse
import gzip
import io
import json
from pathlib import Path
import posixpath
import shutil
import sys
import tempfile
import zipfile
import tarfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from wine_catalog import digest
from wine_package import PACKAGE_MANIFEST, runtime_package_manifest


SPECS = {
    "box64": ("cpu", [], {"box64": "bin/box64"}),
    "wine": ("windows", ["win64", "vulkan"], {"wine": "wine-10.0-amd64-wow64"}),
    "x86-libs": ("libraries", [], {"x86-libs": "x86-libs"}),
    "xkbregistry": ("host-library", [], {"xkbregistry": "native-lib", "xkb-license": "notices/xkbregistry-LICENSE"}),
    "wine-tools": ("helpers", ["borderless", "normal-close"], {"wine-close": "graphics/wine-close.exe", "wine-borderless": "graphics/wine-borderless.exe"}),
    "vulkan-wsi": ("presentation", ["wayland-vulkan"], {"wsi-library": "graphics/wsi/libVkLayer_window_system_integration.so", "wsi-manifest": "graphics/wsi/VkLayer_window_system_integration.json"}),
    "dxvk-sarek": ("graphics", ["d3d9", "d3d10", "d3d11"], {"sarek": "graphics/dxvk-sarek/x64"}),
}


def component_archive(name, kind, provides, sources, output, provenance):
    members = {}
    for source, destination in sources:
        source = Path(source)
        if not source.exists():
            raise ValueError("缺少构建输入：" + str(source))
        for path in sorted(source.rglob("*")) if source.is_dir() else [source]:
            if path.name == ".complete":
                continue
            if path.is_dir() and not path.is_symlink():
                continue
            relative = path.relative_to(source) if source.is_dir() else None
            target = str(Path(destination) / relative) if relative else destination
            if target in members:
                raise ValueError("构建路径重复")
            members[target] = path
    notice = json.dumps({"component": name, "sources": provenance}, ensure_ascii=False, sort_keys=True, indent=2).encode()
    notice_name = "notices/" + name + ".json"
    temporary = output / (name + ".tar.gz")
    unpacked_bytes = len(notice)
    with temporary.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed, tarfile.open(fileobj=compressed, mode="w|") as archive:
        for target, source in sorted(members.items()):
            entry = tarfile.TarInfo(target)
            if source.is_symlink():
                link = str(source.readlink())
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(target), link))
                if link.startswith("/") or resolved.startswith("../"):
                    raise ValueError("运行包内不允许指向外部的链接：" + str(source))
                entry.type, entry.linkname = tarfile.SYMTYPE, link
                archive.addfile(entry)
            else:
                entry.size = source.stat().st_size
                entry.mode = 0o755 if source.stat().st_mode & 0o111 else 0o644
                unpacked_bytes += entry.size
                with source.open("rb") as stream:
                    archive.addfile(entry, stream)
        entry = tarfile.TarInfo(notice_name)
        entry.size, entry.mode = len(notice), 0o644
        archive.addfile(entry, io.BytesIO(notice))
    checksum = digest(temporary)
    final = output / (name + "-" + checksum[:16] + ".tar.gz")
    temporary.replace(final)
    return {"kind": kind, "provides": provides, "archive": final.name, "sha256": checksum,
            "bytes": final.stat().st_size, "unpacked_bytes": unpacked_bytes,
            "files": sorted([*members, notice_name])}


def extract_source(archive_path, directory):
    opener = tarfile.open(fileobj=archive_path, mode="r:*") if hasattr(archive_path, "read") else tarfile.open(archive_path)
    with opener as archive:
        for member in archive:
            name = member.name
            while name.startswith("./"):
                name = name[2:]
            if name in ("", "."):
                continue
            path = Path(name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("源归档路径越界")
            target = directory / path
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not (member.isfile() or member.issym() or member.islnk()):
                raise ValueError("源归档包含特殊设备")
            target.parent.mkdir(parents=True, exist_ok=True)
            if any(parent.is_symlink() for parent in target.parents if parent != directory.parent):
                raise ValueError("源归档父路径包含符号链接")
            if member.issym():
                resolved = posixpath.normpath(posixpath.join(str(path.parent), member.linkname))
                if member.linkname.startswith("/") or resolved.startswith("../"):
                    raise ValueError("源归档链接越界")
                if not target.is_symlink():
                    target.symlink_to(member.linkname)
            else:
                with archive.extractfile(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)


def build(inputs, output, catalog, base_url=""):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    if base_url and not base_url.startswith("https://"):
        raise ValueError("发布根地址必须为 HTTPS")
    provenance = json.loads((ROOT.parent / "runtime-sources.json").read_text())["components"]
    by_name = {item["name"]: item for item in provenance}
    for item in provenance:
        for field, checksum in [("source", "source_sha256"), ("patch_file", "patch_sha256"), ("startup_patch", "startup_patch_sha256")]:
            if checksum in item and digest(ROOT.parent / item[field]) != item[checksum]:
                raise ValueError("源码与运行组件记录不一致：" + item[field])
    # Verify pinned source archives and locally built binaries before packaging.
    for key, name in [("box64", "box64"), ("wine-close", "wine-close"), ("wine-borderless", "wine-borderless")]:
        if digest(inputs[key]) != by_name[name]["baseline_binary_sha256"]:
            raise ValueError("构建输入与已记录二进制不一致：" + key)
    for key, name in [("wine-source", "wine"), ("x86-source", "box64-x86-libs"), ("xkb-source", "libxkbregistry0"), ("sarek-source", "dxvk-sarek")]:
        if digest(inputs[key]) != by_name[name]["sha256"]:
            raise ValueError("上游包校验失败：" + key)
    if digest(Path(inputs["wsi"]) / "libVkLayer_window_system_integration.so") != by_name["vulkan-wsi-layer"]["baseline_binary_sha256"]:
        raise ValueError("WSI 构建输入校验失败")
    driver = by_name["wine"]["handheld_driver"]
    if digest(inputs["wine-wayland"]) != driver["sha256"]:
        raise ValueError("掌机 Wine 驱动构建输入校验失败")
    for relative, checksum in driver["source_files"].items():
        if digest(ROOT / relative) != checksum:
            raise ValueError("掌机 Wine 驱动源码与二进制记录不一致：" + relative)
    # Reconstruct trees from verified archives, never trust a previously staged
    # directory (it may be incomplete or have been used for experiments).
    source_cache = Path(inputs["source-cache"])
    source_cache.mkdir(parents=True, exist_ok=True)
    for key, source_key, suffix in [("wine", "wine-source", "wine-10.0-amd64-wow64"),
                                    ("x86-libs", "x86-source", ""),
                                    ("sarek", "sarek-source", "dxvk-sarek-1.14.1/build/x64")]:
        archive_path = Path(inputs[source_key])
        directory = Path(tempfile.mkdtemp(prefix=key + "-", dir=source_cache))
        extract_source(archive_path, directory)
        inputs[key] = str(directory / suffix)
    shutil.copyfile(inputs["wine-wayland"], Path(inputs["wine"]) / driver["path"])
    # Read the Debian ar container directly; package maintainer scripts never run.
    deb = Path(inputs["xkb-source"]).read_bytes()
    if not deb.startswith(b"!<arch>\n"):
        raise ValueError("无效 Debian 归档")
    offset = 8
    native = Path(tempfile.mkdtemp(prefix="xkb-", dir=source_cache))
    found = False
    while offset + 60 <= len(deb):
        header = deb[offset:offset + 60]
        size = int(header[48:58].decode().strip())
        name = header[:16].decode().strip().rstrip("/")
        data = deb[offset + 60:offset + 60 + size]
        if name.startswith("data.tar"):
            extract_source(io.BytesIO(data), native)
            found = True
            break
        offset += 60 + size + size % 2
    if not found:
        raise ValueError("Debian 归档缺少数据")
    inputs["xkbregistry"] = str(native / "usr/lib/aarch64-linux-gnu")
    inputs["xkb-license"] = str(native / "usr/share/doc/libxkbregistry0/copyright")
    inputs["wsi-library"] = str(Path(inputs["wsi"]) / "libVkLayer_window_system_integration.so")
    inputs["wsi-manifest"] = str(Path(inputs["wsi"]) / "VkLayer_window_system_integration.json")
    result = {}
    for name, (kind, provides, mapping) in SPECS.items():
        source_names = {"box64": ["box64"], "wine": ["wine"], "x86-libs": ["box64-x86-libs"],
                        "xkbregistry": ["libxkbregistry0"], "wine-tools": ["wine-close", "wine-borderless"],
                        "vulkan-wsi": ["vulkan-wsi-layer"], "dxvk-sarek": ["dxvk-sarek"]}[name]
        result[name] = component_archive(name, kind, provides, [(inputs[key], target) for key, target in mapping.items()], output,
                                         [by_name[key] for key in source_names])
        if name in {"wine-tools", "dxvk-sarek"}:
            result[name]["requires"] = ["wine"]
        if name == "dxvk-sarek":
            result[name]["runtime_path"] = "graphics/dxvk-sarek/x64"
        if name == "wine":
            result[name]["runtime_path"] = "wine-10.0-amd64-wow64"
        if base_url:
            result[name]["url"] = base_url.rstrip("/") + "/" + result[name]["archive"]
    Path(catalog).write_text(json.dumps({"components": result}, ensure_ascii=False, indent=2) + "\n")
    (output / "catalog.json").write_bytes(Path(catalog).read_bytes())
    return result


def offline_pack(directory, catalog, destination, root=ROOT):
    from wine_layout import APP_REL, PACKAGES_REL
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    components = json.loads(Path(catalog).read_text())["components"]
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_STORED) as archive:
        marker = zipfile.ZipInfo(PACKAGE_MANIFEST, (2020, 1, 1, 0, 0, 0))
        marker.external_attr = 0o100644 << 16
        archive.writestr(marker, json.dumps(runtime_package_manifest(components, root), ensure_ascii=False, sort_keys=True))
        archive.write(catalog, (APP_REL / "components/catalog.json").as_posix())
        for item in components.values():
            path = Path(directory) / item["archive"]
            if digest(path) != item["sha256"]:
                raise ValueError("离线组件校验失败")
            archive.write(path, (PACKAGES_REL / path.name).as_posix())
    print(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--catalog", default=ROOT / "components/catalog.json", type=Path)
    parser.add_argument("--base-url", default="")
    parser.add_argument("--offline-zip", type=Path)
    args = parser.parse_args()
    components = build(json.loads(args.inputs.read_text()), args.output, args.catalog, args.base_url)
    if args.offline_zip:
        offline_pack(args.output, args.catalog, args.offline_zip)
    print(json.dumps({"components": {key: value["bytes"] for key, value in components.items()}}, ensure_ascii=False))


if __name__ == "__main__":
    main()
