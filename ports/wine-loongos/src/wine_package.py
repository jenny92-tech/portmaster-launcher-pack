#!/usr/bin/env python3
# INPUT:  标准 ZIP、包内身份清单、机型环境与运行器固定组件目录
# OUTPUT: 离线运行包清单、有限目录发现及校验后的组件缓存
# POS:    按内容识别可改名的离线包，只导入当前运行器认可的公共组件
import hashlib
import json
from pathlib import Path
import stat
import tempfile
import zipfile

from wine_catalog import ROOT, digest, load_definition, load_json, relative_path
from wine_layout import PACKAGES_REL, WINDOWS_REL, offline_directory


PACKAGE_MANIFEST = "je-wine-package.json"
COMPONENT_FIELDS = ("archive", "bytes", "sha256")


def runtime_package_manifest(components, root=ROOT):
    boundary = Path(root) / "environments"
    environments = [load_definition(path, boundary) for path in sorted(boundary.glob("*.json"))]
    return {"product": "je-wine", "kind": "runtime", "machine": "aarch64",
            "environments": [item["id"] for item in environments if item["machine"] == "aarch64"],
            "components": {name: {key: item[key] for key in COMPONENT_FIELDS} for name, item in components.items()}}


def package_candidates(library, offline=None):
    library = Path(library)
    if offline is not None and Path(offline).is_file():
        return [Path(offline)]
    directories = [library, Path(offline) if offline is not None else offline_directory(library)]
    if library.parts[-2:] == WINDOWS_REL.parts:
        directories.insert(0, library.parent.parent)
    result = []
    for directory in dict.fromkeys(directories):
        if directory.is_dir():
            result.extend(path for path in sorted(directory.iterdir()) if path.is_file() and not path.is_symlink())
    return result


def _import_package(path, needed, cache, environment, catalog, progress):
    with path.open("rb") as source:
        if source.read(4) not in (b"PK\x03\x04", b"PK\x05\x06"):
            return set()
        source.seek(0)
        with zipfile.ZipFile(source) as archive:
            if PACKAGE_MANIFEST not in archive.namelist():
                return set()
            entries = {}
            for item in archive.infolist():
                name = str(relative_path(item.filename.rstrip("/")))
                if name != item.filename.rstrip("/") or name in entries:
                    raise ValueError("ZIP 包含重复或不规范的路径")
                mode = stat.S_IFMT(item.external_attr >> 16)
                if mode not in (0, stat.S_IFREG, stat.S_IFDIR):
                    raise ValueError("ZIP 包含链接或特殊文件")
                entries[name] = item
            marker = entries[PACKAGE_MANIFEST]
            if marker.file_size > 64 * 1024:
                raise ValueError("离线包身份清单过大")
            manifest = json.loads(archive.read(marker))
            if not isinstance(manifest, dict) or manifest.get("product") != "je-wine" or manifest.get("kind") != "runtime":
                return set()
            environments = manifest.get("environments")
            if (manifest.get("machine") != environment["machine"] or not isinstance(environments, list)
                    or environment["id"] not in environments):
                raise ValueError("离线包不适用于当前机型环境")
            components = manifest.get("components")
            if not isinstance(components, dict) or not components:
                raise ValueError("离线包缺少组件清单")
            for name, item in components.items():
                if name not in catalog or item != {key: catalog[name][key] for key in COMPONENT_FIELDS}:
                    raise ValueError("离线组件与运行器目录不匹配：" + name)
                filename = relative_path(item["archive"])
                if len(filename.parts) != 1:
                    raise ValueError("组件包名不能包含目录")
                member = entries.get((PACKAGES_REL / filename).as_posix())
                if member is None or member.is_dir() or member.file_size != item["bytes"] or member.flag_bits & 1:
                    raise ValueError("离线组件缺失、大小不符或已加密：" + name)
                if member.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                    raise ValueError("离线组件只支持 ZIP Store/Deflate 压缩")
            selected = needed.keys() & components.keys()
            if not selected:
                return set()
            progress("发现离线运行包：" + path.name)
            cache.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".package-", dir=cache) as temporary:
                staging = Path(temporary)
                for name in sorted(selected):
                    item = components[name]
                    checksum, size = hashlib.sha256(), 0
                    with archive.open((PACKAGES_REL / item["archive"]).as_posix()) as stream, (staging / item["archive"]).open("xb") as target:
                        while block := stream.read(1024 * 1024):
                            size += len(block)
                            if size > item["bytes"]:
                                raise ValueError("离线组件大小超出目录记录：" + name)
                            checksum.update(block)
                            target.write(block)
                    if size != item["bytes"] or checksum.hexdigest() != item["sha256"]:
                        raise ValueError("离线组件校验失败：" + name)
                # Publish only after every selected component has passed validation.
                for name in sorted(selected):
                    filename = components[name]["archive"]
                    (staging / filename).replace(cache / filename)
            return selected


def import_runtime_packages(library, components, cache, environment, offline=None, root=ROOT, progress=print):
    cache = Path(cache)
    needed = {}
    for item in components:
        sources = [cache / item["archive"]]
        if offline is not None and Path(offline).is_dir():
            sources.append(Path(offline) / item["archive"])
        if not any(path.is_file() and not path.is_symlink() and digest(path) == item["sha256"] for path in sources):
            needed[item["id"]] = item
    if not needed:
        return
    catalog = load_json(Path(root) / "components/catalog.json")["components"]
    explicit = offline is not None and Path(offline).is_file()
    errors = []
    for path in package_candidates(library, offline):
        try:
            if path.is_symlink():
                raise ValueError("离线包不能是符号链接")
            imported = _import_package(path, needed, cache, environment, catalog, progress)
            if explicit and not imported:
                raise ValueError("不是适用于当前组件的 Je-Wine 离线运行包")
            for name in imported:
                needed.pop(name)
            if not needed:
                return
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, zipfile.BadZipFile, NotImplementedError) as exc:
            message = "离线包不可用（" + path.name + "）：" + str(exc)
            if explicit:
                raise RuntimeError(message) from exc
            errors.append(message)
            progress("跳过" + message)
    if errors and all(not item.get("url") for item in needed.values()):
        raise RuntimeError(errors[0])
